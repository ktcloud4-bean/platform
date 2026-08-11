# HR 직원 포털 권한 운영

`AWS-HR-03-FIX-01`은 [portal-group-members.json](../../gitops/tools/aws-hr-03/portal-group-members.json)을
HR 포털 Keycloak group membership의 단일 원본으로 사용한다. 사용자 생성, 비활성화, 삭제,
Pomerium·Dashy·AWS 변경과 HR DB 직원 원장 변경은 이 절차의 범위가 아니다.

| 대상 | Keycloak group 결과 | 포털 결과 |
|---|---|---|
| `imcherry5778` | `/hr-admins` | `www`·`admin` admission 허용 |
| `foxgeun`, `jaeeyun` | `/hr-users`, `/hr-admins` | `www`·`admin` admission 허용 |
| `cerberos2022`, `snsd-hybirdinfra` | `/hr-users` | `www` admission 허용, `admin` 거부 |

권한을 추가하거나 회수할 때는 먼저 JSON 선언만 수정하고 PR 검토 뒤 다음 명령을 사용한다. 명령은
enabled user exact match, 선언된 `/hr-users`·`/hr-admins` 단일 membership, 선언에 없는 일상 ID의
`/hr-admins` membership 0건을 확인한다. 예상하지 않은 관리자 membership은 자동으로 삭제하지 않고
실패한다.

```bash
gitops/tools/aws-hr-03/manage-employee-portal-users.sh --check
gitops/tools/aws-hr-03/manage-employee-portal-users.sh --apply
gitops/tools/aws-hr-03/manage-employee-portal-users.sh --check
```

`www.imcherry5778.xyz` 경로 admission은 Keycloak group만으로 결정하지만, 직원 정보·급여 등의 애플리케이션
기능은 HR DB에 해당 직원 record가 있는지와 별개로 판정한다. HR DB record 생성·수정은 정확한 인사 원장 값과
별도 승인으로만 수행한다. 이미 로그인한 사용자는 Keycloak group claim을 새로 받도록 로그아웃 후 다시 로그인한다.
