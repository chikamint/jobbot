variable "region" {
  description = "AWS region. The account's free plan allows workloads only in its project region."
  type        = string
  default     = "eu-north-1"
}

variable "instance_type" {
  description = "EC2 type. ARM (t4g) is ~20% cheaper than x86 for the same size."
  type        = string
  # 2 vCPU, 2 GiB. The AWS free plan only allows free-tier-eligible types
  # (`aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`) and forbids
  # changing the type in place. The only eligible 4 GiB option, c7i-flex.large, costs ~$66/month.
  default = "t4g.small"
}

variable "root_volume_gb" {
  description = "Root disk size, holds OS, k3s, container images and PostgreSQL data."
  type        = number
  default     = 20
}

variable "admin_cidr" {
  description = "Your public IP in CIDR form (x.x.x.x/32): only it may reach SSH and the Kubernetes API."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && endswith(var.admin_cidr, "/32")
    error_message = "admin_cidr must be a single address like 203.0.113.10/32."
  }
}

variable "ssh_public_key_path" {
  description = "Public key installed on the server for the ubuntu user."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
