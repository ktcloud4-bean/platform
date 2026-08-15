"""AWS-SEC-03: 월간 IAM Access Analyzer 미사용 접근 요약."""

import boto3
import os


analyzer = boto3.client("accessanalyzer")
sns = boto3.client("sns")


def handler(event, context):
    findings = []
    paginator = analyzer.get_paginator("list_findings_v2")
    for page in paginator.paginate(
        analyzerArn=os.environ["ANALYZER_ARN"],
        filter={"status": {"eq": ["ACTIVE"]}},
    ):
        findings.extend(page.get("findings", []))

    lines = [f"CIEM unused access monthly findings: {len(findings)}"]
    for finding in findings[:20]:
        lines.append(f"- {finding.get('findingType', 'unknown')}: {finding.get('resource', 'unknown')}")
    if len(findings) > 20:
        lines.append(f"- additional findings: {len(findings) - 20}")

    sns.publish(
        TopicArn=os.environ["SNS_TOPIC_ARN"],
        Subject="CIEM unused access monthly report",
        Message="\n".join(lines),
    )
    return {"statusCode": 200, "findings": len(findings)}
