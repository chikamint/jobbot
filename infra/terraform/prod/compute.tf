# The server. Software (k3s) is installed by Ansible, Terraform only creates the machine.

# Latest Ubuntu 24.04 LTS for ARM, published by Canonical in SSM Parameter Store
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

resource "aws_key_pair" "admin" {
  key_name   = "jobbot-admin"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_instance" "node" {
  ami                    = nonsensitive(data.aws_ssm_parameter.ubuntu.value)
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.node.id]
  key_name               = aws_key_pair.admin.key_name

  metadata_options {
    http_tokens = "required" # IMDSv2 only: blocks SSRF attacks that steal instance credentials
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  lifecycle {
    # a new Ubuntu AMI is published every few weeks; without this every apply would rebuild the server
    ignore_changes = [ami]
  }

  tags = { Name = "jobbot-node" }
}

# Static public IP: survives stop/start, so DNS, kubeconfig and the Ansible inventory stay valid
resource "aws_eip" "node" {
  instance = aws_instance.node.id
  domain   = "vpc"

  tags = { Name = "jobbot-node" }
}
