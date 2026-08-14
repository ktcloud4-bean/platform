resource "aws_kms_key" "rds_audit_worm" {
  description             = "RDS audit WORM bucket encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "rds_audit_worm" {
  name          = "alias/${local.name_prefix}-rds-audit-worm"
  target_key_id = aws_kms_key.rds_audit_worm.key_id
}

resource "aws_kms_key" "athena_results" {
  description             = "Managed Grafana Athena result encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "athena_results" {
  name          = "alias/${local.name_prefix}-grafana-athena-results"
  target_key_id = aws_kms_key.athena_results.key_id
}
