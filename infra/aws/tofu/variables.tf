variable "aws_account_id" {
  description = "적용 대상 AWS 계정 ID. 저장소 밖 변수 파일로만 주입한다. bucket 이름의 전역 유일성과 provider 계정 guard에 함께 쓰인다."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id는 12자리 숫자여야 한다."
  }
}

variable "aws_region" {
  description = "오프사이트 bucket과 경보 자원을 두는 region."
  type        = string
  default     = "ap-northeast-2"
}

variable "bucket_prefix" {
  description = "오프사이트 bucket 이름 접두사. 실제 이름은 접두사와 계정 ID를 잇는다."
  type        = string
  default     = "ktcloud4-bean-offsite-backup"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,40}[a-z0-9]$", var.bucket_prefix))
    error_message = "bucket_prefix는 S3 bucket 이름 규칙을 따라야 한다."
  }
}

variable "noncurrent_version_retention_days" {
  description = "덮어쓰기로 밀려난 이전 version을 보존하는 일수. 실수·손상·랜섬웨어 복구 창이다."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_retention_days >= 7
    error_message = "복구 창을 7일 미만으로 줄이지 않는다."
  }
}

variable "abort_incomplete_multipart_days" {
  description = "중단된 multipart upload 조각을 정리하기까지의 일수. 보이지 않는 저장 비용을 막는다."
  type        = number
  default     = 7
}

variable "alert_email" {
  description = "백업 실패 경보를 받을 이메일. 저장소 밖 변수 파일로만 주입한다. 빈 문자열이면 구독을 선언하지 않는다."
  type        = string
  default     = ""
}

variable "enable_heartbeat_alarm" {
  description = "오프사이트 job이 아예 실행되지 않는 상황을 잡는 CloudWatch alarm gate. object host에 job이 배포되어 정기 실행될 때만 연다. 닫혀 있으면 alarm을 0개 선언한다. 열어 둔 채 job을 내리면 alarm이 영구히 울린다."
  type        = bool
  default     = false
}

variable "heartbeat_metric_namespace" {
  description = "오프사이트 job이 성공 시 publish 하는 CloudWatch metric namespace."
  type        = string
  default     = "KtCloud4Bean/OffsiteBackup"
}

variable "heartbeat_metric_name" {
  description = "오프사이트 job 성공 metric 이름."
  type        = string
  default     = "BackupSuccess"
}

variable "backup_user_name" {
  description = "오프사이트 전송 전용 IAM user 이름."
  type        = string
  default     = "seaweedfs-offsite-backup"
}

variable "create_backup_access_key" {
  description = "전송용 access key를 이 root가 만들지 여부. 열면 secret이 state에 들어가므로 state는 저장소 밖 mode 0600으로만 보관한다."
  type        = bool
  default     = true
}
