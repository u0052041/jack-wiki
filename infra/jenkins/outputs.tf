output "instance_id" {
    description = "EC2 instance ID"
    value       = aws_instance.jenkins.id
}

output "ssm_command" {
    description = "SSM 連入指令"
    value       = "aws ssm start-session --target ${aws_instance.jenkins.id} --region ${var.aws_region}"
}

output "alb_dns_name" {
    description = "ALB DNS name → 在 Cloudflare 設 CNAME 指向這個"
    value       = var.enable_alb ? aws_lb.jenkins[0].dns_name : null
}

output "acm_validation_cname" {
    description = "在 Cloudflare 加這筆 CNAME 來驗證 ACM 憑證（只需要做一次）"
    value = {
        for dvo in aws_acm_certificate.jenkins.domain_validation_options : dvo.domain_name => {
            name  = dvo.resource_record_name
            type  = dvo.resource_record_type
            value = dvo.resource_record_value
        }
    }
}
