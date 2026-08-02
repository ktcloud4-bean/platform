# AWX Operator vendoring 기록

- upstream: `https://github.com/ansible/awx-operator.git`
- tag: `2.19.1`
- commit: `dd37ebd440edf953d822f2c134833a44a8e77532`
- vendored paths: `config/crd/bases/*.yaml`, namespaced manager와 필수
  `service_account`, `role`, `role_binding`, `leader_election_role`,
  `leader_election_role_binding`

`operator/kustomization.yaml`은 upstream default overlay의 metrics auth proxy를 포함하지
않는다. 해당 proxy image는 AWX reconcile에 필요하지 않고 metrics endpoint 보호 용도다.
manager image digest, RuntimeDefault seccomp와 존재하지 않는 pull secret 제거만 local
overlay에서 적용하며 이 디렉터리의 vendored YAML 본문은 tag 원문이다.
