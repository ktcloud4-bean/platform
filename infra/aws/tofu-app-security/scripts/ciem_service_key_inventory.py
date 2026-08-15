"""AWS-SEC-07 /service/ IAM access key read-only inventory and alert."""

import json
import os
from datetime import datetime, timedelta, timezone

import boto3


iam = boto3.client("iam")
sns = boto3.client("sns")
ROTATION_DAYS = int(os.environ["ROTATION_DAYS"])
EXPECTED_USERS = json.loads(os.environ["EXPECTED_SERVICE_USERS_JSON"])
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]


def _date(value):
    return value.astimezone(timezone.utc).date().isoformat() if value else "MISSING"


def _days_since(value):
    if value is None:
        return None
    return (datetime.now(timezone.utc) - value).days


def _owner(username):
    for tag in iam.list_user_tags(UserName=username).get("Tags", []):
        if tag.get("Key") == "Owner" and tag.get("Value", "").strip():
            return tag["Value"].strip()
    return None


def _last_used(access_key_id):
    return iam.get_access_key_last_used(AccessKeyId=access_key_id).get("AccessKeyLastUsed", {}).get("LastUsedDate")


def _inventory_users():
    users = {}
    for page in iam.get_paginator("list_users").paginate():
        for user in page.get("Users", []):
            if user.get("Path", "").startswith("/service/"):
                users[user["UserName"]] = user
    return users


def _summary_line(row):
    return (
        f"role={row['role']} user={row['username']} slot={row['slot']} "
        f"owner={row['owner']} status={row['status']} "
        f"created={row['created']} age_days={row['age_days']} "
        f"last_used={row['last_used']} last_used_days={row['last_used_days']} "
        f"rotation_deadline={row['rotation_deadline']}"
    )


def handler(event, context):
    service_users = _inventory_users()
    service_keys = {
        username: iam.list_access_keys(UserName=username).get("AccessKeyMetadata", [])
        for username in service_users
    }
    expected_user_names = set(EXPECTED_USERS.values())
    issues = []
    rows = []

    unexpected_users = sorted(set(service_users) - expected_user_names)
    missing_users = sorted(expected_user_names - set(service_users))
    if unexpected_users:
        issues.append(f"unexpected_service_users={','.join(unexpected_users)}")
    if missing_users:
        issues.append(f"missing_service_users={','.join(missing_users)}")

    role_by_user = {username: role for role, username in EXPECTED_USERS.items()}
    for username in sorted(service_users):
        if username not in role_by_user:
            continue
        user = service_users[username]
        owner = _owner(username)
        keys = service_keys[username]
        role = role_by_user[username]
        if len(keys) != 1:
            issues.append(f"key_count:{role}={len(keys)}")
        if owner is None:
            issues.append(f"owner_missing:{role}")
        for slot, key in enumerate(keys, start=1):
            created_at = key.get("CreateDate")
            age_days = _days_since(created_at)
            last_used_at = _last_used(key["AccessKeyId"])
            last_used_days = _days_since(last_used_at)
            row = {
                "role": role_by_user[username],
                "username": username,
                "slot": slot,
                "owner": owner or "MISSING",
                "status": key.get("Status", "MISSING"),
                "created": _date(created_at),
                "age_days": age_days if age_days is not None else "MISSING",
                "last_used": _date(last_used_at),
                "last_used_days": last_used_days if last_used_days is not None else "MISSING",
                "rotation_deadline": (
                    (created_at + timedelta(days=ROTATION_DAYS)).astimezone(timezone.utc).date().isoformat()
                    if created_at
                    else "MISSING"
                ),
            }
            rows.append(row)
            if last_used_at is None:
                issues.append(f"last_used_missing:{role}:slot={slot}")
            if age_days is None:
                issues.append(f"created_missing:{role}:slot={slot}")
            elif age_days >= ROTATION_DAYS:
                issues.append(f"rotation_due:{role}:slot={slot}")
            if key.get("Status") != "Active":
                issues.append(f"inactive_key:{role}:slot={slot}")

    status = "ALERT" if issues else "OK"
    lines = [
        f"AWS-SEC-07 service IAM key inventory status={status}",
        f"expected_users={len(EXPECTED_USERS)} observed_users={len(service_users)} observed_keys={sum(len(keys) for keys in service_keys.values())}",
        f"rotation_days={ROTATION_DAYS}",
    ]
    lines.extend(_summary_line(row) for row in rows)
    lines.append("issues=" + (";".join(issues) if issues else "none"))
    lines.append("automatic_disable_delete=0")
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="AWS-SEC-07 service IAM key inventory",
        Message="\n".join(lines),
    )

    return {
        "statusCode": 200,
        "status": status,
        "expected_users": len(EXPECTED_USERS),
        "observed_service_users": len(service_users),
        "observed_service_keys": sum(len(keys) for keys in service_keys.values()),
        "issue_count": len(issues),
        "automatic_disable_delete": 0,
    }
