resource "aws_ecr_repository" "jenkins" {
    name                 = "jenkins"
    image_tag_mutability = "MUTABLE"
    tags                 = merge(local.common_tags, { Name = "jenkins" })

    image_scanning_configuration {
        scan_on_push = true
    }
}

resource "aws_ecr_lifecycle_policy" "jenkins" {
    repository = aws_ecr_repository.jenkins.name

    policy = jsonencode({
        rules = [{
            rulePriority = 1
            description  = "Keep last 5 images"
            selection = {
                tagStatus   = "any"
                countType   = "imageCountMoreThan"
                countNumber = 5
            }
            action = {
                type = "expire"
            }
        }]
    })
}

resource "null_resource" "jenkins_image_build" {
    triggers = {
        dockerfile = filemd5("${path.module}/Dockerfile")
    }

    provisioner "local-exec" {
        command = <<-EOT
            aws ecr get-login-password --region ${var.aws_region} | \
                docker login --username AWS --password-stdin ${aws_ecr_repository.jenkins.repository_url}
            docker buildx build --platform linux/amd64 -t ${aws_ecr_repository.jenkins.repository_url}:latest ${path.module}
            docker push ${aws_ecr_repository.jenkins.repository_url}:latest
        EOT
    }

    depends_on = [aws_ecr_repository.jenkins]
}

output "ecr_repository_url" {
    description = "ECR repository URL for Jenkins image"
    value       = aws_ecr_repository.jenkins.repository_url
}
