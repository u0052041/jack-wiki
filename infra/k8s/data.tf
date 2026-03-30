data "aws_caller_identity" "current" {}

data "terraform_remote_state" "networking" {
    backend = "local"
    config = {
        path = "../networking/terraform.tfstate"
    }
}

data "aws_security_group" "jenkins_controller" {
    name = "jenkins-controller-sg"
}
