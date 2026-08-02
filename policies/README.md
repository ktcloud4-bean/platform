# POL-01 정책 기준선

이 디렉터리는 Kyverno Audit 정책 한 건과 `pomerium` namespace NetworkPolicy 기준선을
소유한다. Kyverno controller 배포와 버전·digest·검증/rollback 경계는
[`gitops/apps/kyverno/README.md`](../gitops/apps/kyverno/README.md)가 소유한다.

`POL-02` 전에는 모든 Kyverno validate 정책의 `validationFailureAction`을 `Audit`으로 유지한다.
NetworkPolicy는 k3s 내장 kube-router가 실제 강제하므로 새 namespace에 기계적으로 복제하지
않고, 통신표와 대표 경로가 확인된 namespace만 별도 검증 뒤 추가한다.
