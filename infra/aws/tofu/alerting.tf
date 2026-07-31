# 백업 실패 경보 채널.
# 온프레미스가 통째로 죽어도 경보 경로는 살아 있어야 하므로 AWS 쪽에 둔다.
resource "aws_sns_topic" "alert" {
  name = local.sns_topic_name
}

# email 구독은 수신자가 확인 링크를 눌러야 활성화된다.
# 확인 전 상태는 PendingConfirmation이며 경보가 전달되지 않는다.
resource "aws_sns_topic_subscription" "alert_email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alert.arn
  protocol  = "email"
  endpoint  = var.alert_email

  # AWS는 확인된 email 구독의 endpoint를 반환하지 않는 경우가 있어
  # 확인 상태 변화로 재생성이 계획되지 않게 한다.
  lifecycle {
    ignore_changes = [endpoint]
  }
}

# job이 실패하면 OnFailure 유닛이 SNS로 알린다.
# 그러나 host나 timer가 통째로 죽어 job이 "실행조차 되지 않는" 실패는 그 경로로 잡히지 않는다.
# 성공할 때만 올라오는 heartbeat metric의 부재를 breaching으로 취급해 그 구멍을 메운다.
# 실제로 전송 job이 도는 동안에만 연다. 닫혀 있으면 alarm을 선언하지 않는다.
resource "aws_cloudwatch_metric_alarm" "offsite_heartbeat" {
  count = var.enable_heartbeat_alarm ? 1 : 0

  alarm_name        = "${var.bucket_prefix}-heartbeat-missing"
  alarm_description = "오프사이트 백업 성공 heartbeat가 하루 동안 올라오지 않았다. job·timer·host·자격증명 중 하나가 죽었다."

  namespace   = var.heartbeat_metric_namespace
  metric_name = var.heartbeat_metric_name
  statistic   = "Sum"

  period             = 86400
  evaluation_periods = 1

  comparison_operator = "LessThanThreshold"
  threshold           = 1

  # 데이터가 없는 것 자체가 실패 신호다. 기본값(missing)이면 영원히 침묵한다.
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.alert.arn]
  ok_actions    = [aws_sns_topic.alert.arn]
}
