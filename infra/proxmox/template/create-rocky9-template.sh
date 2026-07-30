#!/usr/bin/env bash
# ==============================================================================
# create-rocky9-template.sh
# Rocky Linux 9 GenericCloud 공식 이미지를 다운로드 및 GPG/SHA256 검증 후
# Proxmox cloud-init template(VMID 9000)을 생성하는 스크립트.
# ==============================================================================

set -euo pipefail

VMID="${VMID:-9000}"
TEMPLATE_NAME="${TEMPLATE_NAME:-rocky9-genericcloud-template}"
STORAGE="${STORAGE:-local-lvm}"
CI_STORAGE="${CI_STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"

IMAGE_NAME="Rocky-9-GenericCloud-Base-9.8-20260525.0.x86_64.qcow2"
BASE_URL="https://dl.rockylinux.org/pub/rocky/9/images/x86_64"
IMAGE_URL="${BASE_URL}/${IMAGE_NAME}"
CHECKSUM_URL="${IMAGE_URL}.CHECKSUM"
ASC_URL="${CHECKSUM_URL}.asc"
GPG_KEY_URL="https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-9"

echo "==> Proxmox VE 환경 확인..."
if ! command -v qm >/dev/null 2>&1; then
    echo "ERROR: 'qm' 명령을 찾을 수 없습니다. Proxmox VE 호스트에서 실행해야 합니다." >&2
    exit 1
fi

if qm status "$VMID" >/dev/null 2>&1; then
    echo "ERROR: VMID ${VMID}가 이미 존재합니다. 기존 템플릿/VM을 확인 후 제거하고 다시 시도하세요." >&2
    exit 1
fi

BUILD_DIR=$(mktemp -d /tmp/rocky9-template-build.XXXXXX)
trap 'rm -rf "${BUILD_DIR}"' EXIT

cd "${BUILD_DIR}"

echo "==> 1. Rocky 9 공식 이미지 및 서명/검증 파일 다운로드..."
curl -sSL -O "${IMAGE_URL}"
curl -sSL -O "${CHECKSUM_URL}"
curl -sSL -O "${ASC_URL}"
curl -sSL -O "${GPG_KEY_URL}"

echo "==> 2. GPG 키 수입 및 CHECKSUM.asc 서명 검증..."
KEYRING="./rocky_keyring.gpg"
gpg --no-default-keyring --keyring "${KEYRING}" --import RPM-GPG-KEY-Rocky-9 >/dev/null 2>&1
gpg --no-default-keyring --keyring "${KEYRING}" --verify "${IMAGE_NAME}.CHECKSUM.asc" "${IMAGE_NAME}.CHECKSUM"

echo "==> 3. SHA256 Checksum 검증..."
EXPECTED_HASH=$(grep -E "SHA256 \(${IMAGE_NAME}\)" "${IMAGE_NAME}.CHECKSUM" | awk '{print $NF}')
ACTUAL_HASH=$(sha256sum "${IMAGE_NAME}" | awk '{print $1}')

if [ -z "${EXPECTED_HASH}" ]; then
    echo "ERROR: CHECKSUM 파일에서 ${IMAGE_NAME}에 대한 해시값을 찾을 수 없습니다." >&2
    exit 1
fi

if [ "${EXPECTED_HASH}" != "${ACTUAL_HASH}" ]; then
    echo "ERROR: Checksum 불일치! Expected: ${EXPECTED_HASH}, Actual: ${ACTUAL_HASH}" >&2
    exit 1
fi
echo "✓ SHA256 Checksum 검증 성공 (${ACTUAL_HASH})"

echo "==> 4. Proxmox VM ${VMID} 생성..."
qm create "${VMID}" \
    --name "${TEMPLATE_NAME}" \
    --memory 2048 \
    --cores 2 \
    --cpu host \
    --net0 virtio,bridge="${BRIDGE}"

echo "==> 5. 디스크 임포트 (${STORAGE})..."
qm importdisk "${VMID}" "${IMAGE_NAME}" "${STORAGE}"

echo "==> 6. VM 계약 설정 (scsihw, cloudinit, boot, agent)..."
# 임포트된 디스크 이름 구하기 (기본: vm-VMID-disk-0)
qm set "${VMID}" --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:vm-${VMID}-disk-0,discard=on,ssd=1"
qm set "${VMID}" --ide2 "${CI_STORAGE}:cloudinit"
qm set "${VMID}" --boot c --bootdisk scsi0
qm set "${VMID}" --serial0 socket --vga serial0
qm set "${VMID}" --agent enabled=1
qm set "${VMID}" --ipconfig0 ip=dhcp

echo "==> 7. VMID ${VMID}를 Template으로 전환..."
qm template "${VMID}"

echo "==> ✓ Rocky 9 Cloud-Init Template (VMID ${VMID}) 생성 완료!"
