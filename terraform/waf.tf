# ---------- WAF WebACL for ALB (internet-facing, handles PII) ----------
resource "aws_wafv2_web_acl" "alb" {
  name        = "${var.cluster_name}-alb-waf"
  description = "WAF for persons-finder ALB — blocks OWASP Top 10, SQLi, known bad inputs"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # AWS Managed Rules — IP Reputation List (evaluate first)
  # Blocks IPs from Amazon threat intelligence: known bots, DDoS sources,
  # and IPs performing reconnaissance against AWS resources. Evaluated at
  # priority 0 so known-bad IPs are rejected before spending WCU on
  # content-inspection rules. Per AWS DDoS resiliency whitepaper, the
  # AWSManagedIPDDoSList sub-rule blocks over 90% of malicious request floods.
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 0
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAmazonIpReputationList"
    }
  }

  # AWS Managed Rules — Core Rule Set (OWASP Top 10 basics)
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
    }
  }

  # AWS Managed Rules — Known Bad Inputs (Log4Shell, etc.)
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
    }
  }

  # AWS Managed Rules — SQL Injection
  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 3
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesSQLiRuleSet"
    }
  }

  # Rate limiting — prevents API bill abuse and application-layer DDoS.
  # Each LLM request costs money (token-based pricing); without rate limiting,
  # a single IP can exhaust the OpenAI API quota or run up unbounded costs.
  rule {
    name     = "RateLimitPerIP"
    priority = 4
    action { block {} }
    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIP"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.cluster_name}-alb-waf"
  }
}

# ---------- WAF Logging — blocked request forensics ----------
# CloudWatch metrics (visibility_config) only provide aggregate counts per rule.
# Sampled requests are retained for 3 hours and cover a small subset. Neither
# supports incident investigation, false positive tuning, or compliance auditing.
# Full logging captures every blocked request with headers, URI, source IP, and
# matched rule — essential for a PII-handling app under SOC2/HIPAA.
# Cost optimization: logging_filter restricts to BLOCK actions only, avoiding
# the high volume of ALLOW request logs.

resource "aws_cloudwatch_log_group" "waf" {
  # Name MUST start with "aws-waf-logs-" — AWS WAF validates this prefix
  name              = "aws-waf-logs-${var.cluster_name}"
  retention_in_days = 30
}

resource "aws_wafv2_web_acl_logging_configuration" "alb" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.alb.arn

  # Only log blocked requests — keeps costs low while capturing all security events.
  # ALLOW requests are high-volume normal traffic; BLOCK requests are the ones
  # that need investigation (attack attempts, false positives, rate limit hits).
  logging_filter {
    default_behavior = "DROP"

    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"

      condition {
        action_condition {
          action = "BLOCK"
        }
      }
    }
  }

  # Redact sensitive headers from logs — Authorization and Cookie headers may
  # contain session tokens or API keys that should not appear in CloudWatch.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}

output "waf_acl_arn" {
  description = "WAF WebACL ARN for ALB ingress annotation"
  value       = aws_wafv2_web_acl.alb.arn
}
