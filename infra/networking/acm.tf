# ── Wildcard ACM Certificate（共用於所有 *.u0052041.com 服務）──────────────

resource "aws_acm_certificate" "wildcard" {
    domain_name       = var.wildcard_domain
    validation_method = "DNS"
    tags              = merge(local.common_tags, { Name = "wildcard-cert" })

    lifecycle {
        create_before_destroy = true
    }
}

# apply 後執行 terraform output acm_validation_cname
# 將輸出的 CNAME 加到 Cloudflare，Terraform 會等待驗證完成
resource "aws_acm_certificate_validation" "wildcard" {
    certificate_arn = aws_acm_certificate.wildcard.arn

    timeouts {
        create = "30m"
    }
}

# ── SSM Parameter（供 Jenkins pipeline deploy 時讀取）─────────────────────

resource "aws_ssm_parameter" "wildcard_cert_arn" {
    name  = "/shared/wildcard-cert-arn"
    type  = "String"
    value = aws_acm_certificate.wildcard.arn
    tags  = merge(local.common_tags, { Name = "wildcard-cert-arn" })
}
