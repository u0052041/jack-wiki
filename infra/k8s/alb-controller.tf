# ── ALB Controller IRSA ──────────────────────────────────────────────────────

locals {
    oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

resource "aws_iam_role" "alb_controller" {
    name = "${var.cluster_name}-alb-controller"
    tags = merge(local.common_tags, { Name = "${var.cluster_name}-alb-controller" })

    assume_role_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [{
            Effect = "Allow"
            Principal = {
                Federated = aws_iam_openid_connect_provider.eks.arn
            }
            Action = "sts:AssumeRoleWithWebIdentity"
            Condition = {
                StringEquals = {
                    "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
                    "${local.oidc_issuer}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
                }
            }
        }]
    })
}

resource "aws_iam_policy" "alb_controller" {
    name   = "${var.cluster_name}-alb-controller"
    tags   = merge(local.common_tags, { Name = "${var.cluster_name}-alb-controller" })
    policy = file("${path.module}/policies/alb-controller-policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
    role       = aws_iam_role.alb_controller.name
    policy_arn = aws_iam_policy.alb_controller.arn
}

# ── SSM Parameters（供 Jenkins helm install 使用）────────────────────────────

resource "aws_ssm_parameter" "alb_controller_role_arn" {
    name  = "/eks/${var.cluster_name}/alb-controller-role-arn"
    type  = "String"
    value = aws_iam_role.alb_controller.arn
    tags  = merge(local.common_tags, { Name = "${var.cluster_name}-alb-controller-role-arn" })
}

resource "aws_ssm_parameter" "cluster_name" {
    name  = "/eks/${var.cluster_name}/cluster-name"
    type  = "String"
    value = aws_eks_cluster.main.name
    tags  = merge(local.common_tags, { Name = "${var.cluster_name}-cluster-name" })
}

resource "aws_ssm_parameter" "aws_region" {
    name  = "/eks/${var.cluster_name}/aws-region"
    type  = "String"
    value = var.aws_region
    tags  = merge(local.common_tags, { Name = "${var.cluster_name}-aws-region" })
}

resource "aws_ssm_parameter" "vpc_id" {
    name  = "/eks/${var.cluster_name}/vpc-id"
    type  = "String"
    value = data.terraform_remote_state.networking.outputs.vpc_id
    tags  = merge(local.common_tags, { Name = "${var.cluster_name}-vpc-id" })
}
