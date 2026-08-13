# OBS-18 완료 증거

- 검증일: 2026-08-13
- 범위: Alertmanager의 #platform-alerts Slack firing·resolved 통지 경로
- 금지 범위: 기존 k3s 공용 HTTPS egress, public DNS/NAT·외부 노출, 기존 internal receiver와 보안 Slack 채널은 변경하지 않았다.

## 불변 GitOps 검증

platform-root 27262d35eb5d49833ff431ff0ce0b6db7fba64fc와 obs
2b7da5b37797b70634dd9b92c7b6880de30f7584가 각각 Synced/Healthy인
불변 SHA에서 검증했다. 검증 뒤 두 Application은 literal main
83d7c833cfffe27f40f3f63d693b6de6e1230d35의 Synced/Healthy로 복구했다.

## 완료 조건

| 항목 | 결과 |
|---|---|
| Vault 주입 | 전용 kv/obs/alertmanager의 단일 field와 별도 Kubernetes auth policy·role만 사용하고, Alertmanager 파일은 0440으로 렌더링 |
| Alertmanager 경로 | critical은 firing·resolved 모두 @channel, warning은 무멘션, info는 route 없음; webhook 값은 api_url_file로만 참조 |
| Pod egress | Alertmanager는 Vault TCP 8200 및 내부 CONNECT proxy TCP 8444 exact NetworkPolicy만 보유 |
| 외부 egress | hostNetwork proxy가 10.10.20.11에서 hooks.slack.com:443으로 연결하고, OPNsense FQDN alias OBS18_SLACK_HOST와 opt2 sequence 1023 PASS rule이 그 TCP 경로만 허용 |
| payload 경계 | proxy는 Pod CIDR·k3s source만 받고 CONNECT hooks.slack.com:443만 허용하며, notifier는 alertname·severity·instance·시각·Grafana link만 전달 |
| 일회성 테스트 | [TEST] critical 한 건을 자동 만료해 Alertmanager API에서 제거되고 internal receiver의 firing·resolved 카운터가 각각 한 번씩 증가 |
| Slack 수신 | 사용자가 #platform-alerts 화면에서 같은 test의 FIRING(11:35:26 UTC)과 RESOLVED(11:36:56 UTC)를 모두 확인 |
| 복구·drift | 테스트 뒤 platform-root·obs는 literal main으로 복구했고 OPNsense 정규화 스냅샷 갱신 뒤 normal drift 없음 |

resolved는 Alertmanager의 다음 group 전송 주기 뒤에 발송되므로, verifier는 API에서 test alert가
사라진 것만으로 성공 처리하지 않고 internal receiver의 resolved 수신까지 대기한다. 이로써
Argo 복구가 resolved 통지보다 먼저 실행되는 것을 막는다.

## Rollback

검증 중에는 platform-root만 literal main으로 되돌려 proxy·Slack route를 prune하는 rollback을
확인했다. 영구 rollback은 OBS-18 ConfigMap·proxy Deployment/Service/SA·NetworkPolicy·Vault
role/policy/KV field·전용 source IP·OPNsense alias/rule만 제거하며, 기존 Alertmanager receiver·
공용 HTTPS egress·다른 Slack 채널은 보존한다.
