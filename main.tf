data "aws_caller_identity" "this" {}
data "aws_region" "current" {}

terraform {
  required_version = ">= 0.12"
}

locals {
  name = var.name
  common_tags = {
    "Name" = local.name
    "Terraform" = true
    "Environment" = var.environment
  }

  tags = merge(var.tags, local.common_tags)
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name = "name"
    values = [
      "ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"]
  }

  filter {
    name = "virtualization-type"
    values = [
      "hvm"]
  }

  owners = [
    "099720109477"]
  # Canonical
}

resource "aws_eip" "this" {
  vpc = true
  lifecycle {
    prevent_destroy = "false"
  }
}

resource "aws_eip_association" "this" {
  allocation_id = aws_eip.this.id
  instance_id = aws_instance.this.id
}

resource "aws_ebs_volume" "this" {
  availability_zone = var.azs[0]
  size = var.ebs_volume_size
  type = "gp2"
  tags = merge(
  local.tags,
  {
    Name = "ebs-main"
  },
  )

  lifecycle {
    prevent_destroy = "false"
  }
}

resource "aws_volume_attachment" "this" {
  device_name = var.volume_path

  volume_id = aws_ebs_volume.this.id
  instance_id = aws_instance.this.id

  force_detach = true
}

data "template_file" "user_data" {
  template = file("${path.module}/data/${var.user_data_script}")
  vars = {
    log_config_bucket = var.log_config_bucket
    log_config_key = var.log_config_key
  }
}

resource "aws_instance" "this" {
  ami = data.aws_ami.ubuntu.id
  instance_type = var.instance_type

  user_data = data.template_file.user_data.rendered
  key_name = var.key_name

  iam_instance_profile = var.instance_profile_id
  subnet_id = var.subnet_id
  security_groups = var.security_groups

  root_block_device {
    volume_type = "gp2"
    volume_size = var.root_volume_size
    delete_on_termination = true
  }
}

resource "aws_route53_record" "a-record" {
  allow_overwrite = true
  name            = "citizen"
  ttl             = 30
  type            = "A"
  zone_id         = var.zone_id

  records = [aws_instance.this.private_ip]
}
