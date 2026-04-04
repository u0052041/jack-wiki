resource "aws_eks_cluster" "main" {
    name                          = var.cluster_name
    version                       = var.cluster_version
    role_arn                      = aws_iam_role.eks_cluster.arn
    bootstrap_self_managed_addons = false
    tags                          = merge(local.common_tags, { Name = var.cluster_name })

    vpc_config {
        subnet_ids              = data.terraform_remote_state.networking.outputs.private_subnet_ids
        endpoint_private_access = true
        endpoint_public_access  = false
    }

    access_config {
        authentication_mode                         = "API_AND_CONFIG_MAP"
        bootstrap_cluster_creator_admin_permissions = true
    }

    depends_on = [
        aws_iam_role_policy_attachment.eks_cluster_policy,
    ]
}

# ── Jenkins EKS Access ───────────────────────────────────────────────────────

resource "aws_eks_access_entry" "jenkins" {
    cluster_name  = aws_eks_cluster.main.name
    principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/jenkins-role"
    type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins" {
    cluster_name  = aws_eks_cluster.main.name
    principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/jenkins-role"
    policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

    access_scope {
        type = "cluster"
    }
}

# ── OIDC Provider（IRSA 前提）────────────────────────────────────────────────

data "tls_certificate" "eks" {
    url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
    url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
    client_id_list  = ["sts.amazonaws.com"]
    thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
    tags            = merge(local.common_tags, { Name = "${var.cluster_name}-oidc" })
}
