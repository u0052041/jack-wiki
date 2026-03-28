resource "aws_acm_certificate" "jenkins" {
    domain_name       = var.jenkins_domain
    validation_method = "DNS"
    tags              = merge(local.common_tags, { Name = "jenkins-cert" })

    lifecycle {
        create_before_destroy = true
    }
}

# apply 後執行 terraform output acm_validation_cname
# 將輸出的 CNAME 加到 Cloudflare，Terraform 會等待驗證完成
resource "aws_acm_certificate_validation" "jenkins" {
    certificate_arn = aws_acm_certificate.jenkins.arn
    # DNS record 需手動到 Cloudflare 加，Terraform 會等待直到驗證完成
    # 執行 terraform output acm_validation_cname 拿到要加的 CNAME
    timeouts {
        create = "30m"
    }
}
