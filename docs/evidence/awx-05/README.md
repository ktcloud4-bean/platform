# AWX-05 완료 증거

AWX-05는 실제 운영 변경 전에 `k3s-01.imcherry5778.xyz` 한 대만 대상으로 하는
무변경 SSH canary다. Machine credential의 private key는 AWX DB가 아닌
`kv/awx/ssh-canary`의 Vault external input source에서만 읽는다. `awx-canary` 계정은
source `10.42.0.0/24,10.10.20.10`으로 제한되고 sudo·become 권한이 없다.

## 실행 결과

- immutable root `720dfc650b1cd96f6017f4f45c5fae2b78bc205b`와 AWX
  `5ecf48b8ae21db62a02ea285ec6d7870a4ef4df5`에서 root/AWX가
  `Synced/Healthy/Succeeded`였다. inventory는 host 한 대, NetworkPolicy는
  `10.10.20.10/32:22` 하나이며 PVC는 0이다.
- Jenkins replay #17이 source `112fb2a25afc2bc774fe3040bf091c1c421a1398`에서
  Trivy·CycloneDX SBOM·Cosign을 통과해 만든 EE digest
  `sha256:0a35dcb1933fd6439730dd2a57e325be1bd175852c29dd0e2894728b16137bb9`로
  canary job `126`이 성공했다. host summary는 `changed=0`, `dark=0`, `failed=0`이다.
- 같은 Job에서 `k3s-01:22` preflight는 허용됐고, 다른 운영 host의 TCP 22 및
  `k3s-01:2222`는 `AWX05_NETWORK_BOUNDARIES=PASS`로 차단됐다. ping과 최소 facts는
  sudo·become 없이 성공했다.
- 실행 중 guest available은 12 GiB 이상, swap은 0, 새 PVC와 OPNsense 변경은 0이다.
  AWX job stdout와 event log를 현재 Vault private key와 대조해 raw secret은 0건으로
  판정했고, 비밀 원문은 출력하거나 Git에 기록하지 않았다.
- 첫 실행 job `123`은 private key가 agent에 추가된 뒤에도 host 변수의
  `IdentitiesOnly=yes`가 agent key 제시를 막아 publickey 인증에서 실패했다. source CIDR,
  key fingerprint, host key와 NetworkPolicy가 모두 맞음을 확인한 뒤 해당 옵션만 제거했고,
  재실행 job `126`으로 수렴했다.
- 검증이 끝난 뒤 root/AWX는 literal `main`
  `fd7e7d759cab0a01e63e7949a32905872f55b90d`로 복원해
  `Synced/Healthy/Succeeded`를 확인했다. 복원 중 만료가 확인된 기존 AWX-04 SCM lookup
  Secret ID는 승인된 재발급 절차로 입력만 갱신했고, 새 project update `130` 성공 뒤 main
  상태를 재확인했다.
