# SeaweedFS 로컬 TLS S3 전환 운영 런북

작업: `S3-01`
검증일: 2026-07-31
대상: `object-01.imcherry5778.xyz` (VMID 151, DATA VLAN)
서비스 endpoint: `https://s3.imcherry5778.xyz:8333`

2026-08-03 `NET-04`에서 아래 exact S3 rule UUID와 sequence `1015`를 의미값 변경 없이
보존했다. 주변 VLAN 경계와 hardened 결과는
[`opnsense-vlan-firewall-hardening.md`](opnsense-vlan-firewall-hardening.md)가 소유한다.

이 문서는 기존 `minio-01` VM을 새 VM·새 disk·disk 확장 없이 SeaweedFS 로컬 S3로
제자리 전환한 실제 절차와 증거를 소유한다. 주소는 [ip-plan.md](../ip-plan.md), 용량
정지 기준은 [capacity-plan.md](../capacity-plan.md), 선택 근거는
[ADR-0010](../adr/0010-seaweedfs-local-s3.md)를 따른다.

## 전환 계약과 복구 지점

| 항목 | 전환 전·후 값 | 판정 |
|---|---|---|
| OpenTofu state 주소 | `module.service_vm["minio-01"]` → `module.service_vm["object-01"]` | `moved` 선언으로 이동 |
| VMID | 151 | 불변 |
| MAC / VLAN / IPv4 | `BC:24:11:3C:CD:77` / 50 / `10.10.50.20` | 불변 |
| boot disk | `local-lvm:vm-151-disk-0`, 200 GiB | 불변 |
| 변경 plan | 0 add · 1 change · 0 destroy | 이름·설명만 변경 |
| 최종 refresh plan | 5개 resource 모두 `no-op` | create/destroy/replace 0 |

변경 직전 local backend state를 저장소 밖
`/home/imcherry/.local/state-backups/s3-01-20260731-7OsvqE/terraform.tfstate.pre-change`에
mode `0600`으로 보관했다. SHA-256은
`84abde409604682de797c68163f97770e6ffbecff2bf8c4fe4de6aafe4f38a51`이다. 이름 이동 후
state 사본 SHA-256은 `abd55833087fec91e019da764121d410ab7906c4aaee80fabf469aa055972c5d`다.
사본 시각은 2026-07-31 13:17:13 KST다. 최신 no-op plan의 SHA-256은
`fc3bb787201ef64cd4894e806ddbd0c3bc3b6cf2cb39fa55abc0998ce82833d3`이다.
state 원문, API token, S3 secret, TLS private key는 기록·Git·일반 log에 넣지 않는다.

rollback은 이 작업이 만든 정확한 이름 전환·Unbound object/s3 record·S3 PF rule·Ansible
리소스만 대상으로 한다. 사본을 이용할 때도 먼저 `moved` 선언을 유지한 refresh plan에서
create/destroy/replace 0을 확인한다. `tofu state rm`, 정상 state의 수동 import, state
원문 편집, VM 삭제·재생성으로 복구하지 않는다. 안전한 자동 rollback을 보장할 수 없으면
state·Proxmox·guest·DNS별 authoritative 이름을 기록하고 중단한다.

## 고정 입력과 영속 경계

| 입력 | 값 |
|---|---|
| SeaweedFS release | 4.40, Rocky Linux 9 amd64 `linux_amd64.tar.gz` |
| archive SHA-256 | `0c63aec15429d17e216fdb878a92532188d3e147d7f072645bfec9eb6f992a02` |
| license | Apache-2.0 |
| LICENSE SHA-256 | `d789d433cc11da163273d1e39be2e8fa67642f9a58ef220d3f258fa9c14ef613` |

