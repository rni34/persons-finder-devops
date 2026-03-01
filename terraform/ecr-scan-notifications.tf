# ---------- ECR Image Scan Finding Notifications ----------
# ECR scan-on-push is enabled but findings are only visible in the AWS Console.
# For a PII-handling app, critical CVEs in container images require immediate
# attention — not passive console checks. This routes CRITICAL findings to SNS
# via EventBridge so the team is notified when a pushed image has severe CVEs.
#
# Note: ECR basic scanning only runs on push. For continuous scanning of
# already-pushed images against new CVEs, enable ECR enhanced scanning
# (Amazon Inspector).

resource "aws_cloudwatch_event_rule" "ecr_scan_findings" {
  name        = "${var.cluster_name}-ecr-critical-findings"
  description = "Notify on ECR image scan CRITICAL findings"

  # finding-severity-counts only includes keys with non-zero counts (per AWS docs),
  # so "exists: true" correctly matches only when CRITICAL findings are present.
  event_pattern = jsonencode({
    source      = ["aws.ecr"]
    detail-type = ["ECR Image Scan"]
    detail = {
      scan-status = ["COMPLETE"]
      finding-severity-counts = {
        CRITICAL = [{ exists = true }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "ecr_scan_sns" {
  rule      = aws_cloudwatch_event_rule.ecr_scan_findings.name
  target_id = "ecr-scan-to-sns"
  arn       = aws_sns_topic.guardduty_findings.arn

  input_transformer {
    input_paths = {
      repo     = "$.detail.repository-name"
      digest   = "$.detail.image-digest"
      findings = "$.detail.finding-severity-counts"
      account  = "$.account"
      region   = "$.region"
    }
    input_template = "\"ECR Image Scan CRITICAL findings in <repo> (<region>, account <account>). Digest: <digest>. Severity counts: <findings>. Review: aws ecr describe-image-scan-findings --repository-name <repo> --image-id imageDigest=<digest>\""
  }
}
