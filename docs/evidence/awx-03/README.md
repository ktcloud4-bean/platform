# AWX-03 완료 증거

2026-08-13 `ARGO-ROOT` 잠금 아래 최종 선언을 root
`04c5de35a24e383409cb47346838a9fa07d96c60`, AWX
`061c04d38df9fa396004de90a37ac2fa53451df5`로 고정해 검증했다.

- 적용 전 socket·Service 실측: Operator→Kubernetes API `443`, web/task→`postgres-01:5432`,
  task→web `8052`; `sso`는 내부 Traefik 경로 `443`으로 해석됐다.
- `AWX03_POLICY=PASS`: 기본 deny와 16개 정확한 NetworkPolicy, root/AWX
  `Synced/Healthy`를 확인했다.
- `AWX03_PATHS=PASS`: web의 PostgreSQL·Keycloak, task의 PostgreSQL·web, Operator API 경로가
  통과했고 기본 deny Pod의 `postgres-01:22`는 차단됐다.
- OIDC/Pomerium과 execution Pod를 쓰는 사람 MFA 검증에서 허용 job `27`, 승인 workflow `28`이
  성공했고 direct apply·approval·특권 계정 execute/권한 관리는 모두 `403`이었다.

첫 고정 적용은 AppProject의 NetworkPolicy allowlist 누락으로 sync가 거부됐다. allowlist 추가 후
Vault Hook selector가 AND로 해석되어 Vault `8200`이 차단된 것을 Agent의 `connect: connection refused`
로그로 확인했고, verifier와 Hook selector를 분리해 최종 재검증했다.

검증 종료 시 AWX child를 시작 main `ac747025c68ff5b16067b81921fbd2beca8d27e2`으로 먼저 복원해
NetworkPolicy 0건을 확인한 뒤 root도 literal `main`과 `Synced/Healthy`로 복원했다. OPNsense,
공개 DNS/NAT, AWX CR·DB·PVC·runtime Secret은 변경하거나 삭제하지 않았다.
