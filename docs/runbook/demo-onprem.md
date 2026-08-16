# 온프레미스 보안 데모 4편

`DEMO-ONPREM-01`은 신규 PVC·공개 DNS·OPNsense 변경·실데이터 없이 합성 고객정보와
통제된 실제 SQLi만 사용한다. 안정 리소스는 `demo-onprem` namespace의 메모리 기반 portal과
내부 API뿐이며, 공격 Pod와 차단 NetworkPolicy, 공급망 판정 Pod는 각 세션 `reset`이 지운다.

## 촬영 인터페이스

| 세션 | 화면 URL·대상 | 고정 입력 | attack 결과 | control 결과 | evidence marker·rule |
|---|---|---|---|---|---|
| 1 계정 탈취 | `https://access.imcherry5778.xyz/demo-onprem/account/control`, `/demo-onprem/account/restricted` | 합성 계정 `demo-onprem-user`, 동일 browser session | 미승인 network namespace에서 내부 `access` route 연결 실패 | 승인 경로에서 control `200`·`DEMO-ACCOUNT-CONTROL-200`, 같은 계정 restricted `403` | `DEMO_SESSION1_*`, Pomerium exact `allow=true`/`allow=false` path와 Wazuh authorize `100102`; groups 값은 `masked`만 출력 |
| 2 SQLi | `https://k3s-01.imcherry5778.xyz/demo-onprem/sqli/control`, `/demo-onprem/sqli/waf` | payload `%' OR 1=1 -- `, request ID `DEMO-ONPREM-01-S2` | 실제 취약 SQLite query가 `SYN-*` 3행을 `200`으로 노출 | 같은 backend·payload를 CrowdSec AppSec가 `403` | `DEMO_SESSION2_*`, OWASP CRS SQLi `942100`, Wazuh `100122`; query/header/body는 로그·증거에서 제외 |
| 3 컨테이너 침해 | `demo-onprem-attacker` → `demo-onprem-internal-api:8080/flag` | 같은 Pod의 TTY `sh`, 같은 Service·port | `DEMO-LATERAL-FLAG`와 합성 flag 확인 | transient egress NetworkPolicy 뒤 같은 연결 실패 | Falco `Interactive Shell in Container`, Wazuh `100123`, Shuffle `SOAR-01 Wazuh read-only approval`의 실제 Continue/Stop `clicked=true`; 자동 대응 0건 |
| 4 공급망 | Kubernetes admission·`demo-onprem-supply-positive` | 동일 Pod shape, negative upstream digest와 positive curated digest | 비승인 upstream image를 ImageValidatingPolicy가 거부 | Harbor 서명 exact digest Pod `Ready` | `DEMO_SESSION4_*`, `k3s-curated-images-require-signature`, `Deny`·`Fail` |

SQLi payload는 URL query로만 전달하며 portal 로그에는 path와 고정 marker만 남는다. 고객 row,
email, flag, 계정은 모두 합성 값이다. Wazuh Pomerium rule은 `no_full_log`, 데모 Falco child도
`no_full_log`이며 증거기는 hit 수·rule ID·경로 존재만 출력한다. Secret/JWT/token/cookie/TOTP,
Shuffle hook·approval capability URL은 출력·Git 기록 대상이 아니다.

## 실행과 reset

세션 하나의 촬영 계약은 다음 네 명령이다.

```bash
gitops/tools/demo-onprem/demo.sh sessionN attack
gitops/tools/demo-onprem/demo.sh sessionN control
gitops/tools/demo-onprem/demo.sh sessionN evidence
gitops/tools/demo-onprem/demo.sh sessionN reset
```

Session 3 `evidence`가 `DEMO_SESSION3_APPROVAL=WAITING`을 출력하면 승인자는
`https://shuffle.imcherry5778.xyz`의 `SOAR-01 Wazuh read-only approval` 최신 실행에서
Continue 또는 Stop을 직접 누른다. 실행기는 API의 승인 노드 `SUCCESS`·`clicked=true`만
판정하며 사람 입력을 대행하지 않는다.

전체 reset 뒤 `demo-onprem-attacker`, `demo-onprem-transient-lateral-block`, 두 supply proof
Pod가 모두 없어야 한다. immutable 검증기는 성공·실패와 무관하게 root·child를 literal
`main`으로 복구하고, main 통합 뒤 관련 Application의 최신 main `Synced/Healthy`를 최종
판정한다.
