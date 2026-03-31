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

