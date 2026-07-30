# Proxmox API 자격증명은 이 저장소에 두지 않는다.
# PROXMOX_VE_API_TOKEN (권장) 또는 PROXMOX_VE_USERNAME·PROXMOX_VE_PASSWORD 환경변수로만 주입한다.
# 자세한 주입 절차와 최소 권한은 README.md 를 따른다.
provider "proxmox" {
  endpoint = var.proxmox_endpoint
  insecure = var.proxmox_insecure
  min_tls  = var.proxmox_min_tls

  # ssh 블록은 두지 않는다.
  # snippet 업로드와 로컬 파일 import 는 이 구성의 범위 밖이고,
  # SSH 경로를 열지 않으면 provider가 Proxmox 호스트 파일시스템에 접근할 수 없다.
}
