resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = data.terraform_remote_state.network.outputs.private_db_subnet_ids

  tags = {
    Name = "${local.name_prefix}-db-subnet-group"
  }
}

resource "aws_cloudwatch_log_group" "aurora_postgresql" {
  name              = "/aws/rds/cluster/${local.name_prefix}-aurora/postgresql"
  retention_in_days = 90
}

resource "aws_rds_cluster" "main" {
  cluster_identifier = "${local.name_prefix}-aurora"
  engine             = "aurora-postgresql"
  engine_version     = "16.14"
  engine_mode        = "provisioned"

  database_name   = var.db_name
  master_username = var.db_username

  # AWS가 master password를 생성·회전 가능한 Secrets Manager secret으로 관리한다.
  # OpenTofu tfvars/state에 master 원문을 넣지 않는다.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [data.terraform_remote_state.network.outputs.rds_security_group_id]

  enabled_cloudwatch_logs_exports = ["postgresql"]
  storage_encrypted               = true
  backup_retention_period         = var.backup_retention_days
  copy_tags_to_snapshot           = true
  deletion_protection             = true
  skip_final_snapshot             = false
  final_snapshot_identifier       = var.final_snapshot_identifier
  apply_immediately               = false

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_acu
    max_capacity = var.aurora_max_acu
  }

  depends_on = [aws_cloudwatch_log_group.aurora_postgresql]

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = "${local.name_prefix}-aurora"
  }
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${local.name_prefix}-aurora-writer"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  auto_minor_version_upgrade = true

  tags = {
    Name = "${local.name_prefix}-aurora-writer"
  }
}

# 서비스 전용 credential은 master와 분리해 Secrets Manager에 보관한다. role 생성은
# private EKS migration Job이 master secret을 읽어 수행하며, 서비스 Pod는 자기 secret만
# IRSA로 읽는다.
resource "random_password" "employee_service" {
  length  = 40
  special = true
}

resource "random_password" "hr_service" {
  length  = 40
  special = true
}

resource "aws_secretsmanager_secret" "employee_service_database" {
  name                    = "${local.name_prefix}/employee-service/database"
  description             = "Employee service read-only Aurora PostgreSQL credential"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret" "hr_service_database" {
  name                    = "${local.name_prefix}/hr-service/database"
  description             = "HR service write Aurora PostgreSQL credential"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret" "bootstrap_hr_admin" {
  name                    = "${local.name_prefix}/bootstrap/hr-admin"
  description             = "Initial HR administrator identity consumed once by the database migration Job"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret_version" "employee_service_database" {
  secret_id = aws_secretsmanager_secret.employee_service_database.id
  secret_string = jsonencode({
    host     = aws_rds_cluster.main.endpoint
    port     = aws_rds_cluster.main.port
    dbname   = var.db_name
    username = "employee_service"
    password = random_password.employee_service.result
  })
}

resource "aws_secretsmanager_secret_version" "hr_service_database" {
  secret_id = aws_secretsmanager_secret.hr_service_database.id
  secret_string = jsonencode({
    host     = aws_rds_cluster.main.endpoint
    port     = aws_rds_cluster.main.port
    dbname   = var.db_name
    username = "hr_service"
    password = random_password.hr_service.result
  })
}

resource "aws_secretsmanager_secret_version" "bootstrap_hr_admin" {
  secret_id = aws_secretsmanager_secret.bootstrap_hr_admin.id
  secret_string = jsonencode({
    email = lower(var.bootstrap_hr_admin_email)
  })
}
