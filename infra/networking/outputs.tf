output "vpc_id" {
    description = "VPC ID"
    value       = aws_vpc.main.id
}

output "public_subnet_ids" {
    description = "List of public subnet IDs (for ALB, NAT GW)"
    value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
    description = "List of private subnet IDs (for EKS nodes, RDS, ElastiCache)"
    value       = aws_subnet.private[*].id
}

output "nat_gateway_ip" {
    description = "Public IP of NAT Gateway (for whitelisting outbound traffic)"
    value       = var.enable_nat_gateway ? aws_eip.nat[0].public_ip : null
}
