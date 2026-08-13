# ADR-0025: Alertmanager Slack egress를 전용 source identity와 CONNECT allowlist로 분리

- 상태: `Accepted`
- 관련 작업: `OBS-18`

## 배경

단일 k3s node의 기존 공용 HTTPS egress는 여러 GitOps·운영 의존성이 함께 사용한다.
같은 source를 유지한 채 Slack FQDN alias를 추가하면 기존 포괄 rule이 먼저 허용하므로,
Slack 목적지 제한이라는 결과가 생기지 않는다. FQDN alias는 방화벽의 L3 목적지 주소
집합을 좁히지만 TLS CONNECT 요청의 hostname까지 판정하지 않는다.

## 결정

Alertmanager Slack 수신기는 클러스터 내부 전용 CONNECT proxy를 경유한다. proxy 한
Pod만 node의 전용 source identity에 bind해 외부 TCP 443을 시작하고, OPNsense는 그
source에서 Slack FQDN alias TCP 443만 허용한다. proxy는 CONNECT method와 Slack hostname을
고정해 L3 alias와 별도로 hostname 경계를 강제한다.

- Alertmanager는 Vault에서 읽은 webhook을 파일로만 사용하고 proxy에는 credential을
  전달하지 않는다.
- Alertmanager egress는 Vault와 내부 proxy의 필요한 port만 허용한다.
- proxy는 host network를 쓰되 token 없이 non-root·read-only filesystem·capability drop으로
  실행하며, 허용한 Pod CIDR/node source만 client로 받는다.
- 기존 공용 source의 HTTPS egress와 Slack 전용 source의 외부 egress를 분리해, 기존
  클러스터 의존성을 좁히거나 재설계하지 않는다.

## 검토한 대안

1. 기존 공용 HTTPS rule 아래 Slack FQDN alias만 추가: 먼저 일치하는 공용 rule이 남아
   있어 실질적인 목적지 제한이 되지 않는다.
2. 공용 source의 모든 HTTPS egress를 FQDN alias로 교체: image pull·GitOps·인증서 등
   기존 의존성을 함께 재설계해야 해 OBS-18 범위를 넘는다.
3. Alertmanager가 Slack으로 직접 연결: 방화벽이 Alertmanager 전용 송신을 구분할 source
   identity가 없고 hostname 방어도 한 계층에 의존한다.

## 결과

Slack webhook은 전용 Vault policy·role과 memory volume 안에만 존재한다. 외부 목적지는
방화벽 FQDN alias와 proxy CONNECT allowlist 두 계층으로 제한되고, 기존 공용 HTTPS
egress의 동작은 보존된다. proxy와 전용 source identity가 추가되어 단일 node 장애 도메인과
운영 절차가 늘어난다.

## 재검토 조건

- k3s node가 늘어나거나 egress source identity를 node별로 보장할 수 없을 때
- Slack hostname 또는 HTTPS proxy 요구가 바뀔 때
- 일반적인 egress gateway, mTLS-aware proxy 또는 central policy enforcement가 도입될 때
