# ---------- GuardDuty — EKS Threat Detection ----------
# Two layers of threat detection:
# 1. Audit Log Monitoring (detector datasource): Analyzes K8s API calls for
#    suspicious activity — anonymous access, privilege escalation, known attack
#    tools, Tor exit nodes, credential exfiltration.
# 2. Runtime Monitoring (detector_feature): Deploys a security agent DaemonSet
#    on each node that monitors OS-level container activity — process execution,
#    file access, network connections. Detects crypto mining, reverse shells,
#    container escape attempts that audit logs cannot see.
#
# Cost: ~$4/million events (audit logs) + ~$1.50/vCPU/month (runtime).
#
# NOTE: GuardDuty is account-level. If already enabled, import the existing
# detector: terraform import aws_guardduty_detector.main <detector-id>
resource "aws_guardduty_detector" "main" {
  enable = true

  datasources {
    kubernetes {
      audit_logs {
        enable = true
      }
    }
  }

  tags = {
    Name = "persons-finder-guardduty"
  }
}

# Runtime Monitoring — container-level threat detection via managed DaemonSet.
# EKS_ADDON_MANAGEMENT auto-deploys and updates the GuardDuty security agent
# as an EKS managed addon (aws-guardduty-agent), eliminating manual DaemonSet
# management. This is the AWS-native equivalent of Falco.
resource "aws_guardduty_detector_feature" "runtime_monitoring" {
  detector_id = aws_guardduty_detector.main.id
  name        = "RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }
}

# ---------- GuardDuty Finding Notifications ----------
# Without notifications, findings sit in the console unnoticed. For a PII-handling
# app, delayed response to threats (crypto mining, container escape, credential
# exfiltration) is unacceptable. EventBridge catches all MEDIUM+ findings and
# routes to SNS for email/Slack/PagerDuty integration.

resource "aws_sns_topic" "guardduty_findings" {
  name              = "${var.cluster_name}-guardduty-findings"
  # CKV_AWS_26 / Security Hub SNS.1: Encrypt at rest. GuardDuty findings contain
  # threat details, source IPs, and resource identifiers — sensitive security data.
  # AWS-managed key avoids CMK key policy complexity; EventBridge can publish
  # to aws/sns-encrypted topics without additional IAM grants.
  kms_master_key_id = "alias/aws/sns"
}

# Enforce TLS for SNS subscriptions (CIS AWS 2.x)
resource "aws_sns_topic_policy" "guardduty_findings" {
  arn = aws_sns_topic.guardduty_findings.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.guardduty_findings.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = [
              aws_cloudwatch_event_rule.guardduty_findings.arn,
              aws_cloudwatch_event_rule.ecr_scan_findings.arn
            ]
          }
        }
      },
      {
        Sid       = "EnforceTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.guardduty_findings.arn
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  name        = "${var.cluster_name}-guardduty-findings"
  description = "Route GuardDuty MEDIUM+ findings to SNS for alerting"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 4] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_findings.name
  target_id = "guardduty-to-sns"
  arn       = aws_sns_topic.guardduty_findings.arn

  input_transformer {
    input_paths = {
      severity    = "$.detail.severity"
      type        = "$.detail.type"
      description = "$.detail.description"
      region      = "$.detail.region"
      account     = "$.detail.accountId"
    }
    input_template = "\"GuardDuty Finding [severity <severity>] in <region> (account <account>): <type> — <description>\""
  }
}