입력은 [공식 release 4.40](https://github.com/seaweedfs/seaweedfs/releases/tag/4.40)과
[공식 Apache-2.0 LICENSE](https://github.com/seaweedfs/seaweedfs/blob/4.40/LICENSE)에서
확인했다. Ansible `get_url checksum`이 archive와 license를 강제하며 mutable `latest`,
`weed mini`, MinIO는 사용하지 않는다.

`seaweedfs` 비로그인 system user가 네 enabled systemd unit을 실행한다.

| 구성요소 | 영속 경로 | 노출 경계 |
|---|---|---|
| master | `/var/lib/seaweedfs/master` | `127.0.0.1:9333` |
| volume server | `/var/lib/seaweedfs/volume` | `127.0.0.1:8080` |
| filer | `/var/lib/seaweedfs/filer` | `127.0.0.1:8888` |
| S3 gateway | filer를 loopback으로 사용, `/etc/seaweedfs/s3.json` | DATA 주소 TCP 8333 TLS만 |

`/var/lib/seaweedfs`는 `var_lib_t`, `/etc/seaweedfs`는 `etc_t`, binary는 `bin_t`로
선언하고 `restorecon`을 적용한다. SELinux는 전환·두 재부팅 후에도 Enforcing이며 부팅
이후 AVC와 failed unit은 모두 0이다. systemd unit은 비-root, 빈 capability set,
`NoNewPrivileges`, `ProtectSystem=strict`, private namespace/device 등을 선언한다.

## TLS·DNS·방화벽·credential 경계

canonical host는 `object-01.imcherry5778.xyz`, S3 alias는
`s3.imcherry5778.xyz`다. PostgreSQL의 host-specific bootstrap TLS 경계를 검토해 같은
형태의 CA:FALSE leaf를 guest에서 생성했다. SAN에는 두 FQDN과 `10.10.50.20`만 넣고,
private key는 guest `/etc/seaweedfs/tls/s3.key` mode `0600`에만 둔다. OPNsense wildcard
private key나 별도 자체 CA는 만들거나 복사하지 않았다. 검증은 `--cacert`와 SNI hostname
verification으로 했고 `-k`나 TLS 검증 비활성화는 쓰지 않았다.

Unbound에는 이전 `minio-01` canonical A/PTR을 제거하고 `object-01` A/PTR와 `s3`
alias를 등록했다. k3s resolver와 DATA gateway resolver에서 두 이름은 `10.10.50.20`으로
해석하고 PTR은 object canonical 이름을 돌려주며 minio 이름은 해석되지 않음을 확인했다.
OPNsense reboot는 수행하지 않았다. 지원 API reconfigure 뒤 saved model·runtime resolver·실제
client를 확인했으며 `check-drift.sh --update`와 일반 no-drift check를 통과했다.

PF rule `58525b66-bc90-484e-893a-a51bfd5aa346`은 PLATFORM의 `k3s-01` (`10.10.20.10/32`)에서
`10.10.50.20:8333/TCP`만 허용한다. runtime counter는 허용 S3 probe의 packet/state를
관측했다. k3s에서 master·volume·filer 관리 port probe는 연결되지 않았고, RFC1918 선차단
rule counter도 음성 control 중 증가했다. timeout/refused만으로 PF 차단을 단정하지 않고,
loopback bind와 PF runtime을 함께 대조했다.

S3 identity는 저장소 밖 mode `0600` extra-vars로만 주입한다. identity별 action은
`Admin|Read|List|Tagging|Write:<정확한-bucket>` 형식만 허용하며 access key와 secret의 최소
길이를 검사한다. 빈 identity 목록에는 disabled `deny-all-bootstrap` sentinel을 넣어
SeaweedFS의 empty-identity allow-all 동작을 막는다. 최종 상태에는 장기 consumer credential이
없고 credential 없는 TLS request는 HTTP 403이다.

## 실제 S3 호환성·최소권한 시험

검증 identity `s3-01-validation-20260731045645-4373d924`에는 고유 bucket
`s3-01-live-20260731045645-4373d924`만의 action과 bucket policy를 주었다. 다른 bucket
생성과 잘못된 credential은 HTTP 403이었고 관리 endpoint는 loopback으로 제한됐다. 모든
시험 payload 합계는 6,291,528 bytes로 64 MiB 제한 안에 있다.

| 시험 | 비밀 아닌 결과 |
|---|---|
| bucket create / list | 고유 bucket 생성·조회 성공 |
| PUT / GET / LIST / DELETE | marker object 정상 round-trip |
| versioning | Enabled, 같은 key 두 version 조회 성공 |
| marker v1 | 내용 `S3-01 marker version 1`, SHA-256 `60529f53e242eb88a284c22b73103c315f445beabd785b91aab93da2a68a44b2`, version `6738b8d68a2b5addeb5b8f2b2f5fed24` |
| marker v2 | 내용 `S3-01 marker version 2`, SHA-256 `6d69ebbeb7652420ea84e6d624bb12b0d168456b479271c6dd8b83f2048aaae8`, version `6738b8d67d45372c2601469f3c38fbad` |
| multipart | 6,291,456 bytes, SHA-256 `90b9d2c90d3f47217ecd241e2b8499e8dde6529c35fbac49e719030639fc01ab`, version `6738b8d6769e79291594568579caa31c` |
| HTTPS presigned URL | hostname 검증을 유지한 다운로드 HTTP 200 |

multipart ETag `"5571a50471b996e38ce060eaa6974cd4-2"`는 SHA-256으로 취급하지 않았다.
업로드 전·다운로드 후 payload SHA-256을 직접 비교했다.

## 재부팅·멱등성·정리 증거

`object-01`만 두 차례 재부팅했고 각 재부팅 전후 boot ID 변경을 확인했다. 최종 boot ID는
`4e938057-1936-4766-9fb0-8791f3be2eaf`다. 최종 boot에서 hostname·DNS가 object 이름으로
일치하고 네 SeaweedFS unit은 enabled+active, TLS hostname verification, marker/version·SHA-256,
최소권한 정책은 유지됐다.

Ansible syntax-check, check/diff와 실제 적용을 재부팅 후 최신 main 기준으로 실행했다.
check/diff는 `ok=36 changed=0 failed=0`, 실제 적용은 `ok=38 changed=0 failed=0`이다.
공식 archive/license checksum, listener bind, TLS 403 negative control, SELinux context도
role assertion으로 재확인했다.

정리는 SeaweedFS S3 API로만 수행했다. marker·multipart object의 version 5개를 삭제하고,
multipart 잔여 upload 0개를 abort 대상으로 확인한 뒤 bucket 부재를 확인했다. 시험
identity·policy·credential와 k3s client virtualenv·임시 파일도 제거했다. 최종 `s3.json`은
disabled sentinel 하나뿐이며 credential·action·시험 identity는 0개다. 데이터 경로 수동
삭제로 성공을 꾸미지 않았다.

## 용량과 한계

정리 뒤 object guest root는 198.86 GiB 중 사용 2.71 GiB(2%), SeaweedFS 세 영속 경로는
77,918 bytes였다. host thin data/metadata는 1.79%/0.29%, available memory 47.66 GiB,
swap 0, 15분 load 0.21로 모두 [capacity-plan.md](../capacity-plan.md)의 경고·정지 기준
밖이다. 이 전환으로 VM allocation과 200 GiB disk 예산은 늘지 않았다.

그러나 master·volume·filer·S3가 한 VM의 한 boot disk에 있으므로 replica·failover·다른
물리 failure domain은 없다. 이 결과는 S3 API와 guest 재부팅 유지 증거일 뿐 HA나 host/NVMe
손실 복구 증거가 아니다. AWS S3 오프사이트 복제·샘플 restore·보존·경보는 `BKP-04`의
별도 범위이며 여기서 구현하지 않았다.

## S3-02: filer 웹 UI의 Pomerium 노출

검증일: 진행 중. 대상: `object-01.imcherry5778.xyz`. 서비스 endpoint:
`https://filer.imcherry5778.xyz`(Pomerium, `/platform-privileged`만 허용).

filer는 SeaweedFS 컴포넌트 중 유일하게 브라우저에서 버킷 내용을 탐색할 수 있는 웹 UI를
갖고 있다. `S3-01` 이후 master·volume·filer 관리 endpoint는 전부 loopback bind였고,
사람이 이 UI에 닿을 경로가 없었다. `S3-02`는 filer만 골라 다음처럼 연다.

- filer systemd unit의 `-ip.bind`를 `127.0.0.1`에서 `0.0.0.0`으로 바꿔 DATA 주소
  (`10.10.50.20:8888`)에서도 듣게 하되, 기존 `127.0.0.1:8888`(S3 gateway의 로컬 filer
  연결)은 그대로 유지한다. `-ip`(자기 식별 주소)는 `seaweedfs_filer_bind_address`
  (DATA 주소)로 맞춘다.
- `IPAddressAllow`에 `10.10.20.10/32`(k3s-01)를 filer 전용 항목으로 명시한다(기존
  `seaweedfs_metrics_allowed_sources`와 값은 같지만, metrics가 나중에 꺼져도 이 노출
  경계가 조용히 사라지지 않도록 별도 목록으로 관리한다).
- OPNsense `opt2` exact PASS 1건(`k3s-01/32` → `object-01/32` TCP 8888)만 추가한다.
  master(9333)·volume(8080) 관리 포트는 loopback으로 그대로 남는다.
- Unbound alias `filer.imcherry5778.xyz` → `k3s-01`(`10.10.20.10`)을 등록한다. 다른
  Pomerium Route와 같은 이유로 실제 backend(`object-01`)가 아니라 Pomerium이 있는
  host를 가리킨다.
- Pomerium Route `filer`는 `to: http://10.10.50.20:8888`로 k3s-01에서 object-01로
  직접 연결한다(클러스터 안 `*.svc.cluster.local`이 아닌 첫 외부 VM 대상 Route). 전송
  구간은 이미 OPNsense가 k3s-01 단일 source로 제한한 평문 HTTP다. `OBS-16`이 같은
  host의 metrics endpoint(9325~9328)에 이미 적용한 것과 같은 경계 판단이며, S3 API
  자체(TLS 8333, `S3-01`)와는 별도 결정이다.

**bucket 단위 접근 통제가 없다는 한계.** `S3-01`의 S3 identity는
`Admin|Read|List|Tagging|Write:<정확한-bucket>` 형식으로 bucket마다 분리돼 있어,
credential 하나가 새도 그 bucket 하나만 노출된다. filer 자체에는 이런 bucket 단위
ACL이 없다 — Pomerium `/platform-privileged` 통과 세션 하나가 전체 filer 네임스페이스
(모든 bucket)에 대해 읽기·쓰기·삭제를 all-or-nothing으로 갖는다. 이 Route는 S3 API의
최소권한 경계를 대체하지 않으며, 별도의 넓은 신뢰 경계로 다룬다.

rollback은 Pomerium Route·NetworkPolicy·Ingress host·Unbound alias·OPNsense PF
rule을 제거하고 filer unit을 `-ip.bind=127.0.0.1`로 원복하는 것으로 끝난다. S3 API
8333 경로·credential·bucket policy는 이 작업으로 바뀌지 않는다.
