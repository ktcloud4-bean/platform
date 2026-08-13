# AWX-02 완료 증거

검증은 `ARGO-ROOT`, `IDENTITY-LIVE` 잠금 아래 2026-08-13에 수행했다. 검증 선언은 AWX/policy
child `346c88c1ce3dbb8131d9036947d31cd8460506c6`, root
`3b971793610457fd7c8520d892b24a9da5ef4b3c`로 고정했다.

- `verify-live.sh platform`: web/task 모든 container UID:GID `1000:0`, execution Pod non-root,
  정확한 migration mutation, AWX 만료 예외 부재, root/AWX/policy `Synced/Healthy`를 통과했다.
- 첫 SSO 뒤 서버 측 exact set은 `imcherry5778=Platform/AWX Operators`,
  `imcherry5778-admin=Platform/AWX Approvers`; legacy membership, superuser, organization admin은 모두 0건이다.
- `verify-live.sh secrets`: Git 추적 파일과 현재 AWX Pod 로그에서 secret 원문 0건을 통과했다.
- 사람 MFA 브라우저 증거: 허용 credential job `19` 성공, deny template/credential `403`; 일상 계정의
  apply/approval `403`, 특권 계정의 execute/permission 관리 `403`; 특권 계정 승인 뒤 workflow `20` 성공이다.

초기 실행 Pod는 `automation-job-*` 경로가 non-root context를 상속하지 않아 admission에서 거부됐다.
CR의 read-only execution queue Pod override로 이 경로만 보정했고, 광범위한 admission mutation은 추가하지 않았다.

검증 종료 시 policy-baseline, AWX, root 순으로 시작 main
`fa670d6b8fa88815e722d5208c1c98601003f812`에 복원해 세 Application이 `main`과
`Synced/Healthy`임을 확인했다. AWX CR, DB, PVC, runtime Secret은 삭제하지 않았다.
