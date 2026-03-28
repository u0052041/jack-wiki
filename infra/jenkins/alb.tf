resource "aws_lb" "jenkins" {
    count              = var.enable_alb ? 1 : 0
    name               = "jenkins-alb"
    internal           = false
    load_balancer_type = "application"
    security_groups    = [aws_security_group.alb[0].id]
    subnets            = data.terraform_remote_state.networking.outputs.public_subnet_ids
    tags               = merge(local.common_tags, { Name = "jenkins-alb" })
}

resource "aws_lb_target_group" "jenkins" {
    count    = var.enable_alb ? 1 : 0
    name     = "jenkins-tg"
    port     = 8080
    protocol = "HTTP"
    vpc_id   = data.terraform_remote_state.networking.outputs.vpc_id

    health_check {
        path                = "/login"
        matcher             = "200,302"
        healthy_threshold   = 2
        unhealthy_threshold = 3
    }

    tags = merge(local.common_tags, { Name = "jenkins-tg" })
}

resource "aws_lb_target_group_attachment" "jenkins" {
    count            = var.enable_alb ? 1 : 0
    target_group_arn = aws_lb_target_group.jenkins[0].arn
    target_id        = aws_instance.jenkins.id
    port             = 8080
}

# HTTP → HTTPS redirect
resource "aws_lb_listener" "http" {
    count             = var.enable_alb ? 1 : 0
    load_balancer_arn = aws_lb.jenkins[0].arn
    port              = 80
    protocol          = "HTTP"

    default_action {
        type = "redirect"
        redirect {
            port        = "443"
            protocol    = "HTTPS"
            status_code = "HTTP_301"
        }
    }
}

# HTTPS → Jenkins
resource "aws_lb_listener" "https" {
    count             = var.enable_alb ? 1 : 0
    load_balancer_arn = aws_lb.jenkins[0].arn
    port              = 443
    protocol          = "HTTPS"
    ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
    certificate_arn   = aws_acm_certificate_validation.jenkins.certificate_arn

    default_action {
        type             = "forward"
        target_group_arn = aws_lb_target_group.jenkins[0].arn
    }
}
