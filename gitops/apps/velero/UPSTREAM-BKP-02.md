# BKP-02 Velero 공급망과 운영 경계

이 디렉터리는 공식 `vmware-tanzu/helm-charts`의 `velero-12.1.0.tgz`를
`release-metadata.env`의 SHA-256으로 검증해 vendoring한 것이다. chart가 기본으로 가리키는
Velero 1.18.1 대신 보안·버그 수정 릴리스 1.18.2를 사용하므로 `Chart.yaml`의
`appVersion`과 `values-bkp-02.yaml`의 image를 1.18.2로 명시했다. 실행 image는 tag가 아니라
linux/amd64 manifest digest로 고정한다.

AWS object-store plugin은 Velero 1.18.x 호환 계열인 1.14.2를 linux/amd64 digest로
고정한다. Kopia는 별도 container가 아니라 Velero binary에 포함된
`github.com/project-velero/kopia` fork commit을 사용한다. 전체 출처·tag commit·index와
platform digest는 `release-metadata.env`가 소유한다.

`local-path` PV에는 CSI snapshot을 사용하지 않는다. `snapshotsEnabled: false`, 빈 CSI
feature, node-agent와 Kopia filesystem backup만 사용하며 각 대상 Pod가 annotation으로
volume을 명시적으로 opt-in한다. Velero ServiceAccount의 `cluster-admin` binding과
node-agent의 root·privileged host-pod mount는 복원 기능에 필요한 운영 위험으로 승인받은
경계다. Velero 1.18.2 image config의 이름형 `cnb:cnb` 사용자는 kubelet의
`runAsNonRoot` 사전 판정을 통과하지 못하므로 server Pod는 명시적인 숫자 UID/GID
`1000:1000`으로 고정하고 실제 기동으로 검증한다. Kopia repository client가 쓰는
`/udmrepo`는 root filesystem이 아니라 fsGroup 1000이 적용되는 server 전용 `emptyDir`로
마운트한다. 이름형 image 사용자의 기본 home이 `/`로 해석돼 `/.cache` 쓰기를 시도하지
않도록 server와 node-agent의 `HOME`도 각 Pod의 writable `/scratch`로 고정한다.
repository의 영속 metadata와 data는 S3에 있고 이 volume은 실행 cache다.

S3 credential과 Kopia repository password는 이 디렉터리나 Helm values에 넣지 않는다.
저장소 밖 mode 0600 입력에서 `bkp-02-s3-credentials`와
`velero-repo-credentials` Secret을 별도로 주입해야 한다. chart 삭제 시 CRD 자동 삭제는
금지하며 `cleanUpCRDs: false`를 유지한다.
