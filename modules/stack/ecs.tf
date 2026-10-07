# ---- Images ----
# One platform image (every Rust binary) and one web image. CI pushes
# immutable tags and records the deployed tag in SSM; Terraform reads it so
# an apply never rolls a service back to an older image.

resource "aws_ecr_repository" "this" {
  for_each             = toset(["platform", "web"])
  name                 = "levi-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.env != "production"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 50 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 50 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_ssm_parameter" "image_tag" {
  for_each       = aws_ecr_repository.this
  name           = "/levi/${var.env}/image-tag/${each.key}"
  type           = "String"
  insecure_value = "bootstrap"
  description    = "Deployed ${each.key} image tag; written by CI"

  lifecycle {
    ignore_changes = [insecure_value]
  }
}

data "aws_ssm_parameter" "image_tag" {
  for_each = aws_ssm_parameter.image_tag
  name     = each.value.name
}

locals {
  image = {
    for k, repo in aws_ecr_repository.this : k => "${repo.repository_url}:${data.aws_ssm_parameter.image_tag[k].insecure_value}"
  }
}

# ---- Environment and secrets per service ----

locals {
  egress_ips = aws_eip.egress[*].public_ip

  common_env = {
    LEVI_ENV         = var.env
    PGHOST           = aws_db_instance.main.address
    PGPORT           = tostring(aws_db_instance.main.port)
    PGUSER           = "levi_app"
    PGDATABASE       = "levi"
    LEVI_STORAGE     = local.storage_url
    LEVI_APP_URL     = local.app_url
    LEVI_API_URL     = local.api_url
    LEVI_SCALE_STAGE = tostring(var.scale_stage)
    AWS_REGION       = var.region
    RUST_LOG         = "info"
  }

  env = {
    api = merge(local.common_env, {
      LEVI_AUTH_MODE             = "workos"
      WORKOS_CLIENT_ID           = var.workos_client_id
      LEVI_STAFF_ORG_ID          = var.staff_org_id
      LEVI_CRYPTO                = "kms:${aws_kms_key.credentials.arn}"
      LEVI_EGRESS_IPS            = join(",", local.egress_ips)
      LEVI_CALENDLY_URL          = var.calendly_url
      STRIPE_REQUIRE_TOS_CONSENT = tostring(var.stripe_require_tos_consent)
    })
    edge = local.common_env
    web = {
      LEVI_CONTROL_URL    = local.control_url
      LEVI_APP_URL        = local.app_url
      WORKOS_CLIENT_ID    = var.workos_client_id
      WORKOS_REDIRECT_URI = "${local.app_url}/auth/callback"
    }
    ops = merge(local.common_env, {
      LEVI_CRYPTO = "kms:${aws_kms_key.credentials.arn}"
    })
  }

  secrets = {
    api = {
      PGPASSWORD            = local.secret_arn["db-app-password"]
      LEVI_INTERNAL_TOKEN   = local.secret_arn["internal-token"]
      LEVI_API_KEY_PEPPER   = local.secret_arn["api-key-pepper"]
      WORKOS_API_KEY        = local.secret_arn["workos-api-key"]
      STRIPE_SECRET_KEY     = local.secret_arn["stripe-secret-key"]
      STRIPE_WEBHOOK_SECRET = local.secret_arn["stripe-webhook-secret"]
    }
    edge = {
      PGPASSWORD          = local.secret_arn["db-app-password"]
      LEVI_INTERNAL_TOKEN = local.secret_arn["internal-token"]
      LEVI_API_KEY_PEPPER = local.secret_arn["api-key-pepper"]
    }
    web = {
      WORKOS_API_KEY         = local.secret_arn["workos-api-key"]
      WORKOS_COOKIE_PASSWORD = local.secret_arn["workos-cookie-password"]
    }
    ops = {
      PGPASSWORD            = local.secret_arn["db-app-password"]
      LEVI_INTERNAL_TOKEN   = local.secret_arn["internal-token"]
      STRIPE_SECRET_KEY     = local.secret_arn["stripe-secret-key"]
      STRIPE_WEBHOOK_SECRET = local.secret_arn["stripe-webhook-secret"]
      LEVI_APP_DB_PASSWORD  = local.secret_arn["db-app-password"]
      LEVI_ADMIN_PGUSER     = "${local.db_master_secret_arn}:username::"
      LEVI_ADMIN_PGPASSWORD = "${local.db_master_secret_arn}:password::"
    }
  }

  tasks = {
    web  = { image = local.image["web"], command = null, port = 3000 }
    api  = { image = local.image["platform"], command = ["levi-api"], port = 8081 }
    edge = { image = local.image["platform"], command = ["levi-edge"], port = 8082 }
    ops  = { image = local.image["platform"], command = ["levi-ops", "--help"], port = null }
  }
}

# ---- Cluster, logs and roles ----

resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_cloudwatch_log_group" "service" {
  for_each          = toset(["web", "api", "edge", "ops", "cell", "sync"])
  name              = "/levi/${var.env}/${each.key}"
  retention_in_days = 14
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# Execution roles: pull the image, write logs, and read only that task's secrets.
resource "aws_iam_role" "execution" {
  for_each           = local.tasks
  name               = "${local.name}-${each.key}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  for_each   = aws_iam_role.execution
  role       = each.value.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  for_each = aws_iam_role.execution
  name     = "read-own-secrets"
  role     = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = distinct([for v in values(local.secrets[each.key]) : split(":username::", split(":password::", v)[0])[0]])
    }]
  })
}

