"""
ConnectSetChatTimeouts
----------------------
Amazon Connect contact-flow Lambda that configures chat timeouts for the
*customer* participant by calling the Connect UpdateParticipantRoleConfig API.

It sets:
  - Customer idle timeout            (TimerType=IDLE)
  - Customer auto-disconnect timeout (TimerType=DISCONNECT_NONCUSTOMER)

Both timers are applied to the CUSTOMER participant role and persist for the
life of the chat (and across transfers).

Docs:
  https://docs.aws.amazon.com/connect/latest/adminguide/setup-chat-timeouts.html
  https://docs.aws.amazon.com/boto3/latest/reference/services/connect/client/update_participant_role_config.html

Invocation attributes (set in the contact flow's "Invoke AWS Lambda function"
block, all optional - defaults shown):
  customerIdleTimeoutMinutes            default 5
  customerAutoDisconnectTimeoutMinutes  default 10

Connect timer limits: minimum 2 minutes, maximum 480 minutes (8 hours).
"""

import os
import boto3

connect = boto3.client("connect")

# Connect's documented timer bounds (minutes).
MIN_MINUTES = 2
MAX_MINUTES = 480

DEFAULT_CUSTOMER_IDLE_MINUTES = 5
DEFAULT_CUSTOMER_AUTO_DISCONNECT_MINUTES = 10


def _instance_id_from_arn(instance_arn):
    """Return the instance id (last path segment) from an instance ARN."""
    if not instance_arn:
        return None
    return instance_arn.rstrip("/").split("/")[-1]


def _coerce_minutes(raw, default):
    """Parse a minutes value and clamp it to Connect's allowed range."""
    try:
        minutes = int(float(raw))
    except (TypeError, ValueError):
        minutes = default
    return max(MIN_MINUTES, min(MAX_MINUTES, minutes))


def lambda_handler(event, context):
    details = event.get("Details", {}) or {}
    contact_data = details.get("ContactData", {}) or {}
    params = details.get("Parameters", {}) or {}

    contact_id = contact_data.get("ContactId")
    instance_id = (
        _instance_id_from_arn(contact_data.get("InstanceARN"))
        or os.environ.get("CONNECT_INSTANCE_ID")
    )

    if not contact_id or not instance_id:
        return {
            "status": "ERROR",
            "message": "Missing ContactId or InstanceId in the contact event.",
        }

    idle_minutes = _coerce_minutes(
        params.get("customerIdleTimeoutMinutes"),
        DEFAULT_CUSTOMER_IDLE_MINUTES,
    )
    auto_disconnect_minutes = _coerce_minutes(
        params.get("customerAutoDisconnectTimeoutMinutes"),
        DEFAULT_CUSTOMER_AUTO_DISCONNECT_MINUTES,
    )

    timer_config_list = [
        {
            "ParticipantRole": "CUSTOMER",
            "TimerType": "IDLE",
            "TimerValue": {"ParticipantTimerDurationInMinutes": idle_minutes},
        },
        {
            "ParticipantRole": "CUSTOMER",
            "TimerType": "DISCONNECT_NONCUSTOMER",
            "TimerValue": {
                "ParticipantTimerDurationInMinutes": auto_disconnect_minutes
            },
        },
    ]

    connect.update_participant_role_config(
        InstanceId=instance_id,
        ContactId=contact_id,
        ChannelConfiguration={
            "Chat": {"ParticipantTimerConfigList": timer_config_list}
        },
    )

    return {
        "status": "SUCCESS",
        "customerIdleTimeoutMinutes": str(idle_minutes),
        "customerAutoDisconnectTimeoutMinutes": str(auto_disconnect_minutes),
    }
