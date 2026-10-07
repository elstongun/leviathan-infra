# ---- KMS: envelope encryption for customer database credentials ----
# Only workers (and the ops task) may decrypt; levi-api can only encrypt.

resource "aws_kms_key" "credentials" {
  description             = "${local.name}: customer source credentials"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "credentials" {
  name          = "alias/${local.name}-credentials"
  target_key_id = aws_kms_key.credentials.key_id
}

# ---- S3: uploads and index snapshots ----

resource "aws_s3_bucket" "blobs" {
  bucket = "${local.name}-blobs-${local.account_id}"
}

resource "aws_s3_bucket_public_access_block" "blobs" {
  bucket                  = aws_s3_bucket.blobs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "blobs" {
  bucket = aws_s3_bucket.blobs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "blobs" {
  bucket = aws_s3_bucket.blobs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning gives deleted projects' snapshots the 7-day recovery window.
resource "aws_s3_bucket_versioning" "blobs" {
  bucket = aws_s3_bucket.blobs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "blobs" {
  bucket     = aws_s3_bucket.blobs.id
  depends_on = [aws_s3_bucket_versioning.blobs]

  rule {
    id     = "recovery-window"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    expiration {
      expired_object_delete_marker = true
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

resource "aws_s3_bucket_policy" "blobs_tls_only" {
  bucket = aws_s3_bucket.blobs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.blobs.arn, "${aws_s3_bucket.blobs.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.blobs]
}

# ---- RDS Postgres: control plane, jobs, usage ----
# The master password is generated and kept by RDS in Secrets Manager; it is
# only used once, by `levi-ops db-bootstrap`, to create the `levi_app` role
# the services use.

resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_db_parameter_group" "main" {
  name   = "${local.name}-pg17"
  family = "postgres17"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
}

resource "aws_db_instance" "main" {
  identifier                   = local.name
  engine                       = "postgres"
  engine_version               = "17"
  instance_class               = var.rds_instance_class
  allocated_storage            = var.rds_allocated_storage_gb
  max_allocated_storage        = var.rds_allocated_storage_gb * 4
  storage_type                 = "gp3"
  storage_encrypted            = true
  db_name                      = "levi"
  username                     = "levi_admin"
  manage_master_user_password  = true
  multi_az                     = var.rds_multi_az
  db_subnet_group_name         = aws_db_subnet_group.main.name
  vpc_security_group_ids       = [aws_security_group.this["rds"].id]
  parameter_group_name         = aws_db_parameter_group.main.name
  publicly_accessible          = false
  backup_retention_period      = 7
  backup_window                = "07:00-08:00"
  maintenance_window           = "sun:08:30-sun:09:30"
  auto_minor_version_upgrade   = true
  copy_tags_to_snapshot        = true
  performance_insights_enabled = true
  ca_cert_identifier           = "rds-ca-rsa2048-g1"
  deletion_protection          = var.env == "production"
  skip_final_snapshot          = var.env != "production"
  final_snapshot_identifier    = "${local.name}-final"
  apply_immediately            = var.env != "production"
}
