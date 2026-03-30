locals {
    common_tags = {
        Project     = "eks"
        Environment = var.environment
        ManagedBy   = "terraform"
    }
}
