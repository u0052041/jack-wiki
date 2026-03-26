resource "aws_ssm_parameter" "cloudflare_tunnel_token" {
    name        = "/jenkins/cloudflare-tunnel-token"
    description = "Cloudflare Tunnel token for Jenkins controller"
    type        = "SecureString"
    value       = "PLACEHOLDER"

    tags = merge(local.common_tags, { Name = "jenkins-cloudflare-tunnel-token" })

    lifecycle {
        ignore_changes = [value]
    }
}
