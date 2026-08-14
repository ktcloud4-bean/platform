# AWX-04-FIX-04 완료 증거

AWX-05의 첫 private EE runner는 Harbor image pull 단계에서 `no basic auth credentials`로
실패했다. 당시 `awx-ee-pull`은 kubelet용 Docker config Secret 하나뿐이었고, AWX CR에는
app/database `image_pull_secrets`와 default Instance Group automation-job Pod의
`imagePullSecrets`가 없었다. 따라서 이 증거는 실행 대상·SSH·playbook 문제가 아니라 실행
Pod가 private registry 인증을 받지 못한 선언 결함임을 분리한다.

보정은 기존 Vault Harbor robot 입력을 바꾸지 않는다. bootstrap Hook이 같은 입력으로
`awx-ee-pull` (`kubernetes.io/dockerconfigjson`)과 `awx-ee-pull-credentials` (Opaque;
`url`, `username`, `password`, `ssl_verify`)를 각각 생성한다. AWX CR은 전자를 app/database
Pod에, default execution queue Pod spec override는 동적 automation-job Pod에 연결한다.

완료는 immutable root/AWX SHA에서 두 Secret의 type/key set, AWX CR의 두 참조와 default
Instance Group의 exact `imagePullSecrets` 및 기존 Pod security context가 수렴한 것으로만
판정한다. private EE pull runner나 `k3s-01` SSH는 실행하지 않는다. 이 보정 뒤 그 실제
canary 증거는 `AWX-05`가 한 번만 수행한다.

## 실행 결과

- immutable root `fc4a412ecf1365bdfeb32cdb9fe3a71c975f97dd`와 AWX
  `50c79fa509fac4350ac5a11416094de60b4fd7ab`에서 Opaque Secret의 exact key set,
  Docker config Secret type/key, CR 참조와 default Instance Group의
  `imagePullSecrets`·security context가 모두 수렴했다.
- 검증 중 만료가 확인된 SCM AppRole Secret ID는 승인 후 재발급했다. bearer 없는
  lookup과 SCM update `89`, 보정 상태 update `93`, rollback main update `94`가 성공했다.
- rollback은 literal `main` `c5bb5f8fae5ac032646c25c7bd5a8fd08b96c382`에서 root/AWX
  `Synced/Healthy/Succeeded`, 기존 default override와 `awx-ee-pull` 참조로 복구됐다.
  검증용 Opaque Secret은 삭제됐으며 비밀 원문은 출력하지 않았다.
