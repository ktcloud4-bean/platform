-- =============================================================================
-- HR Aurora PostgreSQL PII 데이터 이중 마스킹 뷰 및 IAM DB 인증 역할 정의
-- =============================================================================

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

-- remediation_admin/db_admin이 employees/change_history 소유자 권한을 가짐
GRANT hr_platform_admin TO remediation_admin;
GRANT hr_platform_admin TO db_admin;

-- 데이터베이스 접속 권한 부여 (PostgreSQL 15+)
GRANT CONNECT ON DATABASE hr_system TO general_user_readonly, security_auditor_readonly, db_admin, remediation_admin;

CREATE SCHEMA IF NOT EXISTS masked;

-- 일반 사용자용 마스킹 뷰: salary 컬럼을 NULL로 가림
CREATE OR REPLACE VIEW masked.employees_general AS
SELECT
  id, email, name, department, position, is_hr,
  NULL::integer AS salary
FROM employees;

-- 감사자용 뷰: salary 컬럼 원본 노출
CREATE OR REPLACE VIEW masked.employees_audit AS
SELECT
  id, email, name, department, position, is_hr,
  salary
FROM employees;

-- 변경 이력 일반 사용자용 뷰: field_name='salary'인 경우 '****' 마스킹
CREATE OR REPLACE VIEW masked.change_history_general AS
SELECT
  id, employee_id, field_name,
  CASE WHEN field_name = 'salary' THEN '****' ELSE old_value END AS old_value,
  CASE WHEN field_name = 'salary' THEN '****' ELSE new_value END AS new_value,
  changed_by, department, reason, changed_at
FROM change_history;

-- 변경 이력 감사자용 뷰: 원본 값 노출
CREATE OR REPLACE VIEW masked.change_history_audit AS
SELECT
  id, employee_id, field_name, old_value, new_value,
  changed_by, department, reason, changed_at
FROM change_history;

-- 원본 테이블에 대한 직접 접근 권한 제한
REVOKE ALL ON employees FROM PUBLIC;
REVOKE ALL ON change_history FROM PUBLIC;
REVOKE ALL ON employees, change_history FROM general_user_readonly, security_auditor_readonly;

-- 마스킹 스키마 및 뷰 접근 권한 부여
GRANT USAGE ON SCHEMA masked TO general_user_readonly, security_auditor_readonly;
GRANT SELECT ON masked.employees_general, masked.change_history_general TO general_user_readonly;
GRANT SELECT ON masked.employees_audit, masked.change_history_audit TO security_auditor_readonly;
