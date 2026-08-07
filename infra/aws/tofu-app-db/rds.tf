resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = var.private_db_subnet_ids

  tags = {
    Name = "${local.name_prefix}-db-subnet-group"
  }
}

resource "aws_db_parameter_group" "postgres_pg" {
  name   = "${local.name_prefix}-postgres-pg"
  family = "postgres15"

  parameter {
    name  = "log_min_duration_statement"
    value = "2000"
  }
}

resource "aws_cloudwatch_log_group" "rds_postgresql" {
  name              = "/aws/rds/instance/${local.name_prefix}-postgres-db/postgresql"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "rds_upgrade" {
  name              = "/aws/rds/instance/${local.name_prefix}-postgres-db/upgrade"
  retention_in_days = 7
}

resource "aws_db_instance" "main" {
  identifier     = "${local.name_prefix}-postgres-db"
  engine         = "postgres"
  engine_version = "15.13"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp2"

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  parameter_group_name = aws_db_parameter_group.postgres_pg.name

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = var.rds_security_group_ids

  multi_az = var.multi_az_rds

  skip_final_snapshot = true

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    aws_cloudwatch_log_group.rds_postgresql,
    aws_cloudwatch_log_group.rds_upgrade,
  ]

  tags = {
    Name = "${local.name_prefix}-postgres-db"
  }
}