# Task roles: what the running code may do in AWS.
resource "aws_iam_role" "task" {
  for_each           = toset(["api", "ops"])
  name               = "${local.name}-${each.key}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy" "api_task" {
  name = "uploads-and-seal"
  role = aws_iam_role.task["api"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
      {
        Sid      = "SealOnly"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Encrypt"]
        Resource = aws_kms_key.credentials.arn
      },
    ]
  })
}

resource "aws_iam_role_policy" "ops_task" {
  name = "operations"
  role = aws_iam_role.task["ops"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
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
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt"]
        Resource = aws_kms_key.credentials.arn
      },
      {
        Sid      = "StripeSetupStoresWebhookSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:PutSecretValue"]
        Resource = local.secret_arn["stripe-webhook-secret"]
      },
    ]
  })
}

# ---- Task definitions ----

resource "aws_ecs_task_definition" "this" {
  for_each                 = local.tasks
  family                   = "${local.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_sizes[each.key].cpu
  memory                   = var.task_sizes[each.key].memory
  execution_role_arn       = aws_iam_role.execution[each.key].arn
  task_role_arn            = contains(["api", "ops"], each.key) ? aws_iam_role.task[each.key].arn : null

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([merge(
    {
      name        = each.key
      image       = each.value.image
      essential   = true
      environment = [for k, v in local.env[each.key] : { name = k, value = v } if v != ""]
      secrets     = [for k, v in local.secrets[each.key] : { name = k, valueFrom = v }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.service[each.key].name
          awslogs-region        = var.region
          awslogs-stream-prefix = each.key
        }
      }
    },
    each.value.command == null ? {} : { command = each.value.command },
    each.value.port == null ? {} : { portMappings = [{ containerPort = each.value.port, protocol = "tcp" }] },
  )])
}

# ---- Services ----

locals {
  desired = {
    web  = var.web_desired_count
    api  = var.api_desired_count
    edge = var.edge_desired_count
  }
}

resource "aws_ecs_service" "this" {
  for_each                          = local.http_services
  name                              = "${local.name}-${each.key}"
  cluster                           = aws_ecs_cluster.main.id
  task_definition                   = aws_ecs_task_definition.this[each.key].arn
  desired_count                     = local.desired[each.key]
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 30
  propagate_tags                    = "SERVICE"
  enable_execute_command            = false

  network_configuration {
    subnets          = local.service_subnets
    security_groups  = [aws_security_group.this[each.key].id]
    assign_public_ip = local.assign_public_ip
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this[each.key].arn
    container_name   = each.key
    container_port   = each.value.port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.https]

  lifecycle {
    # Auto scaling owns the running count between the minimum and maximum.
    ignore_changes = [desired_count]
  }
}

resource "aws_appautoscaling_target" "service" {
  for_each           = aws_ecs_service.this
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${each.value.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = local.desired[each.key]
  max_capacity       = max(var.service_autoscaling_max, local.desired[each.key])
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each           = aws_appautoscaling_target.service
  name               = "${local.name}-${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = each.value.service_namespace
  resource_id        = each.value.resource_id
  scalable_dimension = each.value.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
