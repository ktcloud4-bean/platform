-- HR RDS(Aurora) PII 마스킹 뷰 - project-c의 employees/change_history 스키마
-- 기준(hr-app 코드베이스가 만드는 스키마와 동일할 것으로 가정 - platform-main의
-- 실제 스키마는 마이그레이션 Job 컨테이너 안에 있어 이 저장소에서 직접 확인은
-- 못 했음. 적용 전 실제 컬럼명과 대조할 것).
--
-- ⚠️ 전제조건: Aurora 클러스터에 iam_database_authentication_enabled=true가
-- 켜져 있어야 한다(tofu-app-db 소관, 확인 시점 기준 꺼져있음 - 43-demo-
-- scenario-resources.tf 주석 참고). 켜지 전까지는 이 스크립트의 IAM 인증
-- 역할(GRANT rds_iam)이 실제로는 못 쓰인다.
--
-- 두 개의 서로 다른 권한 축:
--   1) AWS IAM Role(observer/security-reader 등) - RDS에 접속할 수 있는가.
--   2) employees.is_hr 플래그 - 애플리케이션이 화면에 급여를 보여줄지 판단.
-- CloudShell/디버그 파드로 psql을 직접 여는 경로는 애플리케이션을 거치지
-- 않아 is_hr 체크가 실행되지 않으므로, 이 마스킹 뷰가 별도 방어선이 된다.
--
-- 적용: psql -h <aurora_writer_endpoint> -U hr_platform_admin -d hr_system -f hr-data-masking-views.sql
-- (호스트/DB명은 project-f의 terraform output rds_endpoint 및 tofu-app-db의
-- var.db_name 기본값 "hr_system" 기준. 마스터 사용자명도 tofu-app-db의
-- var.db_username 기본값 "hr_platform_admin" 기준 - 실제 값과 다르면 아래
-- GRANT hr_platform_admin 줄도 같이 바꿀 것.)

CREATE ROLE rds_pgaudit NOLOGIN;
CREATE EXTENSION IF NOT EXISTS pgaudit;

GRANT SELECT, INSERT, UPDATE, DELETE ON employees TO rds_pgaudit;
GRANT SELECT, INSERT, UPDATE, DELETE ON change_history TO rds_pgaudit;

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

  -- 아래 두 Role은 05번 시나리오(마스킹)엔 필요 없고 09번(DB 권한 드리프트
  -- 자동 복구, 30-rds-permission-drift-check.tf)에만 필요함.
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

-- remediation_admin/db_admin이 employees/change_history의 실질 소유자 권한을
-- 가져야 하는 이유: (1) information_schema.role_table_grants는 그랜터/그랜티/
-- 멤버/소유자 관계로만 보이므로, 이 GRANT가 없으면 다른 계정이 부여한 드리프트
-- GRANT를 아예 못 보고 REVOKE 대상에서 누락시킨다, (2) REVOKE 자체도 소유자
-- 권한 없이는 실행 못 함. db_username(tofu-app-db var.db_username 기본값
-- "hr_platform_admin")과 항상 일치해야 하므로, 실제 값이 다르면 아래도 바꿀 것.
GRANT hr_platform_admin TO remediation_admin;
GRANT hr_platform_admin TO db_admin;

CREATE SCHEMA IF NOT EXISTS masked;

-- salary만 가림. email/name/department/position/is_hr은 사내 조직도 수준
-- 정보로 그대로 노출(email은 change_history.changed_by 추적에도 필요).
CREATE OR REPLACE VIEW masked.employees_general AS
SELECT
  id, email, name, department, position, is_hr,
  NULL::integer AS salary
FROM employees;

CREATE OR REPLACE VIEW masked.employees_audit AS
SELECT
  id, email, name, department, position, is_hr,
  salary
FROM employees;

-- field_name='salary'인 행만 old_value/new_value를 가림.
CREATE OR REPLACE VIEW masked.change_history_general AS
SELECT
  id, employee_id, field_name,
  CASE WHEN field_name = 'salary' THEN '****' ELSE old_value END AS old_value,
  CASE WHEN field_name = 'salary' THEN '****' ELSE new_value END AS new_value,
  changed_by, department, reason, changed_at
FROM change_history;

CREATE OR REPLACE VIEW masked.change_history_audit AS
SELECT
  id, employee_id, field_name, old_value, new_value,
  changed_by, department, reason, changed_at
FROM change_history;

REVOKE ALL ON employees FROM PUBLIC;
REVOKE ALL ON change_history FROM PUBLIC;
REVOKE ALL ON employees, change_history FROM general_user_readonly, security_auditor_readonly;

GRANT USAGE ON SCHEMA masked TO general_user_readonly, security_auditor_readonly;
GRANT SELECT ON masked.employees_general, masked.change_history_general TO general_user_readonly;
GRANT SELECT ON masked.employees_audit, masked.change_history_audit TO security_auditor_readonly;

-- 확인:
--   SET ROLE general_user_readonly;
--   SELECT * FROM masked.employees_general LIMIT 5;
--   RESET ROLE;
