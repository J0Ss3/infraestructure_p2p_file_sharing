terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for every resource."
  type        = string
  default     = "p2p-files"
}

variable "instance_type" {
  description = "EC2 instance type for the ECS container instance. t3.nano is cheaper but leaves little headroom for the ECS agent and dockerd."
  type        = string
  default     = "t3.micro"
}

variable "container_cli" {
  description = "Container CLI used to build and push the image. Set to \"podman\" if docker is not usable by the current user."
  type        = string
  default     = "docker"
}

variable "app_ref" {
  description = "Git ref of J0Ss3/p2p_file_sharing to build."
  type        = string
  default     = "main"
}

# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

# Lets the security group admit CloudFront edge nodes only, without hardcoding ranges.
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

# Forwards every viewer header except Host, which includes the Upgrade,
# Connection and Sec-WebSocket-* headers the /ws handshake needs.
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewerExceptHostHeader"
}

# ---------------------------------------------------------------------------
# Network. A single public subnet is all this needs: one instance that has to
# reach ECR and be reachable from CloudFront. No private subnets, so no NAT
# gateway and no hourly charge.
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/16"

  # Required for aws_eip.public_dns, which is the CloudFront origin hostname.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Image
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "app" {
  name                 = var.name
  force_delete         = true
  image_tag_mutability = "MUTABLE"
}

resource "terraform_data" "image" {
  triggers_replace = [
    filesha256("${path.module}/Dockerfile"),
    var.app_ref,
    var.container_cli,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      aws ecr get-login-password --region ${var.region} \
        | ${var.container_cli} login --username AWS --password-stdin ${aws_ecr_repository.app.repository_url}
      ${var.container_cli} build --pull \
        --build-arg APP_REF=${var.app_ref} \
        -t ${aws_ecr_repository.app.repository_url}:latest \
        ${path.module}
      ${var.container_cli} push ${aws_ecr_repository.app.repository_url}:latest
    EOT
  }
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------

resource "aws_security_group" "app" {
  name        = var.name
  description = "Origin for ${var.name}: HTTP from CloudFront only"
  vpc_id      = aws_vpc.this.id
}

resource "aws_vpc_security_group_ingress_rule" "http_from_cloudfront" {
  security_group_id = aws_security_group.app.id
  description       = "HTTP from CloudFront edge locations"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  description       = "Pull images, reach the ECS control plane"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# No key pair is created, so SSM Session Manager is the only way onto the box.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-instance"
  role = aws_iam_role.instance.name
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = var.name
}

resource "aws_instance" "ecs" {
  ami                    = nonsensitive(data.aws_ssm_parameter.ecs_ami.value)
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  user_data = <<-EOT
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.this.name}" >> /etc/ecs/ecs.config
  EOT

  # 30 GB is the ECS-optimized AMI's snapshot size; anything smaller is rejected.
  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = var.name }

  depends_on = [aws_route_table_association.public]
}

# The EIP is what makes the CloudFront origin hostname stable. A public IPv4 is
# billed either way, so this costs nothing extra over an auto-assigned address.
resource "aws_eip" "app" {
  instance = aws_instance.ecs.id
  domain   = "vpc"
}

# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.name}"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "app" {
  family                   = var.name
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]

  container_definitions = jsonencode([{
    name      = "app"
    image     = "${aws_ecr_repository.app.repository_url}:latest"
    essential = true
    memory    = 400

    portMappings = [{
      containerPort = 3000
      hostPort      = 80
    }]

    environment = [{
      name  = "PORT"
      value = "3000"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name            = var.name
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.app.arn
  launch_type     = "EC2"
  desired_count   = 1

  # Host port 80 is exclusive, so the old task has to stop before the new one
  # can start. Signalling state is in memory anyway, so there is nothing to
  # drain gracefully.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  depends_on = [terraform_data.image, aws_eip.app]
}

# ---------------------------------------------------------------------------
# TLS and public URL
# ---------------------------------------------------------------------------

resource "aws_cloudfront_distribution" "app" {
  enabled         = true
  comment         = var.name
  is_ipv6_enabled = true

  origin {
    origin_id   = "ec2"
    domain_name = aws_eip.app.public_dns

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 60
      origin_keepalive_timeout = 60
    }
  }

  default_cache_behavior {
    target_origin_id       = "ec2"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    # POST/PUT/PATCH/DELETE are needed for the WebSocket upgrade to pass through.
    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "url" {
  description = "Public HTTPS URL of the app."
  value       = "https://${aws_cloudfront_distribution.app.domain_name}"
}

output "origin_ip" {
  description = "Elastic IP of the container instance."
  value       = aws_eip.app.public_ip
}
