locals {
    common_tags = {
        Project     = "jenkins"
        Environment = var.environment
        ManagedBy   = "terraform"
    }
}
