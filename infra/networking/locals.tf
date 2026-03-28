locals {
    common_tags = {
        Project     = "shared-networking"
        Environment = var.environment
        ManagedBy   = "terraform"
    }

    azs = ["${var.aws_region}a", "${var.aws_region}c"]

    public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
    private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]
}
