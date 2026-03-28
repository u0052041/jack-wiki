resource "aws_vpc" "main" {
    cidr_block           = var.vpc_cidr
    enable_dns_support   = true
    enable_dns_hostnames = true
    tags                 = merge(local.common_tags, { Name = "main-vpc" })
}

# ── Public Subnets ──────────────────────────────────────────────────────────

resource "aws_subnet" "public" {
    count             = length(local.azs)
    vpc_id            = aws_vpc.main.id
    cidr_block        = local.public_subnet_cidrs[count.index]
    availability_zone = local.azs[count.index]

    # ALB Controller 需要這個 tag 來識別 public subnet
    tags = merge(local.common_tags, {
        Name                     = "public-${local.azs[count.index]}"
        "kubernetes.io/role/elb" = "1"
    })
}

# ── Private Subnets ─────────────────────────────────────────────────────────

resource "aws_subnet" "private" {
    count             = length(local.azs)
    vpc_id            = aws_vpc.main.id
    cidr_block        = local.private_subnet_cidrs[count.index]
    availability_zone = local.azs[count.index]

    # ALB Controller 需要這個 tag 來識別 internal subnet
    tags = merge(local.common_tags, {
        Name                              = "private-${local.azs[count.index]}"
        "kubernetes.io/role/internal-elb" = "1"
    })
}

# ── Internet Gateway ────────────────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
    vpc_id = aws_vpc.main.id
    tags   = merge(local.common_tags, { Name = "main-igw" })
}

# ── NAT Gateway（放在第一個 public subnet）──────────────────────────────────

resource "aws_eip" "nat" {
    count  = var.enable_nat_gateway ? 1 : 0
    domain = "vpc"
    tags   = merge(local.common_tags, { Name = "nat-eip" })
}

resource "aws_nat_gateway" "main" {
    count         = var.enable_nat_gateway ? 1 : 0
    allocation_id = aws_eip.nat[0].id
    subnet_id     = aws_subnet.public[0].id
    tags          = merge(local.common_tags, { Name = "main-nat-gw" })

    depends_on = [aws_internet_gateway.main]
}

# ── Route Tables ─────────────────────────────────────────────────────────────

resource "aws_route_table" "public" {
    vpc_id = aws_vpc.main.id
    route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.main.id
    }
    tags = merge(local.common_tags, { Name = "public-rt" })
}

resource "aws_route_table_association" "public" {
    count          = length(local.azs)
    subnet_id      = aws_subnet.public[count.index].id
    route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
    vpc_id = aws_vpc.main.id
    tags   = merge(local.common_tags, { Name = "private-rt" })
}

resource "aws_route" "private_nat" {
    count                  = var.enable_nat_gateway ? 1 : 0
    route_table_id         = aws_route_table.private.id
    destination_cidr_block = "0.0.0.0/0"
    nat_gateway_id         = aws_nat_gateway.main[0].id
}

resource "aws_route_table_association" "private" {
    count          = length(local.azs)
    subnet_id      = aws_subnet.private[count.index].id
    route_table_id = aws_route_table.private.id
}
