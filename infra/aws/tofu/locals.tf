locals {
  # bucket 이름은 전역 유일해야 하므로 계정 ID를 붙인다.
  bucket_name = "${var.bucket_prefix}-${var.aws_account_id}"

  bucket_arn = "arn:aws:s3:::${local.bucket_name}"

  # 오프사이트 job이 매 실행마다 쓰는 liveness object의 prefix.
  # 원본 bucket 사본과 섞이지 않도록 예약한다.
  heartbeat_prefix = "_heartbeat"

  # 원본 bucket 사본이 들어가는 prefix. 로컬 bucket 이름이 그대로 한 단계 아래에 온다.
  # 예: s3://<bucket>/seaweedfs/<로컬 bucket>/<key>
  source_copy_prefix = "seaweedfs"

  sns_topic_name = "${var.bucket_prefix}-alert"
}
