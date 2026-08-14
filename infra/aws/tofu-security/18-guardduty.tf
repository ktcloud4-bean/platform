# GuardDuty Foundational - Runtime Monitoring은 의도적으로 안 켬(Falco 담당 영역과
# 중복). aws_guardduty_detector_feature로 EKS_RUNTIME_MONITORING/RUNTIME_MONITORING을
# 켜는 리소스를 여기 추가하지 않는 것 자체가 그 결정을 코드로 표현한 것.

resource "aws_guardduty_detector" "main" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  tags = {
    Name = "${local.name_prefix}-guardduty"
  }
}

output "guardduty_detector_id" {
  value = aws_guardduty_detector.main.id
}
