# ADR-0007: 탐지·관측의 역할과 배포 순서

- 상태: `Accepted`
- 날짜: 2026-07-30
- 관련 작업: `NIDS-01`, `CORAZA-01`, `POL-01`, `FALCO-01`, `AUDIT-01`, `LOKI-01`, `OBS-01`, `WAZUH-01`, `SOAR-DASH-01`, `SOAR-01`, `NIPS-01`

## 배경

네트워크 IDS, WAF, Kubernetes 정책, 런타임 탐지, 로그·메트릭과 SIEM은 보는 계층과 대응 권한이 다르다. 이를 Wazuh 하나로 통합하거나 초기부터 자동 차단하면 원인 구분이 어려워지고 오탐이 네트워크와 복구 경로를 끊을 수 있다. 관측·SIEM·SOAR는 현재 단일 노드에서 큰 자원을 사용한다.

## 결정

Suricata는 OPNsense에서 프로젝트의 north-south와 라우팅된 VLAN 흐름을 보는 alert-only IDS로 시작한다. HTTP 본문은 Traefik에서 복호화된 뒤 Coraza와 OWASP CRS가 검사한다. Pod 간 통신은 NetworkPolicy, 정책 위반은 Kyverno, 컨테이너·노드 런타임 행위는 Falco가 담당한다.

보안 이벤트는 각 소스에서 Wazuh로 직접 수집하고 Wazuh Dashboard에서 조사한다. 서비스와 수집기의 운영 로그는 Loki, 숫자형 상태와 경보는 Prometheus·Alertmanager·Grafana가 소유한다. Loki, kube-prometheus-stack, Wazuh와 Shuffle은 핵심 플랫폼과 복구 경로가 안정된 뒤 하나씩 배포하고 매 단계 capacity gate를 확인한다.

Wazuh active response와 방화벽 자동 차단은 사용하지 않는다. Shuffle은 read-only 정보 보강과 사람 승인 흐름부터 시작한다. Suricata IPS는 정상 트래픽, 오탐, 처리량과 즉시 rollback을 검증한 규칙만 조건부로 승격한다.

## 검토한 대안

- **Suricata IPS를 Day 1부터 사용:** 차단 효과는 있지만 오탐과 성능 문제가 전체 네트워크를 중단시킬 수 있다.
- **모든 로그를 Wazuh로 통합:** 도구 수는 줄지만 운영 로그·메트릭과 보안 이벤트의 목적·보존·용량이 섞인다.
- **관측 스택을 플랫폼보다 먼저 배포:** 초기 가시성은 높지만 큰 워크로드가 기반 서비스 구축과 복구 검증을 지연시킨다.

## 결과

- 초기 기준선은 예방보다 탐지와 증거 품질을 우선한다.
- 같은 사건을 여러 계층에서 상관분석할 수 있지만 수집 파이프라인이 늘어난다.
- 관측 스택이 늦게 배포되므로 그전에는 제품 로컬 로그와 직접 상태 검증이 필요하다.
- 자동 대응은 검증된 incident runbook 없이는 활성화되지 않는다.

## 재검토 조건

- 핵심 서비스 이후 CPU·RAM·disk 여유가 측정된다.
- 경보 분류, 보존기간과 오탐 기준이 합의된다.
- 반복 가능한 수동 대응과 rollback runbook이 검증된다.
