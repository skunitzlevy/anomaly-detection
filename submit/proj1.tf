terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

locals {
  stack_name = "proj1"
}

data "aws_caller_identity" "current" {}

# Ubuntu 24.04 AMI ID from SSM (Canonical)
data "aws_ssm_parameter" "ubuntu_2404_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

variable "key_name" {
  description = "Existing EC2 key pair for SSH"
  type        = string
}

variable "ssh_location" {
  description = "Your public IP in CIDR form for SSH (example 1.2.3.4/32)"
  type        = string
}

variable "repo_url" {
  description = "HTTPS URL of your forked anomaly-detection repository"
  type        = string
  default     = "https://github.com/skunitzlevy/anomaly-detection.git"
}

############################
# SNS Topic + Policy
############################

resource "aws_sns_topic" "app_topic" {
  name = "ds5220-dp1"
}

resource "aws_sns_topic_policy" "app_topic_policy" {
  arn = aws_sns_topic.app_topic.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowS3PublishToTopic"
        Effect = "Allow"
        Principal = {
          Service = "s3.amazonaws.com"
        }
        Action   = "sns:Publish"
        Resource = aws_sns_topic.app_topic.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

############################
# S3 Bucket + Notification
############################

resource "aws_s3_bucket" "data_bucket" {
  bucket        = "${local.stack_name}-${data.aws_caller_identity.current.account_id}-data"
  force_destroy = false
}

# Allow S3 to publish to SNS (policy above handles authorization),
# but S3 notifications are configured via aws_s3_bucket_notification.
resource "aws_s3_bucket_notification" "data_bucket_notify" {
  bucket = aws_s3_bucket.data_bucket.id

  topic {
    topic_arn     = aws_sns_topic.app_topic.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "raw/"
    filter_suffix = ".csv"
  }

  # Make sure the topic policy exists before Terraform applies notification config
  depends_on = [aws_sns_topic_policy.app_topic_policy]
}

############################
# IAM Role + Policy + Instance Profile
############################

resource "aws_iam_role" "app_role" {
  name = "${local.stack_name}-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "app_bucket_policy" {
  name = "DataBucketAccessOnly"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.data_bucket.arn
      },
      {
        Sid      = "BucketObjectsRWDelete"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.data_bucket.arn}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_bucket_policy" {
  role       = aws_iam_role.app_role.name
  policy_arn = aws_iam_policy.app_bucket_policy.arn
}

resource "aws_iam_instance_profile" "app_instance_profile" {
  name = "${local.stack_name}-app-instance-profile"
  role = aws_iam_role.app_role.name
}

############################
# Security Group
############################

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "app_security_group" {
  name        = "${local.stack_name}-app-sg"
  description = "Allow SSH from student IP and API on port 8000 from anywhere"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH from your IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_location]
  }

  ingress {
    description = "FastAPI endpoint for SNS and API access"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################
# EC2 Instance + EIP
############################

resource "aws_instance" "app_instance" {
  ami                    = data.aws_ssm_parameter.ubuntu_2404_ami.value
  instance_type          = "t3.micro"
  key_name               = var.key_name
  iam_instance_profile   = aws_iam_instance_profile.app_instance_profile.name
  vpc_security_group_ids = [aws_security_group.app_security_group.id]

  root_block_device {
    volume_size           = 16
    volume_type           = "gp3"
    delete_on_termination = true
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    apt-get install -y python3 python3-venv python3-pip git

    su - ubuntu -c "cd /home/ubuntu && if [ ! -d anomaly-detection ]; then git clone ${var.repo_url}; else cd anomaly-detection && git pull; fi"

    su - ubuntu -c "cd /home/ubuntu/anomaly-detection && python3 -m venv .venv"
    su - ubuntu -c "cd /home/ubuntu/anomaly-detection && .venv/bin/pip install --upgrade pip"
    su - ubuntu -c "cd /home/ubuntu/anomaly-detection && .venv/bin/pip install -r requirements.txt"

    export BUCKET_NAME='${aws_s3_bucket.data_bucket.id}'
    echo "export BUCKET_NAME=${aws_s3_bucket.data_bucket.id}" >> /home/ubuntu/.bashrc

    if grep -q '^BUCKET_NAME=' /etc/environment; then
      sed -i "s|^BUCKET_NAME=.*|BUCKET_NAME=${aws_s3_bucket.data_bucket.id}|" /etc/environment
    else
      echo "BUCKET_NAME=${aws_s3_bucket.data_bucket.id}" >> /etc/environment
    fi

    cat > /etc/systemd/system/anomaly-api.service <<'SERVICEEOF'
    [Unit]
    Description=Anomaly Detection FastAPI Service
    After=network.target

    [Service]
    Type=simple
    User=ubuntu
    WorkingDirectory=/home/ubuntu/anomaly-detection
    Environment=BUCKET_NAME=${aws_s3_bucket.data_bucket.id}
    ExecStart=/home/ubuntu/anomaly-detection/.venv/bin/uvicorn app:app --host 0.0.0.0 --port 8000
    Restart=always
    RestartSec=5

    [Install]
    WantedBy=multi-user.target
    SERVICEEOF

    systemctl daemon-reload
    systemctl enable anomaly-api.service
    systemctl start anomaly-api.service
  EOF

  tags = {
    Name = "${local.stack_name}-app"
  }
}

resource "aws_eip" "app_eip" {
  domain = "vpc"
}

resource "aws_eip_association" "app_eip_association" {
  allocation_id = aws_eip.app_eip.id
  instance_id   = aws_instance.app_instance.id
}

############################
# SNS Subscription (HTTP endpoint on EIP)
############################

resource "aws_sns_topic_subscription" "app_subscription" {
  topic_arn = aws_sns_topic.app_topic.arn
  protocol  = "http"
  endpoint  = "http://${aws_eip.app_eip.public_ip}:8000/notify"

  # ensure the EIP is attached before creating subscription.
  depends_on = [
    aws_eip_association.app_eip_association
  ]
}

############################
# Outputs
############################

output "bucket_name" {
  description = "S3 bucket used by the app"
  value       = aws_s3_bucket.data_bucket.id
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.app_instance.id
}

output "elastic_ip" {
  description = "Stable public IP for API/SNS endpoint"
  value       = aws_eip.app_eip.public_ip
}

output "notify_endpoint" {
  description = "SNS HTTP endpoint used by the app"
  value       = "http://${aws_eip.app_eip.public_ip}:8000/notify"
}