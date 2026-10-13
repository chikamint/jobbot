# Firewall of the server. Admin ports are open only to your IP, web ports to everyone.

resource "aws_security_group" "node" {
  name        = "jobbot-node"
  description = "jobbot k3s node"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "jobbot-node" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.node.id
  description       = "SSH from admin"
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  security_group_id = aws_security_group.node.id
  description       = "Kubernetes API from admin"
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
}

resource "aws_vpc_security_group_ingress_rule" "web" {
  for_each = toset(["80", "443"])

  security_group_id = aws_security_group.node.id
  description       = "HTTP/HTTPS from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.node.id
  description       = "Outbound: job APIs, Telegram, image registry, OS updates"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
