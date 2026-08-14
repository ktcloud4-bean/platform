# CloudTrail → CloudWatch Logs 경로에서 CIS CloudWatch control 12개를 metric/alarm으로 만든다.
locals {
  cis_cloudwatch_alarms = {
    root_account_usage = {
      control_id  = "CloudWatch.1"
      metric_name = "RootAccountUsageCount"
      pattern     = "{ $.userIdentity.type = \"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType != \"AwsServiceEvent\" }"
      description = "루트 계정 사용 감지"
    }
    iam_policy_changes = {
      control_id  = "CloudWatch.4"
      metric_name = "IAMPolicyChangesCount"
      pattern     = "{($.eventName=DeleteGroupPolicy)||($.eventName=DeleteRolePolicy)||($.eventName=DeleteUserPolicy)||($.eventName=PutGroupPolicy)||($.eventName=PutRolePolicy)||($.eventName=PutUserPolicy)||($.eventName=CreatePolicy)||($.eventName=DeletePolicy)||($.eventName=CreatePolicyVersion)||($.eventName=DeletePolicyVersion)||($.eventName=AttachRolePolicy)||($.eventName=DetachRolePolicy)||($.eventName=AttachUserPolicy)||($.eventName=DetachUserPolicy)||($.eventName=AttachGroupPolicy)||($.eventName=DetachGroupPolicy)}"
      description = "IAM 정책 변경 감지"
    }
    cloudtrail_changes = {
      control_id  = "CloudWatch.5"
      metric_name = "CloudTrailChangesCount"
      pattern     = "{($.eventName=CreateTrail)||($.eventName=UpdateTrail)||($.eventName=DeleteTrail)||($.eventName=StartLogging)||($.eventName=StopLogging)}"
      description = "CloudTrail 설정 변경 감지"
    }
    console_auth_failures = {
      control_id  = "CloudWatch.6"
      metric_name = "ConsoleAuthFailureCount"
      pattern     = "{($.eventName=ConsoleLogin) && ($.errorMessage=\"Failed authentication\")}"
      description = "AWS 콘솔 로그인 실패 감지"
    }
    cmk_deletion = {
      control_id  = "CloudWatch.7"
      metric_name = "CMKDeletionCount"
      pattern     = "{($.eventSource=kms.amazonaws.com) && (($.eventName=DisableKey)||($.eventName=ScheduleKeyDeletion))}"
      description = "CMK 비활성화 또는 삭제 예약 감지"
    }
    s3_bucket_policy_changes = {
      control_id  = "CloudWatch.8"
      metric_name = "S3BucketPolicyChangesCount"
      pattern     = "{($.eventSource=s3.amazonaws.com) && (($.eventName=PutBucketAcl) || ($.eventName=PutBucketPolicy) || ($.eventName=PutBucketCors) || ($.eventName=PutBucketLifecycle) || ($.eventName=PutBucketReplication) || ($.eventName=DeleteBucketPolicy) || ($.eventName=DeleteBucketCors) || ($.eventName=DeleteBucketLifecycle) || ($.eventName=DeleteBucketReplication))}"
      description = "S3 버킷 정책 변경 감지"
    }
    config_changes = {
      control_id  = "CloudWatch.9"
      metric_name = "ConfigChangesCount"
      pattern     = "{($.eventSource = config.amazonaws.com) && (($.eventName=StopConfigurationRecorder)||($.eventName=DeleteDeliveryChannel)||($.eventName=PutDeliveryChannel)||($.eventName=PutConfigurationRecorder))}"
      description = "AWS Config 설정 변경 감지"
    }
    security_group_changes = {
      control_id  = "CloudWatch.10"
      metric_name = "SecurityGroupChangesCount"
      pattern     = "{($.eventName=AuthorizeSecurityGroupIngress)||($.eventName=AuthorizeSecurityGroupEgress)||($.eventName=RevokeSecurityGroupIngress)||($.eventName=RevokeSecurityGroupEgress)||($.eventName=CreateSecurityGroup)||($.eventName=DeleteSecurityGroup)}"
      description = "보안 그룹 변경 감지"
    }
    nacl_changes = {
      control_id  = "CloudWatch.11"
      metric_name = "NaclChangesCount"
      pattern     = "{($.eventName=CreateNetworkAcl)||($.eventName=CreateNetworkAclEntry)||($.eventName=DeleteNetworkAcl)||($.eventName=DeleteNetworkAclEntry)||($.eventName=ReplaceNetworkAclEntry)||($.eventName=ReplaceNetworkAclAssociation)}"
      description = "네트워크 ACL 변경 감지"
    }
    network_gateway_changes = {
      control_id  = "CloudWatch.12"
      metric_name = "NetworkGatewayChangesCount"
      pattern     = "{($.eventName=CreateCustomerGateway)||($.eventName=DeleteCustomerGateway)||($.eventName=AttachInternetGateway)||($.eventName=CreateInternetGateway)||($.eventName=DeleteInternetGateway)||($.eventName=DetachInternetGateway)}"
      description = "네트워크 gateway 변경 감지"
    }
    route_table_changes = {
      control_id  = "CloudWatch.13"
      metric_name = "RouteTableChangesCount"
      pattern     = "{($.eventName=CreateRoute)||($.eventName=CreateRouteTable)||($.eventName=ReplaceRoute)||($.eventName=ReplaceRouteTableAssociation)||($.eventName=DeleteRouteTable)||($.eventName=DeleteRoute)||($.eventName=DisassociateRouteTable)}"
      description = "라우팅 테이블 변경 감지"
    }
    vpc_changes = {
      control_id  = "CloudWatch.14"
      metric_name = "VpcChangesCount"
      pattern     = "{($.eventName=CreateVpc)||($.eventName=DeleteVpc)||($.eventName=ModifyVpcAttribute)||($.eventName=AcceptVpcPeeringConnection)||($.eventName=CreateVpcPeeringConnection)||($.eventName=DeleteVpcPeeringConnection)||($.eventName=RejectVpcPeeringConnection)||($.eventName=AttachClassicLinkVpc)||($.eventName=DetachClassicLinkVpc)||($.eventName=DisableVpcClassicLink)||($.eventName=EnableVpcClassicLink)}"
      description = "VPC 변경 감지"
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "cis" {
  for_each       = local.cis_cloudwatch_alarms
  name           = "${local.name_prefix}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = each.value.pattern

  metric_transformation {
    name          = each.value.metric_name
    namespace     = "CISBenchmark/${local.name_prefix}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "cis" {
  for_each = local.cis_cloudwatch_alarms

  alarm_name          = "${local.name_prefix}-${each.key}"
  alarm_description   = "${each.value.description} (${each.value.control_id})"
  namespace           = "CISBenchmark/${local.name_prefix}"
  metric_name         = each.value.metric_name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.security_alerts.arn]

  depends_on = [aws_cloudwatch_log_metric_filter.cis]
}
