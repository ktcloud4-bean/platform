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

## 영구 기반 적용 결과

첫 main commit `161debf143d61f8e621ce25b25e601e0c5c207a7` 뒤 Argo
`platform-root`는 해당 SHA에서 `Synced/Healthy`이고 `AppProject/crowdsec` 하나만
생성됐다. CrowdSec Application·namespace는 없으며 Traefik은 generation `5`, Pod UID
`5e3bd6ee-395f-4459-b4b6-9e358dd4b8c9`, restart `0`으로 시작 기준선과 같다.

## byte-preserving 보정과 격리 결과

- source CRS 49개와 기존 manifest를 sorted ustar, mtime 0, owner/group 0, mode 0644,
  `gzip -n -9`로 묶었다. archive는 153,184 bytes이고 SHA-256은
  `235dc3bc50c3c861ba9561487c72d6562e8c6501467314a6618781a37bdaede6`이다.
- 공급망 verifier가 source 49개, manifest, deterministic rebuild, Helm
  `ConfigMap.binaryData`에서 decode한 archive와 AppSec YAML 3개의 byte hash를 확인했다.
  packaged chart는 358,527 bytes로 1MiB 미만이다.
- network 공급망 검증에서 고정 chart/source/plugin archive, Hub YAML과 Hub data
  49개가 기록된 hash와 모두 일치했다.
- Docker 격리에서 fixed CrowdSec image의 실제 `tar`·`sha256sum` init 명령과 packaged
  Traefik `3.7.4`+bouncer `v1.7.1`을 사용했다. 정상 200, rule `913100` 공격 403,
  exact URI+UA 예외만 200, 세 negative 예외 403, control 공격 200, decision 0개,
  AppSec 중단 시 WAF만 403/control 200, 복구 뒤 WAF 200을 확인했다. Traefik은
  running, OOMKilled false, restart 0이었다.
- live packaged chart archive/base values를 읽기만 해 수정 HCC를 격리 렌더했고 plugin
  module/version/hash, `/plugins-storage`, mode 0440 bouncer key mount와 기존 image를
  확인했다.
- `crowdsec-fix-01-verify` 격리 namespace의 실제 Kubernetes API에 ConfigMap을 저장했다.
  API JSON에서 decode한 archive와 AppSec YAML hash, Pod volume mount 뒤 archive와
  추출된 CRS 49개 hash가 모두 일치했다. 첫 실행의 마지막 중복 확인은 BusyBox가 GNU
  `sha256sum --quiet`를 지원하지 않아 실패했지만 Pod의 실제 init과 API hash는 이미
  통과했고 실패 trap이 namespace를 제거했다. 중복 확인을 `sha256sum -c`로 보정한
  두 번째 실행은 전부 통과했고 namespace를 다시 제거했다.
- full Helm render, root와 HCC는 live API server-side dry-run을 통과했다. Secret manifest는
  0개이고 Application targetRevision은 계속 `main`이다.

격리 검증 후 live root·ingress·keycloak은 foundation SHA에서 모두 `Synced/Healthy`,
AppProject는 존재하고 CrowdSec Application·검증 namespace는 없다. Traefik generation
`5`, UID `5e3bd6ee-395f-4459-b4b6-9e358dd4b8c9`, restart `0`도 불변이다.

## 미완료 증거

- 전용 WAF/control route 기능·exact rule `913100` 예외
- 3 round p95·CPU·RSS, AppSec fail-closed, 기존 ingress 전체 회귀
- Application finalizer prune·Argo rollback·merge 후 Git revert
- Git history·diff의 secret 원문 0건
