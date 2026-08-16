# DEMO-ONPREM-01 완료 증거

## 판정

`DONE` — immutable 작업 SHA에서 네 독립 세션의 attack/control/evidence/reset을 완료하고,
검증용 선언과 합성 identity를 제거한 뒤 literal `main`으로 복구했다.

## 세션 증거

```text
DEMO_SESSION1_ATTACK=PASS device=unapproved route=absent
DEMO_SESSION1_CONTROL=PASS same_account=true same_session=true allow=200 restricted=403 groups=masked
DEMO_SESSION1_EVIDENCE=PASS pomerium_paths=allow+not-allowed wazuh_rule=100102 authorize_hits>=2 identities=masked
DEMO_SESSION2_ATTACK=PASS payload=fixed request_id=DEMO-ONPREM-01-S2 control=200 synthetic_rows=3
DEMO_SESSION2_CONTROL=PASS same_payload=true same_backend=true waf=403 crs_rule=942100
DEMO_SESSION2_EVIDENCE=PASS crowdsec_block=present wazuh_rule=100122 request=masked
DEMO_SESSION3_ATTACK=PASS source=demo-onprem-attacker destination=internal-api:8080 synthetic_flag=visible
DEMO_SESSION3_CONTROL=PASS same_source=true same_destination=internal-api:8080 networkpolicy=blocked
DEMO_SESSION3_FALCO=PASS rule=Interactive-Shell-in-Container events>=2 fields=masked
DEMO_SESSION3_WAZUH=PASS wazuh_rule=100123 falco_parent=100121 events>=2
DEMO_SESSION3_APPROVAL=PASS workflow=SOAR-01 decision=ContinueOrStop clicked=true status=SUCCESS
DEMO_SESSION3_AUTOMATIC_RESPONSE=PASS wazuh=disabled shuffle_response_actions=0
DEMO_SESSION4_ATTACK=PASS same_pod_shape=true unapproved_image=denied policy=Enforce
DEMO_SESSION4_CONTROL=PASS same_pod_shape=true signed_exact_digest=Ready
DEMO_SESSION4_EVIDENCE=PASS policy=ImageValidatingPolicy action=Deny failurePolicy=Fail exact_digest=Ready
```

출력은 합성 marker·상태·rule ID만 남긴다. 계정 비밀번호·TOTP, cookie, token, 고객 row,
SQL query 원문, 합성 flag, Shuffle hook·approval capability URL은 출력하거나 Git에 기록하지 않았다.

## reset과 복구

```text
DEMO_LIVE=PASS sessions=4 transient_attack_resources=0
DEMO_ARGO_RESTORE=PASS root=main
```

- 합성 Keycloak identity 삭제
- 공격 Pod·차단 NetworkPolicy·공급망 판정 Pod 0건
- 검증용 `demo-onprem` Application·namespace 0건
- `platform-root`, `pomerium`, `wazuh`와 관련 관측 child를 literal `main`의 최신 SHA에서
  `Synced/Healthy`로 복구

첫 검증에서 기존 합성 계정에는 Keycloak이 붙인 `CONFIGURE_TOTP` required action만 남아 있었다.
email·이름·활성화·TOTP·단일 group이 모두 exact 선언과 일치함을 확인한 뒤 이 합성 계정에만
required action을 비우도록 보정했다. cleanup의 Keycloak 관리자 로그인은 직전과 다른 30초
TOTP 구간에서 실행하고, 성공한 identity reset은 같은 검증 안에서 중복 로그인하지 않는다.

두 번째 검증에서 Wazuh `100102` 문서는 `no_full_log` 경계대로 원문과 동적 path 값을 저장하지
않는다는 실제 index 응답을 확인했다. 따라서 같은 검증 창의 Pomerium authorize 로그에서 exact
control/restricted path와 allow/deny boolean을 메모리에서만 판정하고, Wazuh에는 같은 창의
authorize `100102` hit가 도착했는지를 분리해 확인한다. identity·email·로그 원문은 출력하지 않는다.
Pomerium 로그 flush 차이는 5초 간격·최대 7회로 유한 대기하며, 실패 진단도 데모 path와
allow/deny boolean만 남긴다.

Pomerium의 restricted `403`은 명시적 deny rule match가 아니라 허용 rule 불일치이므로 실제
authorize 값은 `allow=false`, `deny=false`였다. control의 `allow=true`와 restricted의
`allow=false`를 exact path별 판정값으로 사용한다.

CrowdSec AppSec 로그 증거는 라이브 Deployment가 실제로 쓰는 `type=appsec` Pod label로만
대상을 고정한다.

Falco demo event는 Wazuh parent `100121`까지 도달했지만 CRI prefix 경로의 JSON decoder가
dynamic field 값을 만들지 않아 최초 child `100123`이 0건이었다. parent를 유지하고 분석
시점의 raw line에서 exact `demo-onprem` namespace·`demo-onprem-attacker` Pod marker만 PCRE2
lookahead로 판정하며, `no_full_log`로 raw syscall·command line 비저장 경계를 유지한다.

첫 `100123` 전달 때 `custom-soar01`은 `exit 4`였고 Shuffle 실행은 0건이었다. hook 값과
내부 URL 형식은 정상이었지만 Vault Agent 파일은 `0440`, 소유자는 `100:101`, 실제
`wazuh-integratord`는 `999:999`라 읽을 수 없었다. capability를 재발급하지 않고 manager
container만 mount하는 memory volume의 해당 파일을 `0444`로 보정했으며, 세션 시작 전에
다음을 판정한다.

```text
DEMO_SOAR_HOOK=PASS integratord=readable capability=masked
```

승인 완료 실행의 rule ID는 Shuffle 응답의 `execution_argument` JSON 문자열 안에 있으므로 이를
JSON으로 해석해 exact `rule_id=100123`인 실행만 선택한다. 문자열 전체를 다시 직렬화한 결과의
따옴표 모양에는 의존하지 않는다.
