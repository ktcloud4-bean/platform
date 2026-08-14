# Amazon Managed Grafana - SOC 대시보드. project-c의 대시보드 JSON 템플릿
# (docs/grafana/*.json)은 수정 없이 그대로 배포한다(요청사항).
#
# Amazon Managed Grafana는 임의 OIDC 직접 연동을 지원하지 않고 SAML 2.0만
# 지원한다 - AWS IAM SAML Provider(tofu-identity 소유)와는 별개로, Grafana
# 전용 SAML 클라이언트를 온프레미스 Keycloak에 추가로 등록해야 한다.

resource "aws_iam_role" "grafana" {
  name = "${local.name_prefix}-grafana-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "grafana.amazonaws.com" }
    }]
  })
}

data "aws_iam_policy_document" "grafana_datasources" {
  statement {
    effect = "Allow"
    actions = [
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetInsightRuleReport",
      "logs:DescribeLogGroups",
      "logs:GetLogGroupFields",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "logs:GetLogEvents",
      # CloudWatch 패널 쿼리 에디터가 초기화 단계에서 oam:ListSinks를 먼저
      # 조회함 - 없으면 그 뒤 실제 로그 쿼리 자체를 브라우저가 안 보냄.
      "oam:ListSinks",
      "oam:ListAttachedLinks",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "athena:GetDataCatalog",
      "athena:GetDatabase",
      "athena:GetTableMetadata",
      "athena:ListDatabases",
      "athena:ListTableMetadata",
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution",
      "athena:GetWorkGroup",
      "athena:ListWorkGroups",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:BatchGetPartition",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::aws-security-data-lake-*", "arn:aws:s3:::aws-security-data-lake-*/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.cloudtrail_bucket.arn, "${aws_s3_bucket.cloudtrail_bucket.arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::aws-security-data-lake-*/athena-results/*"]
  }

  # CloudTrail 버킷 객체가 KMS로 암호화돼 있어서 Athena가 열어보려면 필요
  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.cloudtrail.arn]
  }
}

resource "aws_iam_role_policy" "grafana_datasources" {
  name   = "grafana-datasources-readonly"
  role   = aws_iam_role.grafana.id
  policy = data.aws_iam_policy_document.grafana_datasources.json
}

# Security Lake Glue 데이터베이스는 Lake Formation 거버넌스가 걸려있어 IAM
# 정책만으로는 접근 못 하고 Lake Formation 권한을 별도로 부여해야 함.
resource "aws_lakeformation_permissions" "grafana_database" {
  principal   = aws_iam_role.grafana.arn
  permissions = ["DESCRIBE"]
  database {
    name = "amazon_security_lake_glue_db_${replace(var.aws_region, "-", "_")}"
  }
}

resource "aws_lakeformation_permissions" "grafana_tables" {
  principal   = aws_iam_role.grafana.arn
  permissions = ["SELECT", "DESCRIBE"]
  table {
    database_name = "amazon_security_lake_glue_db_${replace(var.aws_region, "-", "_")}"
    wildcard      = true
  }
}

# IAM API 호출 타임라인용 CloudTrail Athena 테이블 - Security Lake의
# CLOUD_TRAIL_MGMT 소스가 이 리전 조합 미지원이라 CloudTrail S3 버킷을
# Athena 외부 테이블로 직접 매핑(AWS 공식 CloudTrailSerde 스키마 그대로).
resource "aws_glue_catalog_table" "cloudtrail" {
  name          = "${replace(local.name_prefix, "-", "_")}_cloudtrail_logs"
  database_name = "default"
  table_type    = "EXTERNAL_TABLE"

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.cloudtrail_bucket.id}/prefix/AWSLogs/${data.aws_caller_identity.current.account_id}/CloudTrail/"
    input_format  = "com.amazon.emr.cloudtrail.CloudTrailInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "com.amazon.emr.hive.serde.CloudTrailSerde"
    }

    columns {
      name = "eventversion"
      type = "string"
    }
    columns {
      name = "useridentity"
      type = "struct<type:string,principalid:string,arn:string,accountid:string,invokedby:string,accesskeyid:string,userName:string,sessioncontext:struct<attributes:struct<mfaauthenticated:string,creationdate:string>,sessionissuer:struct<type:string,principalId:string,arn:string,accountId:string,userName:string>>>"
    }
    columns {
      name = "eventtime"
      type = "string"
    }
    columns {
      name = "eventsource"
      type = "string"
    }
    columns {
      name = "eventname"
      type = "string"
    }
    columns {
      name = "awsregion"
      type = "string"
    }
    columns {
      name = "sourceipaddress"
      type = "string"
    }
    columns {
      name = "useragent"
      type = "string"
    }
    columns {
      name = "errorcode"
      type = "string"
    }
    columns {
      name = "errormessage"
      type = "string"
    }
    columns {
      name = "requestparameters"
      type = "string"
    }
    columns {
      name = "responseelements"
      type = "string"
    }
    columns {
      name = "additionaleventdata"
      type = "string"
    }
    columns {
      name = "requestid"
      type = "string"
    }
    columns {
      name = "eventid"
      type = "string"
    }
    columns {
      name = "resources"
      type = "array<struct<arn:string,accountId:string,type:string>>"
    }
    columns {
      name = "eventtype"
      type = "string"
    }
    columns {
      name = "apiversion"
      type = "string"
    }
    columns {
      name = "readonly"
      type = "string"
    }
    columns {
      name = "recipientaccountid"
      type = "string"
    }
    columns {
      name = "serviceeventdetails"
      type = "string"
    }
    columns {
      name = "sharedeventid"
      type = "string"
    }
    columns {
      name = "vpcendpointid"
      type = "string"
    }
  }
}

resource "aws_lakeformation_permissions" "grafana_default_database" {
  principal   = aws_iam_role.grafana.arn
  permissions = ["DESCRIBE"]
  database {
    name = "default"
  }
}

resource "aws_lakeformation_permissions" "grafana_cloudtrail_table" {
  principal   = aws_iam_role.grafana.arn
  permissions = ["SELECT", "DESCRIBE"]
  table {
    database_name = "default"
    name          = aws_glue_catalog_table.cloudtrail.name
  }
}

resource "aws_grafana_workspace" "main" {
  name                     = "${local.name_prefix}-soc"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["SAML"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana.arn
  data_sources             = ["CLOUDWATCH", "ATHENA"]

  configuration = jsonencode({
    unifiedAlerting = { enabled = false }
    plugins         = { pluginAdminEnabled = true }
  })
}

# Grafana 전용 SAML 클라이언트(scripts/keycloak-grafana-saml-client.sh)는
# 온프레미스 Keycloak이라 SSM RunCommand로 자동 등록 못 함(project-c는 EC2라
# 가능했음) - apply 후 온프레미스 Keycloak 호스트에서 GRAFANA_ENDPOINT 환경변수를
# 아래 grafana_workspace_endpoint 출력값으로 채워 수동 실행할 것.
data "http" "keycloak_saml_metadata" {
  url      = "https://${var.onprem_keycloak_host}/realms/${var.keycloak_realm_name}/protocol/saml/descriptor"
  insecure = true
}

resource "aws_grafana_workspace_saml_configuration" "keycloak" {
  workspace_id     = aws_grafana_workspace.main.id
  idp_metadata_xml = data.http.keycloak_saml_metadata.response_body

  role_assertion  = "role"
  email_assertion = "email"
  login_assertion = "login"
  name_assertion  = "name"

  # 값은 keycloak-grafana-saml-client.sh가 실제로 등록하는 Keycloak 그룹
  # 이름과 정확히 일치해야 함 - 기본값 없음(variables.tf에서 채울 것).
  admin_role_values  = var.grafana_admin_role_values
  editor_role_values = var.grafana_editor_role_values
}

# 표준(엔터프라이즈) SOC 대시보드 자동 프로비저닝 - project-c 템플릿
# (docs/grafana/grafana-securityhub-standard-dashboard.json) 그대로 배포.
# grafana-dashboard-setup.sh는 SAML 로그인+서비스 계정 토큰 발급+데이터소스
# 생성까지 멱등 처리하므로 재실행해도 안전. 워크스페이스/SAML 클라이언트
# 전파 타이밍에 따라 일시 실패할 수 있어 재시도 루프를 둠.
resource "null_resource" "grafana_securityhub_standard_dashboard" {
  depends_on = [
    aws_grafana_workspace_saml_configuration.keycloak,
    aws_iam_role_policy.grafana_datasources,
  ]

  triggers = {
    dashboard_hash   = filemd5("${path.module}/docs/grafana/grafana-securityhub-standard-dashboard.json")
    grafana_endpoint = aws_grafana_workspace.main.endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      cd ${path.module}
      export GRAFANA_ENDPOINT="${aws_grafana_workspace.main.endpoint}"
      export KEYCLOAK_PUBLIC_IP="${var.onprem_keycloak_host}"
      export KEYCLOAK_USER="${var.grafana_provisioning_user}"
      export KEYCLOAK_PASSWORD="${var.keycloak_test_users_password}"
      export DASHBOARD_JSON="docs/grafana/grafana-securityhub-standard-dashboard.json"
      for i in $(seq 1 10); do
        if bash scripts/grafana-dashboard-setup.sh; then
          echo "표준 대시보드 프로비저닝 성공"
          exit 0
        fi
        echo "대시보드 프로비저닝 실패, 15초 후 재시도... ($i/10)"
        sleep 15
      done
      echo "표준 대시보드 프로비저닝 최종 실패" >&2
      exit 1
    EOT
  }
}

output "grafana_workspace_endpoint" {
  value = aws_grafana_workspace.main.endpoint
}

output "grafana_workspace_id" {
  value = aws_grafana_workspace.main.id
}

output "grafana_saml_configuration_status" {
  value = aws_grafana_workspace_saml_configuration.keycloak.status
}

# Athena "primary" 워크그룹 - OutputLocation이 비어있으면 StartQueryExecution이
# 성공해도 결과를 어디 쓸지 몰라 조용히 막힘.
resource "aws_athena_workgroup" "primary" {
  count = var.enable_security_lake ? 1 : 0
  name  = "primary"

  configuration {
    enforce_workgroup_configuration = false
    result_configuration {
      output_location = "s3://${split(":::", aws_securitylake_data_lake.main[0].s3_bucket_arn)[1]}/athena-results/"
    }
  }
}
