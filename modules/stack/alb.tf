resource "aws_lb" "main" {
  name                       = local.name
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = aws_subnet.public[*].id
  security_groups            = [aws_security_group.this["alb"].id]
  idle_timeout               = 300 # build progress streams and large uploads
  drop_invalid_header_fields = true
  enable_deletion_protection = var.env == "production"
}

locals {
  http_services = {
    web  = { port = 3000, host = local.app_host }
    api  = { port = 8081, host = local.control_host }
    edge = { port = 8082, host = local.api_host }
  }
}

resource "aws_lb_target_group" "this" {
  for_each             = local.http_services
  name                 = "${local.name}-${each.key}"
  port                 = each.value.port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.main.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["web"].arn
  }
}

resource "aws_lb_listener_rule" "host" {
  for_each     = { for k, v in local.http_services : k => v if k != "web" }
  listener_arn = aws_lb_listener.https.arn
  priority     = each.key == "edge" ? 10 : 20

  condition {
    host_header {
      values = [each.value.host]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }
}
