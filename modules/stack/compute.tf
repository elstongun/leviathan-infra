# Cells (levi-cell) and sync workers (levi-sync) run on EC2. Each one is an
# Auto Scaling group of exactly one instance, so AWS replaces a failed server
# by itself. Cells keep their data volume across replacement; workers keep
# their Elastic IP. A boot script installs Docker, fetches secrets and runs
# the container; CI reruns /opt/levi/deploy.sh through SSM to roll out a new
# image, one instance at a time.

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_ec2_instance_type" "cell" {
  instance_type = var.cell_instance_type
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  instance_roles = {
    cell = {
      secrets = {
        PGPASSWORD          = local.secret_arn["db-app-password"]
        LEVI_INTERNAL_TOKEN = local.secret_arn["internal-token"]
      }
    }
    worker = {
      secrets = {
        PGPASSWORD          = local.secret_arn["db-app-password"]
        LEVI_INTERNAL_TOKEN = local.secret_arn["internal-token"]
      }
    }
  }
}

resource "aws_iam_role" "instance" {
  for_each           = local.instance_roles
  name               = "${local.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_instance_profile" "instance" {
  for_each = aws_iam_role.instance
  name     = each.value.name
  role     = each.value.name
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  for_each   = aws_iam_role.instance
  role       = each.value.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "instance_ecr" {
  for_each   = aws_iam_role.instance
  role       = each.value.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "instance_common" {
  for_each = aws_iam_role.instance
  name     = "levi-common"
  role     = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = values(local.instance_roles[each.key].secrets)
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = aws_ssm_parameter.image_tag["platform"].arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
        Resource = "${aws_cloudwatch_log_group.service[each.key == "cell" ? "cell" : "sync"].arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.blobs.arn}/${local.blob_prefix}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.blobs.arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "cell_volume" {
  name = "attach-own-data-volume"
  role = aws_iam_role.instance["cell"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeVolumes"]
        Resource = "*"
      },
      {
        Effect    = "Allow"
        Action    = ["ec2:AttachVolume"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:ResourceTag/LeviEnv" = var.env } }
      },
    ]
  })
}

resource "aws_iam_role_policy" "worker_extra" {
  name = "worker"
  role = aws_iam_role.instance["worker"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "OpenCredentials"
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:Encrypt"]
          Resource = aws_kms_key.credentials.arn
        },
        {
          Effect   = "Allow"
          Action   = ["ec2:DescribeAddresses"]
          Resource = "*"
        },
        {
          Effect    = "Allow"
          Action    = ["ec2:AssociateAddress"]
          Resource  = "*"
          Condition = { StringEquals = { "aws:ResourceTag/LeviEnv" = var.env } }
        },
      ],
      var.enable_cost_explorer ? [{
        Effect   = "Allow"
        Action   = ["ce:GetCostAndUsage"]
        Resource = "*"
      }] : [],
    )
  })
}

# ---- Egress IPs customers allowlist ----

resource "aws_eip" "egress" {
  count  = var.egress_ip_count
  domain = "vpc"
  tags   = { Name = "${local.name}-egress-${count.index}", LeviEnv = var.env }

  lifecycle {
    # Customers allowlist these; never replace one by accident.
    prevent_destroy = true
  }
}

# ---- Cells ----

resource "aws_ebs_volume" "cell" {
  count             = var.cell_count
  availability_zone = local.azs[count.index % 2]
  size              = var.cell_volume_gb
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "${local.name}-cell-${count.index}-data", LeviEnv = var.env, LeviCell = "cell-${count.index}" }
}

locals {
  cell_env = {
    for i in range(var.cell_count) : i => merge(local.common_env, {
      LEVI_DATA_DIR      = "/data/cell"
      LEVI_CELL_ID       = "cell-${i}"
      LEVI_INSTANCE_TYPE = var.cell_instance_type
      LEVI_CELL_RAM_GB   = tostring(data.aws_ec2_instance_type.cell.memory_size / 1024)
      LEVI_CELL_DISK_GB  = tostring(var.cell_volume_gb)
    })
  }
  worker_env = {
    for i in range(var.worker_count) : i => merge(local.common_env, {
      LEVI_CRYPTO        = "kms:${aws_kms_key.credentials.arn}"
      LEVI_WORKER_ID     = "worker-${i}"
      LEVI_WORK_DIR      = "/data/work"
      LEVI_COST_EXPLORER = tostring(var.enable_cost_explorer)
    })
  }
}

resource "aws_launch_template" "cell" {
  count                  = var.cell_count
  name                   = "${local.name}-cell-${count.index}"
  image_id               = data.aws_ssm_parameter.al2023_arm64.insecure_value
  instance_type          = var.cell_instance_type
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance["cell"].arn
  }

  network_interfaces {
    associate_public_ip_address = local.assign_public_ip
    security_groups             = [aws_security_group.this["cell"].id]
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/boot.sh.tftpl", {
    role        = "cell"
    service     = "levi-cell"
    region      = var.region
    env_name    = var.env
    log_group   = aws_cloudwatch_log_group.service["cell"].name
    image_param = aws_ssm_parameter.image_tag["platform"].name
    image_repo  = aws_ecr_repository.this["platform"].repository_url
    env_vars    = local.cell_env[count.index]
    secrets     = local.instance_roles.cell.secrets
    volume_id   = aws_ebs_volume.cell[count.index].id
    eip_alloc   = ""
    port        = 8083
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name}-cell-${count.index}", LeviEnv = var.env, LeviRole = "cell" }
  }
}

resource "aws_autoscaling_group" "cell" {
  count               = var.cell_count
  name                = "${local.name}-cell-${count.index}"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [var.enable_nat_gateway ? aws_subnet.private[count.index % 2].id : aws_subnet.public[count.index % 2].id]
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.cell[count.index].id
    version = aws_launch_template.cell[count.index].latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }

  tag {
    key                 = "LeviEnv"
    value               = var.env
    propagate_at_launch = true
  }
}

# ---- Sync workers ----

resource "aws_launch_template" "worker" {
  count                  = var.worker_count
  name                   = "${local.name}-worker-${count.index}"
  image_id               = data.aws_ssm_parameter.al2023_arm64.insecure_value
  instance_type          = var.worker_instance_type
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance["worker"].arn
  }

  # Workers always sit in a public subnet: their traffic to customer
  # databases must leave from the published Elastic IP.
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.this["worker"].id]
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = var.worker_volume_gb
      volume_type = "gp3"
      encrypted   = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/boot.sh.tftpl", {
    role        = "worker"
    service     = "levi-sync"
    region      = var.region
    env_name    = var.env
    log_group   = aws_cloudwatch_log_group.service["sync"].name
    image_param = aws_ssm_parameter.image_tag["platform"].name
    image_repo  = aws_ecr_repository.this["platform"].repository_url
    env_vars    = local.worker_env[count.index]
    secrets     = local.instance_roles.worker.secrets
    volume_id   = ""
    eip_alloc   = aws_eip.egress[count.index].allocation_id
    port        = 0
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name}-worker-${count.index}", LeviEnv = var.env, LeviRole = "worker" }
  }
}

resource "aws_autoscaling_group" "worker" {
  count               = var.worker_count
  name                = "${local.name}-worker-${count.index}"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.public[count.index % 2].id]
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.worker[count.index].id
    version = aws_launch_template.worker[count.index].latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }

  tag {
    key                 = "LeviEnv"
    value               = var.env
    propagate_at_launch = true
  }
}
