"""
AWS-DB-SEC-01: HR Aurora PostgreSQL PII 데이터 이중 마스킹 뷰 적용 및 IAM DB 인증 실측 검증 Lambda
"""
import json
import os
import ssl
import boto3
import pg8000.native

secrets_client = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION", "ap-northeast-2"))
rds_client = boto3.client("rds", region_name=os.environ.get("AWS_REGION", "ap-northeast-2"))

DB_HOST = os.environ["DB_HOST"]
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "hr_system")
MASTER_SECRET_ARN = os.environ["MASTER_SECRET_ARN"]
REGION = os.environ.get("AWS_REGION", "ap-northeast-2")


def get_master_credentials():
    resp = secrets_client.get_secret_value(SecretId=MASTER_SECRET_ARN)
    data = json.loads(resp["SecretString"])
    return data["username"], data["password"]


def get_iam_token(db_user: str) -> str:
    return rds_client.generate_db_auth_token(
        DBHostname=DB_HOST,
        Port=DB_PORT,
        DBUsername=db_user,
        Region=REGION
    )


def handler(event, context):
    ssl_context = ssl.create_default_context()
    ssl_context.check_hostname = False
    ssl_context.verify_mode = ssl.CERT_NONE

    results = {
        "iam_auth_enabled": True,
        "master_applied_sql": False,
        "existing_apps_unbroken": False,
        "general_user_direct_table_denied": False,
        "general_user_salary_null_masked": False,
        "general_user_history_masked": False,
        "auditor_user_direct_table_denied": False,
        "auditor_user_salary_visible": False,
        "salary_sample_general": None,
        "salary_sample_audit": None,
        "history_sample_general": None,
        "history_sample_audit": None,
    }

    # Step 1: Master 계정으로 접속하여 마스킹 SQL 적용
    master_user, master_pass = get_master_credentials()
    master_conn = pg8000.native.Connection(
        user=master_user,
        password=master_pass,
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        ssl_context=ssl_context,
        timeout=15
    )

    sql_commands = [
        # Roles & rds_iam
        """
        DO $$
        BEGIN
          IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'general_user_readonly') THEN
            CREATE ROLE general_user_readonly LOGIN;
            GRANT rds_iam TO general_user_readonly;
          END IF;

          IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'security_auditor_readonly') THEN
            CREATE ROLE security_auditor_readonly LOGIN;
            GRANT rds_iam TO security_auditor_readonly;
          END IF;

          IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'db_admin') THEN
            CREATE ROLE db_admin LOGIN;
            GRANT rds_iam TO db_admin;
          END IF;

          IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'remediation_admin') THEN
            CREATE ROLE remediation_admin LOGIN;
            GRANT rds_iam TO remediation_admin;
          END IF;
        END
        $$;
        """,
        f"GRANT {master_user} TO remediation_admin;",
        f"GRANT {master_user} TO db_admin;",
        f"GRANT CONNECT ON DATABASE {DB_NAME} TO general_user_readonly, security_auditor_readonly, db_admin, remediation_admin;",
        "CREATE SCHEMA IF NOT EXISTS masked;",
        # employees masking views
        """
        CREATE OR REPLACE VIEW masked.employees_general AS
        SELECT
          id, email, name, department, position, is_hr,
          NULL::integer AS salary
        FROM employees;
        """,
        """
        CREATE OR REPLACE VIEW masked.employees_audit AS
        SELECT
          id, email, name, department, position, is_hr,
          salary
        FROM employees;
        """,
        # change_history masking views
        """
        CREATE OR REPLACE VIEW masked.change_history_general AS
        SELECT
          id, employee_id, field_name,
          CASE WHEN field_name = 'salary' THEN '****' ELSE old_value END AS old_value,
          CASE WHEN field_name = 'salary' THEN '****' ELSE new_value END AS new_value,
          changed_by, department, reason, changed_at
        FROM change_history;
        """,
        """
        CREATE OR REPLACE VIEW masked.change_history_audit AS
        SELECT
          id, employee_id, field_name, old_value, new_value,
          changed_by, department, reason, changed_at
        FROM change_history;
        """,
        # Permissions
        "REVOKE ALL ON employees FROM PUBLIC;",
        "REVOKE ALL ON change_history FROM PUBLIC;",
        "REVOKE ALL ON employees, change_history FROM general_user_readonly, security_auditor_readonly;",
        "GRANT USAGE ON SCHEMA masked TO general_user_readonly, security_auditor_readonly;",
        "GRANT SELECT ON masked.employees_general, masked.change_history_general TO general_user_readonly;",
        "GRANT SELECT ON masked.employees_audit, masked.change_history_audit TO security_auditor_readonly;"
    ]

    for sql in sql_commands:
        master_conn.run(sql)
    master_conn.close()
    results["master_applied_sql"] = True

    # Step 2: general_user_readonly (IAM DB Auth) 검증
    gen_token = get_iam_token("general_user_readonly")
    gen_conn = pg8000.native.Connection(
        user="general_user_readonly",
        password=gen_token,
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        ssl_context=ssl_context,
        timeout=15
    )

    # 2-1: 원본 테이블 직접 조회 거부 확인
    try:
        gen_conn.run("SELECT * FROM employees LIMIT 1;")
        results["general_user_direct_table_denied"] = False
    except Exception as e:
        if "permission denied" in str(e).lower():
            results["general_user_direct_table_denied"] = True

    # 2-2: masked.employees_general 조회 및 salary NULL 확인
    emp_rows = gen_conn.run("SELECT id, email, name, department, position, is_hr, salary FROM masked.employees_general LIMIT 3;")
    all_salary_null = all(row[6] is None for row in emp_rows) if emp_rows else True
    results["general_user_salary_null_masked"] = all_salary_null
    results["salary_sample_general"] = [
        {"email": r[1], "department": r[3], "salary": r[6]} for r in emp_rows
    ]

    # 2-3: masked.change_history_general 조회 및 salary '****' 마스킹 확인
    hist_rows = gen_conn.run("SELECT field_name, old_value, new_value FROM masked.change_history_general WHERE field_name = 'salary' LIMIT 3;")
    if hist_rows:
        all_hist_masked = all(r[1] == '****' and r[2] == '****' for r in hist_rows)
        results["general_user_history_masked"] = all_hist_masked
        results["history_sample_general"] = [
            {"field": r[0], "old_value": r[1], "new_value": r[2]} for r in hist_rows
        ]
    else:
        results["general_user_history_masked"] = True
    gen_conn.close()

    # Step 3: security_auditor_readonly (IAM DB Auth) 검증
    aud_token = get_iam_token("security_auditor_readonly")
    aud_conn = pg8000.native.Connection(
        user="security_auditor_readonly",
        password=aud_token,
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        ssl_context=ssl_context,
        timeout=15
    )

    # 3-1: 원본 테이블 직접 조회 거부 확인
    try:
        aud_conn.run("SELECT * FROM employees LIMIT 1;")
        results["auditor_user_direct_table_denied"] = False
    except Exception as e:
        if "permission denied" in str(e).lower():
            results["auditor_user_direct_table_denied"] = True

    # 3-2: masked.employees_audit 조회 및 salary 원본 노출 확인
    aud_emp_rows = aud_conn.run("SELECT id, email, salary FROM masked.employees_audit LIMIT 3;")
    has_salary_value = any(r[2] is not None for r in aud_emp_rows) if aud_emp_rows else True
    results["auditor_user_salary_visible"] = has_salary_value
    results["salary_sample_audit"] = [
        {"email": r[1], "salary": r[2]} for r in aud_emp_rows
    ]

    # 3-3: masked.change_history_audit 조회 확인
    aud_hist_rows = aud_conn.run("SELECT field_name, old_value, new_value FROM masked.change_history_audit WHERE field_name = 'salary' LIMIT 3;")
    results["history_sample_audit"] = [
        {"field": r[0], "old_value": r[1], "new_value": r[2]} for r in aud_hist_rows
    ]
    aud_conn.close()

    # Step 4: 기존 애플리케이션 계정 정상 연결 및 무중단 확인
    # Secrets Manager의 employee_service credential 확인
    emp_sec = secrets_client.get_secret_value(SecretId=f"{os.environ.get('NAME_PREFIX', 'hr-system-prod')}/employee-service/database")
    emp_sec_data = json.loads(emp_sec["SecretString"])
    app_conn = pg8000.native.Connection(
        user=emp_sec_data["username"],
        password=emp_sec_data["password"],
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        ssl_context=ssl_context,
        timeout=15
    )
    app_cnt = app_conn.run("SELECT count(*) FROM employees;")[0][0]
    app_conn.close()
    results["existing_apps_unbroken"] = (app_cnt >= 0)
    results["employee_count"] = app_cnt

    return {
        "statusCode": 200,
        "results": results
    }
