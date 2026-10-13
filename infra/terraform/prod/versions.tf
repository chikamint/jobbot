terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }

  # State lives in S3 (created by ../bootstrap), not on a laptop:
  # versioned, encrypted, and locked so two applies can never run at once.
  backend "s3" {
    bucket       = "jobbot-tfstate-840285599922"
    key          = "prod/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true # native S3 locking, no DynamoDB table needed (Terraform >= 1.10)
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project     = "jobbot"
      environment = "prod"
      managed_by  = "terraform"
    }
  }
}
