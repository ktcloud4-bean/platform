# OBS-16-FIX-01 native metric 경보 receiver 증거

2026-08-13에 OBS-16의 두 native metric 경보가 기본 `discard`로 떨어지던 route 누락을
기존 내부 `obs-13-receiver` matcher 확장만으로 보정한 결과다. service·exporter·방화벽을
멈추거나 alert rule의 임계값·`for`를 바꾸지 않았다. Secret, token, S3 object name, query text와
peer identity는 기록하지 않는다.

## 변경과 rollback

- `NativeMetricsTargetDown`과 `PostgreSQLDatabaseMetricsDown`만 기존 `obs-13-receiver`
  matcher에 추가했다. 기존 5개 alertname route, 기본 `discard`, receiver·NetworkPolicy와
  외부 egress는 불변이다.
- rollback은 `values-kube-prometheus-stack-01.yaml`과 재생성 `install.yaml`의 해당 두
  alertname만 matcher에서 제거한다. 서비스·exporter·방화벽에는 rollback 대상이 없다.

## 완료 증거

| 항목 | 결과 |
|---|---|
| immutable GitOps | root `1bffd29e258c7c09bb8df0c357c4b6db3d41392f`, obs `c74d88a0fc662c92ac6ed92309f379b282673432`에서 `Synced/Healthy` |
| runtime route | Alertmanager 생성 설정의 `obs-13-receiver` matcher가 기존 5개와 `NativeMetricsTargetDown`·`PostgreSQLDatabaseMetricsDown` 두 alertname을 정확히 포함 |
| baseline | 두 native metric alert가 active 0건 |
| 수신 검증 | `NativeMetricsTargetDown`, `severity=critical`, `test=true`, 만료 시각을 가진 Alertmanager test alert 정확히 한 건이 receiver에 firing 1회 수신 |
| 자동 만료 | 같은 test alert가 자동 만료됐고 Alertmanager test alert 0건 및 receiver resolved 1회 수신 |
| 종료 상태 | `platform-root`·`obs`가 literal `main`, revision `60cad6c5b6278fc384df1d2757ac3efca3490864`에서 `Synced/Healthy` |
