# OBS-17 완료 증거

- 검증일: 2026-08-13
- 범위: Warpgate systemd·ACME timer와 private TLS 만료 경보
- 금지 범위: public DNS/NAT·새 외부 노출·인증서 재발급·합성 장애·서비스 재기동은 변경하지 않았다.

## immutable GitOps 검증

`platform-root` `6687d26af1577335feac9f5694c07cde9c5f7a69`와 `obs`
`05af5367c623c2eeca1bd9f9e49e804c15333930`가 각각 `Synced/Healthy`인
immutable SHA에서 `gitops/tools/obs-17/verify-live.sh`를 한 번 실행해 `ALL PASS`를
확인했다. 검증 뒤 두 Application은 literal `main`
`d207ffc6b810daf9733f853ecab7f5cd7c837c55`의 `Synced/Healthy`로 복구했다.

## 완료 조건

| 항목 | 결과 |
|---|---|
| systemd metric | `warpgate.service=active`, `warpgate-acme-renew.timer=active`, one-shot `warpgate-acme-renew.service=inactive` |
| private TLS | `probe_success=1`, 인증서 잔여 기간 78일로 14일 초과 |
| 경보 수신 경로 | 세 OBS-17 alertname이 기존 `obs-13-receiver` matcher에 정확히 포함 |
| Pod egress | blackbox Pod의 `10.10.30.10/32` TCP 8888 exact NetworkPolicy |
| OPNsense | `opt2` sequence `1013`, UUID `98957500-c698-4c3b-a241-a56db40d69ca`, k3s-01→warpgate-01 TCP 8888 exact PASS 및 정상 drift |

Flannel IP masquerade와 Warpgate host listener/firewall은 변경하지 않았다. 실패 원인은
처음에는 OPNsense rule이 non-public BLOCK 뒤에 있던 순서, 이어서는 TCP 8888 egress를
Grafana policy에 넣었던 selector 오류였다. 최종 상태는 rule을 BLOCK 앞 `1013`에 두고
blackbox selector에만 exact egress를 둔다.

## Rollback

`WarpgateServiceDown`·`WarpgateACMERenewTimerDown`·
`WarpgateTLSCertificateExpiringSoon`, blackbox target, 해당 NetworkPolicy egress 및
UUID `98957500-c698-4c3b-a241-a56db40d69ca`의 OPNsense rule만 제거한다. 기존
node_exporter·Traefik TLS probe·다른 Alertmanager route·public 경계는 보존한다.
