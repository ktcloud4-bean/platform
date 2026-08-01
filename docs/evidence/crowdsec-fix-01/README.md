# CROWDSEC-FIX-01 검증 증거

이 디렉터리는 `CROWDSEC-01` live 적용에서 발견한 CRS ConfigMap 바이트
훼손과 AppProject prune 순서 결함을 보정하고, ADR-0012의 기능·성능·
장애·rollback gate를 재수행한 결과를 소유한다.

## 2026-08-01 시작 기준선

- branch/worktree: `task/crowdsec-fix-01`, `platform-crowdsec-fix-01`
- 시작 main: `87112193df5e156b4d9038ca3e83f3413ab16b11`
- Argo `platform-root`·`ingress`·`keycloak`: 모두 같은 main SHA에서
  `Synced/Healthy`
- packaged Traefik: generation `5`, Pod UID
  `5e3bd6ee-395f-4459-b4b6-9e358dd4b8c9`, restart `0`, image digest
  `sha256:fcdef599e6259359833dd2e1d49f9e964f66825d69bd3dd468f51102ce013d03`
- CrowdSec Application·AppProject·namespace와 HCC plugin marker: 없음
- Node: `Ready=True`, `DiskPressure=False`; 비정상 Pod 없음

`CROWDSEC-01` 실패 시 원본 CRS 49개는 모두 LF로 끝났지만 Helm template의
YAML `|-` block scalar는 렌더된 ConfigMap value에서 마지막 LF를 제거했다.
결과는 `files=49 mismatches=49`였다. 소스 디렉터리를 bind mount한 기존
Docker 검증은 Kubernetes API 직렬화를 통과하지 않아 이 결함을 놓쳤다.

rollback 중에는 root prune이 `AppProject/crowdsec`를 Application보다 먼저
제거해 Application finalizer가 `project not found`로 멈춰다. 비밀이 없는 Project를
임시 복원한 뒤에야 namespace와 하위 자원을 정상 prune할 수 있었다.

## 승인된 main 3커밋 경계

1. 영구 최소 `AppProject/crowdsec` 기반. Application·HelmChartConfig·workload를
   만들지 않으므로 Traefik을 재기동하지 않는다.
2. byte-preserving snapshot과 수정 enablement. 적용 직전 `KC-01` 상태와
   시점을 다시 확인한 뒤 Traefik을 한 번만 재생성한다.
3. 모든 live gate를 통과한 경우에만 evidence와 `CROWDSEC-FIX-01 DONE`을
   기록한다.

gate 실패 시 2번 enablement 커밋만 `git revert`하고, 1번의 영구
AppProject는 남겨 Application finalizer의 정상 prune 경계를 보장한다.

## 미완료 증거

- deterministic CRS archive·archive SHA-256·내부 49개 hash
- Kubernetes API round-trip 후 archive·파일 hash 일치
- packaged Traefik `3.7.4` 격리 호환과 공급망 고정 재검증
- 전용 WAF/control route 기능·exact rule `913100` 예외
- 3 round p95·CPU·RSS, AppSec fail-closed, 기존 ingress 전체 회귀
- Application finalizer prune·Argo rollback·merge 후 Git revert
- Git history·diff의 secret 원문 0건
