resource "aws_cloudwatch_log_group" "jenkins_agent" {
    name              = "/ecs/jenkins-agent"
    retention_in_days = 7
    tags              = merge(local.common_tags, { Name = "jenkins-agent-logs" })
}
