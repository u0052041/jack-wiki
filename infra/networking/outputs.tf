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

# ── ACM ──────────────────────────────────────────────────────────────────────

output "wildcard_cert_arn" {
    description = "Wildcard ACM certificate ARN（供 Jenkins ALB / K8s Ingress 共用）"
    value       = aws_acm_certificate.wildcard.arn
}

output "acm_validation_cname" {
    description = "在 Cloudflare 加這筆 CNAME 來驗證 ACM 憑證（只需要做一次）"
    value = {
        for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
            name  = dvo.resource_record_name
            type  = dvo.resource_record_type
            value = dvo.resource_record_value
        }
    }
}
