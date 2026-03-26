resource "aws_security_group" "jenkins_controller" {
    name   = "jenkins-controller-sg"
    vpc_id = aws_vpc.main.id
    tags   = merge(local.common_tags, { Name = "jenkins-controller-sg" })

    ingress {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"] # 無固定ip時使用
    }
}

resource "aws_security_group" "jenkins_agent" {
    name   = "jenkins-agent-sg"
    vpc_id = aws_vpc.main.id
    tags   = merge(local.common_tags, { Name = "jenkins-agent-sg" })
}

# Controller 上開洞允許 Agent 連入 50000
resource "aws_security_group_rule" "controller_from_agent" {
    type = "ingress"
    from_port = 50000
    to_port = 50000
    protocol = "tcp"
    security_group_id = aws_security_group.jenkins_controller.id
    source_security_group_id = aws_security_group.jenkins_agent.id
}

# Agent 需要可以對外連到網路啦取 docker image
resource "aws_security_group_rule" "agent_egress_all" {
    type = "egress"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    security_group_id = aws_security_group.jenkins_agent.id
}