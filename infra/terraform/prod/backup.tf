# PostgreSQL backups: private S3 bucket + IAM role for the node.
# No static access keys anywhere: the backup pod gets short-lived credentials from the
# instance profile via IMDSv2 (see metadata_options in compute.tf).

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "backups" {
  bucket = "jobbot-backups-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Retention: keep daily dumps for 14 days, then S3 deletes them automatically
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-old-dumps"
    status = "Enabled"
    filter {
      prefix = "postgres/"
    }
    expiration {
      days = 14
    }
  }
}

# --- IAM: the node may write/read dumps in this bucket and nothing else ---

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "jobbot-node"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "backups" {
  statement {
    sid       = "ListDumps"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["postgres/*"]
    }
  }
  statement {
    sid       = "ReadWriteDumps"
    actions   = ["s3:PutObject", "s3:GetObject"] # no DeleteObject: a compromised node cannot wipe backups
    resources = ["${aws_s3_bucket.backups.arn}/postgres/*"]
  }
}

resource "aws_iam_role_policy" "backups" {
  name   = "postgres-backups"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.backups.json
}

resource "aws_iam_instance_profile" "node" {
  name = "jobbot-node"
  role = aws_iam_role.node.name
}

output "backup_bucket" {
  value = aws_s3_bucket.backups.bucket
}
