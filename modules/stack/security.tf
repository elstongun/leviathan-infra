# One security group per role. Nothing accepts traffic from the internet
# except the load balancer; everything else only from named peers.

locals {
  security_groups = {
    alb    = "Public load balancer"
    web    = "web (Next.js) tasks"
    api    = "levi-api tasks"
    edge   = "levi-edge tasks"
    cell   = "levi-cell instances"
    worker = "levi-sync instances"
    ops    = "levi-ops one-off tasks"
    rds    = "Control-plane Postgres"
  }

  # [group, port, source group]
  internal_rules = [
    ["web", 3000, "alb"],
    ["api", 8081, "alb"],
    ["edge", 8082, "alb"],
    ["cell", 8083, "edge"],
    ["cell", 8083, "api"],
    ["cell", 8083, "worker"],
    ["cell", 8083, "ops"],
    ["rds", 5432, "api"],
    ["rds", 5432, "edge"],
    ["rds", 5432, "cell"],
    ["rds", 5432, "worker"],
    ["rds", 5432, "ops"],
  ]
}

resource "aws_security_group" "this" {
  for_each    = local.security_groups
  name        = "${local.name}-${each.key}"
  description = each.value
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-${each.key}" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.this["alb"].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.this["alb"].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  description       = "Redirected to HTTPS"
}

resource "aws_vpc_security_group_ingress_rule" "internal" {
  for_each                     = { for r in local.internal_rules : "${r[0]}-${r[1]}-from-${r[2]}" => r }
  security_group_id            = aws_security_group.this[each.value[0]].id
  referenced_security_group_id = aws_security_group.this[each.value[2]].id
  ip_protocol                  = "tcp"
  from_port                    = each.value[1]
  to_port                      = each.value[1]
}

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each          = { for k, v in local.security_groups : k => v if k != "rds" }
  security_group_id = aws_security_group.this[each.key].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
