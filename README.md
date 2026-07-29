# platform

단일 물리 노드에서 제로 트러스트 플랫폼을 재현하는 온프레미스 랩이다. 프로덕션과 비슷한 통제·자동화·복구 절차를 구현하지만, 장비 한 대의 SPOF를 HA로 가장하지 않는다.

## 범위

```text
OPNsense → Proxmox → Rocky Linux VM → k3s → 플랫폼 서비스
```

이 저장소가 소유하는 것은 다음과 같다.

- OPNsense 구성 스냅샷과 안전한 변경 절차
- Proxmox 설치 재현성, VM과 OS 자동화
- k3s GitOps, 통합인증, 접근제어, 공급망 보안
- 백업·복구와 온프레미스 ↔ AWS 연결

애플리케이션 소스와 HOME 네트워크의 내부 구성은 범위 밖이다.

## 문서 원본

| 질문 | 단일 원본 |
|---|---|
| 지금 무엇을 할 수 있는가 | [`docs/backlog.md`](docs/backlog.md) |
| 무엇을 어디에 두는가 | [`docs/architecture.md`](docs/architecture.md) |
| IP·VLAN·DNS는 무엇인가 | [`docs/ip-plan.md`](docs/ip-plan.md) |
| OPNsense를 어떻게 운영하는가 | [`infra/opnsense/README.md`](infra/opnsense/README.md) |
| 검증된 현장 절차는 무엇인가 | [`docs/runbook/`](docs/runbook/) |

같은 값을 두 문서에 적지 않는다. 현재 상태는 백로그, 목표 구조는 아키텍처, 주소는 IP 계획이 소유한다.

## 저장소 구조

```text
docs/          아키텍처 · 주소 계획 · 백로그 · runbook
infra/         OPNsense · Proxmox · VM · OS 자동화
gitops/        Argo CD가 적용할 Kubernetes 선언
policies/      Kyverno · NetworkPolicy · 서명 검증 정책
```

`gitops/`와 `policies/`는 해당 기반이 준비되는 백로그 작업에서 만든다. 빈 구조를 미리 만들지 않는다.

## 계층별 Git의 역할

| 계층 | 방식 | 드리프트 처리 |
|---|---|---|
| OPNsense | 마스킹한 스냅샷으로 기록 | 알림 후 사람이 승인·교정 |
| Proxmox VM | OpenTofu | `plan` 검토 후 사람이 적용 |
| VM OS | Ansible | `--check` 검토 후 사람이 적용 |
| k3s | Argo CD | 선언 상태로 지속 교정 |

베어메탈을 무인 자동 교정하면 복구 경로까지 끊을 수 있다. 자동화 강도는 계층마다 달라야 한다.

## 운영 원칙

1. UI나 콘솔에서 바꾼 내용도 같은 날 Git에 기록한다.
2. 복구 경로는 복구 대상과 Keycloak에 의존하지 않는다.
3. 하나의 물리 노드에 여러 VM을 두는 것은 격리이지 HA가 아니다.
4. 데이터 백업은 같은 NVMe의 스냅샷만으로 완료 처리하지 않는다.
5. 서비스는 필요한 시점에 추가하고, 관측 도구 자체가 선행 구축을 막지 않게 한다.

## 시크릿

- Git에는 참조와 정책만 두고 값은 Vault에 둔다.
- Vault 이전의 부트스트랩 값은 저장소 밖에서 최소 기간만 보관한다.
- OPNsense 원본 백업, tfstate, kubeconfig, Shamir share와 root token은 Git 금지다.
- 예제 파일에는 실제와 다른 명백한 자리표시자만 사용한다.
