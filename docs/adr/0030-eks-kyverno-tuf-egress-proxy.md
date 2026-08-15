# ADR-0030: EKS Kyverno TUF metadata의 사설 CONNECT 경로

- 상태: `Accepted`
- 날짜: 2026-08-15
- 관련 작업: `SUPPLY-01-FIX-01`

## 배경

EKS private subnet에는 NAT Gateway·Internet Gateway·기본 경로가 없다. Kyverno
`ImageValidatingPolicy`가 Cosign 서명과 CycloneDX attestation을 검증하려면 Sigstore TUF
metadata를 읽어야 하는데, 기존 policy의 mirror 누락은 Kyverno 내부 verifier 초기화 실패를
일으켰고, mirror를 추가한 뒤에도 `tuf-repo-cdn.sigstore.dev:443`가 private subnet에서
timeout/connection refused였다.

## 결정

기존 `10.10.0.0/16 ↔ 10.20.0.0/16` S2S VPN을 재사용하고, k3s-01에
`10.10.20.12:8445` 전용 CONNECT proxy를 배치한다. EKS node SG는 해당 `/32`의 TCP
8445만 허용하고, OPNsense는 다음 세 exact 흐름만 허용한다.

- `10.20.10.0/24`, `10.20.20.0/24` → `10.10.20.12:8445`
- `10.10.20.12` → `tuf-repo-cdn.sigstore.dev:443`

proxy process는 허용 client CIDR과 `CONNECT tuf-repo-cdn.sigstore.dev:443`을 다시 판정한다.
Kyverno는 `HTTPS_PROXY`를 사용하되 AWS·cluster private CIDR은 `NO_PROXY`로 직접 접근한다.
TUF mirror와 Cosign root pin은 Git 선언에 유지한다.

## 검토한 대안

- NAT Gateway 또는 `0.0.0.0/0` route: endpoint-only private AWS egress 결정을 깨므로 채택하지 않는다.
- Harbor proxy cache를 TUF source로 사용: OCI image 획득 경계와 Sigstore TUF metadata source를
  섞고 운영 source의 signed metadata 갱신 책임이 불명확하므로 채택하지 않는다.
- 외부 CDN을 EKS에서 직접 허용: private subnet에는 경로가 없고, workload별 목적지 고정도
  불가능하므로 채택하지 않는다.
- 장기 private TUF mirror: upstream metadata 동기화·서명·만료 운영을 별도 소유해야 하므로
  이번 긴급 보정에서는 만들지 않고 재검토 조건으로 남긴다.

## 결과

EKS 전체 인터넷 egress 없이 admission verifier가 필요한 TUF metadata만 기존 사설 VPN과
전용 proxy로 읽는다. proxy 장애나 CDN 장애는 `failurePolicy: Fail`에 따라 image admission을
중단시키며, AWS API·ECR 경로에는 영향을 주지 않는다.

## 재검토 조건

TUF CDN의 주소·인증서·갱신 정책 변화, S2S VPN 장애 도메인 확대, EKS 다중 AZ/다중 cluster,
또는 proxy 없이 운영 가능한 내부 signed mirror가 준비되면 private TUF mirror 또는 별도
egress gateway로 재검토한다.
