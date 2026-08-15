# AWS-SEC-03: CIEM 조치 계층 증거

## 범위

- `infra/aws/tofu-app-security/`에 CIEM 보고·알림·사람 승인 callback·action executor·권한 드리프트·IAM 경계 감시를 추가했다.
- IAM·SNS·Secrets Manager는 VPC 밖 Lambda가 담당하고, Keycloak session logout만 VPC Lambda가 기존 VGW 경로로 호출한다.
- Slack signing secret과 Keycloak client secret은 Terraform `secret_version`으로 선언하지 않고 Secrets Manager 외부 주입 경계를 유지한다.

## 정적·단위 검증

```text
bash -n infra/aws/tofu-app-security/scripts/*.sh                         PASS
python3 -m compileall -q infra/aws/tofu-app-security/scripts             PASS
tofu -chdir=infra/aws/tofu-app-security fmt -check                       PASS
CIEM targeted unit probes: callback=401/403/async, key-age-not-used       PASS
grep 0.0.0.0/0 in CIEM Terraform/script egress declarations              0 matches
```

callback 단위 표본은 서명 secret 미설정 `401`, allowlist 밖 사용자 `403`, 허용 사용자
비동기 executor enqueue를 판정했다. IAM key 표본은 `/service/` key를 제외하고, 생성된 지
오래됐지만 3일 전에 사용한 key를 후보로 올리지 않음을 확인했다.

## AWS live 및 OpenTofu

초기 plan은 `0 add / 1 change / 0 destroy`였고, 변경은 최근 사용 시점 기준으로 보정한
key-exception Lambda 1건이었다. apply는 `0 added / 1 changed / 0 destroyed`로 끝났고
후속 plan은 다음과 같았다.

```text
No changes. Your infrastructure matches the configuration.
```

live 구성은 다음 경계를 만족한다.

- CIEM orchestrator 5개는 VPC config가 없고, Keycloak session Lambda만 VPC에 있다.
- session Lambda security group은 `10.10.20.10/32` TCP 443 단일 egress다. `0.0.0.0/0`
  egress 선언은 없다.
- `AttachRolePolicy` EventBridge pattern은 `errorCode`가 없는 성공 이벤트만 수신한다.
- CIEM Lambda `Errors` alarm 7개가 존재한다.
- AWS account에서 `/service/` prefix 사용자 4개와 access key 4개를 사람용 후보에서
  제외하는 경계를 확인했다.

## OPNsense·Keycloak 경로

```text
AWS-SEC-03 FirewallCheck=PASS interface=enc0(IPsec) direction=in rules=2 destination=Keycloak-HTTPS
AWS-SEC-03 Argo=PASS root=044ce77868ee783f14857fbf71eb9c577eabe370 keycloak=cb23b98f01f796b3a5b698b39790903869b837a0 route=admin-vpc-exact session=vgw-private
```

immutable 검증은 전용 root/child SHA에서 `/admin` source allowlist와 VPC Lambda의
`user_not_found` session probe를 확인한 뒤 `platform-root`와 `keycloak`을 literal
`main`으로 복원했다. 복원 후 두 Application은 시작 main
`cdbfdc51aac2ee0b3b72f3ebfc4f932ec754c52d`에서 `Synced/Healthy`였고 CIEM route·middleware는
main 선언에 없어 정리됐다.

검증 출력과 이 문서에는 token, signing secret, client secret, kubeconfig를 넣지 않았다.
