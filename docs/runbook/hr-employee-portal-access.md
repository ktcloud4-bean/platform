# HR 직원 포털 권한 운영

`AWS-HR-03`은 팀 일상 Keycloak ID에 HR 직원 포털 admission만 부여한다. 사용자 생성, 비활성화,
삭제, HR 관리자 승격, Pomerium·Dashy·AWS 변경과 HR DB 직원 원장 변경은 이 절차의 범위가 아니다.

| 대상 | Keycloak group 결과 | 포털 결과 |
|---|---|---|
| `imcherry5778` | 기존 `/hr-admins` 유지 | `www`·`admin` admission 유지 |
| `foxgeun`, `cerberos2022`, `jaeeyun`, `snsd-hybirdinfra` | `/hr-users`만 부여 | `www` admission 허용, `admin` 거부 |

실행 전과 후에는 다음 명령을 사용한다. 명령은 enabled user exact match, `/hr-users` 단일 membership,
대상 네 사용자의 `/hr-admins` membership 0건을 확인한다. 어느 하나라도 성립하지 않으면 변경하지 않고
실패한다.

```bash
gitops/tools/aws-hr-03/manage-employee-portal-users.sh --check
gitops/tools/aws-hr-03/manage-employee-portal-users.sh --apply
gitops/tools/aws-hr-03/manage-employee-portal-users.sh --check
```

`www.imcherry5778.xyz` 경로 admission은 Keycloak group만으로 결정하지만, 직원 정보·급여 등의 애플리케이션
기능은 HR DB에 해당 직원 record가 있는지와 별개로 판정한다. HR DB record 생성·수정은 정확한 인사 원장 값과
별도 승인으로만 수행한다. 이미 로그인한 사용자는 Keycloak group claim을 새로 받도록 로그아웃 후 다시 로그인한다.
