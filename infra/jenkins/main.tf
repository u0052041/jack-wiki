resource "aws_instance" "jenkins" {
    ami           = var.jenkins_ami
    instance_type = var.jenkins_instance_type
    tags          = merge(local.common_tags, { Name = "jenkins-controller" })
    availability_zone           = var.availability_zone
    subnet_id                   = data.terraform_remote_state.networking.outputs.private_subnet_ids[0]
    vpc_security_group_ids      = [aws_security_group.jenkins_controller.id]
    associate_public_ip_address = false
    iam_instance_profile        = aws_iam_instance_profile.jenkins.name
    root_block_device {
        encrypted = true
    }

    user_data = <<-EOF
        #!/bin/bash
        set -euo pipefail

        # Install and start Docker
        dnf install -y docker
        systemctl enable --now docker
        usermod -aG docker ec2-user

        # Wait for EBS device to be attached (up to 150s)
        EBS_FOUND=false
        for i in $(seq 1 30); do
            if [ -b /dev/nvme1n1 ] || [ -b /dev/xvdf ]; then
                EBS_FOUND=true
                break
            fi
            sleep 5
        done
        if [ "$EBS_FOUND" = "false" ]; then
            echo "ERROR: EBS device not found after 150s" >&2
            exit 1
        fi

        # Detect EBS device (nvme on nitro instances, xvdf on older)
        if [ -b /dev/nvme1n1 ]; then
            EBS_DEV=/dev/nvme1n1
        else
            EBS_DEV=/dev/xvdf
        fi

        # Format only if not already formatted (safe on re-provision)
        if ! blkid $EBS_DEV; then
            mkfs -t ext4 $EBS_DEV
        fi

        # Mount
        mkdir -p /mnt/jenkins-data
        echo "$EBS_DEV /mnt/jenkins-data ext4 defaults,nofail 0 2" >> /etc/fstab
        mount -a

        # Jenkins UID is 1000
        chown -R 1000:1000 /mnt/jenkins-data

        # Login to ECR and pull latest Jenkins image
        aws ecr get-login-password --region ${var.aws_region} | \
            docker login --username AWS --password-stdin ${aws_ecr_repository.jenkins.repository_url}

        # Start Jenkins container
        docker run -d \
            --name jenkins \
            --restart always \
            -p 8080:8080 \
            -p 50000:50000 \
            -v /mnt/jenkins-data:/var/jenkins_home \
            ${aws_ecr_repository.jenkins.repository_url}:latest
    EOF

    user_data_replace_on_change = false
}

resource "null_resource" "jenkins_container_update" {
    triggers = {
        dockerfile = filemd5("${path.module}/Dockerfile")
    }

    provisioner "local-exec" {
        command = <<-EOT
            echo "Waiting for SSM agent to register on ${aws_instance.jenkins.id}..."
            aws ssm wait instance-information-available \
                --region ${var.aws_region} \
                --filters "Key=InstanceIds,Values=${aws_instance.jenkins.id}"
            aws ssm send-command \
                --region ${var.aws_region} \
                --instance-ids ${aws_instance.jenkins.id} \
                --document-name "AWS-RunShellScript" \
                --parameters 'commands=[
                    "aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${aws_ecr_repository.jenkins.repository_url}",
                    "docker pull ${aws_ecr_repository.jenkins.repository_url}:latest",
                    "docker stop jenkins && docker rm jenkins",
                    "docker run -d --name jenkins --restart always -p 8080:8080 -p 50000:50000 -v /mnt/jenkins-data:/var/jenkins_home ${aws_ecr_repository.jenkins.repository_url}:latest"
                ]'
        EOT
    }

    depends_on = [null_resource.jenkins_image_build]
}

resource "aws_ebs_volume" "jenkins" {
    availability_zone = var.availability_zone
    size              = 20
    type              = "gp3"
    encrypted         = true
    tags              = merge(local.common_tags, { Name = "jenkins-data" })

    lifecycle {
        prevent_destroy = true
    }
}

resource "aws_volume_attachment" "jenkins" {
    device_name = "/dev/xvdf"
    volume_id = aws_ebs_volume.jenkins.id
    instance_id = aws_instance.jenkins.id
}
