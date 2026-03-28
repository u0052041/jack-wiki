# ALB SG：允許 internet 進來
resource "aws_security_group" "alb" {
    count  = var.enable_alb ? 1 : 0
    name   = "jenkins-alb-sg"
    vpc_id = data.terraform_remote_state.networking.outputs.vpc_id
    tags   = merge(local.common_tags, { Name = "jenkins-alb-sg" })

    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    ingress {
        from_port   = 443
        to_port     = 443
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

resource "aws_security_group" "jenkins_controller" {
    name   = "jenkins-controller-sg"
    vpc_id = data.terraform_remote_state.networking.outputs.vpc_id
    tags   = merge(local.common_tags, { Name = "jenkins-controller-sg" })

    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

# ALB 連到 Jenkins 8080
resource "aws_security_group_rule" "controller_from_alb" {
    count                    = var.enable_alb ? 1 : 0
    type                     = "ingress"
    from_port                = 8080
    to_port                  = 8080
    protocol                 = "tcp"
    security_group_id        = aws_security_group.jenkins_controller.id
    source_security_group_id = aws_security_group.alb[0].id
}
