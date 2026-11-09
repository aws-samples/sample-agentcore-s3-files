"""Reusable A2A client for inter-agent invocation via AgentCore Runtime.

Signs an InvokeAgentRuntime (A2A message/send) call with SigV4. Used by the
orchestrator and agents to invoke AgentCore runtimes.
"""
import json
import os
from urllib.parse import quote
from uuid import uuid4

import boto3
import httpx
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

REGION = os.getenv("AWS_DEFAULT_REGION") or os.getenv("AWS_REGION")
if not REGION:
    raise RuntimeError("AWS_DEFAULT_REGION or AWS_REGION must be set")
AGENTCORE_ENDPOINT = f"https://bedrock-agentcore.{REGION}.amazonaws.com"


def _resolve_account_id() -> str:
    """Account id for building runtime ARNs. Prefer AWS_ACCOUNT_ID, else ask STS.

    Resolving from the caller's own credentials (sts:GetCallerIdentity) means the
    invoke works with zero configuration — an empty account id produces a malformed
    ARN (arn:...:REGION::runtime/...) and AgentCore rejects it with 403.
    """
    env = os.environ.get("AWS_ACCOUNT_ID", "")
    if env:
        return env
    try:
        return boto3.client("sts", region_name=REGION).get_caller_identity()["Account"]
    except Exception:
        return ""


ACCOUNT_ID = _resolve_account_id()

_SESSION_ID_MIN = 33
_SESSION_ID_MAX = 128


def ensure_valid_session_id(session_id: str) -> str:
    """AgentCore requires the session id to be 33-128 chars (Lesson 6)."""
    if len(session_id) < _SESSION_ID_MIN:
        session_id = session_id.ljust(_SESSION_ID_MIN, "0")
    return session_id[:_SESSION_ID_MAX]


def build_runtime_session_id(agent_id: str, scenario_id: str, differentiator: str = "") -> str:
    """Build a valid AgentCore runtimeSessionId (33-128 chars).

    Format: {agent_id}/{scenario_id}/{differentiator}.

    The SAME repo/mr always maps to the SAME session id for a given agent, so the
    agent and the MCP servers it calls attach to the SAME shared S3 workspace.
    `scenario_id` is the mr_id (or repo/mr key); `differentiator` isolates
    parallel runs (falls back to a slice of scenario_id when omitted).
    """
    diff = differentiator or scenario_id[:20]
    sid = f"{agent_id}/{scenario_id}/{diff}"
    return ensure_valid_session_id(sid)


def _runtime_url(runtime_id: str) -> str:
    if not ACCOUNT_ID:
        raise RuntimeError(
            "Could not resolve AWS account id for the runtime ARN. Set AWS_ACCOUNT_ID or "
            "ensure your AWS credentials allow sts:GetCallerIdentity."
        )
    arn = f"arn:aws:bedrock-agentcore:{REGION}:{ACCOUNT_ID}:runtime/{runtime_id}"
    return f"{AGENTCORE_ENDPOINT}/runtimes/{quote(arn, safe='')}/invocations/"


def invoke_agent_a2a(runtime_id: str, message: str, session_id: str | None = None,
                     timeout: int = 600) -> str:
    """Invoke an agent runtime via A2A (synchronous message/send)."""
    if not runtime_id:
        return "Error: runtime_id is empty or not set"

    url = _runtime_url(runtime_id)
    session_id = ensure_valid_session_id(session_id or str(uuid4()))

    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": str(uuid4()),
        "method": "message/send",
        "params": {
            "message": {
                "role": "user",
                "parts": [{"kind": "text", "text": message}],
                "messageId": str(uuid4()),
            }
        },
    })

    creds = boto3.Session(region_name=REGION).get_credentials()
    if not creds:
        return f"Error: unable to retrieve AWS credentials for A2A call to {runtime_id}"
    frozen = creds.get_frozen_credentials()

    headers = {
        "Content-Type": "application/json",
        "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": session_id,
    }
    req = AWSRequest(method="POST", url=url, data=payload, headers=headers)
    SigV4Auth(frozen, "bedrock-agentcore", REGION).add_auth(req)

    with httpx.Client(timeout=timeout) as client:
        resp = client.post(url, content=payload, headers=dict(req.headers))
        resp.raise_for_status()
        result = resp.json()

    artifacts = result.get("result", {}).get("artifacts", [])
    if artifacts:
        parts = artifacts[0].get("parts", [])
        if parts:
            return parts[0].get("text", "") or json.dumps(result)
    return json.dumps(result)[:2000]


def deterministic_session_id(name: str) -> str:
    """Deterministic 36-char session id from a workspace name (Lesson 6).

    The SAME repo/mr always maps to the SAME session id, so every agent in the
    workflow attaches to the same shared workspace.
    """
    import hashlib
    raw = hashlib.sha256(f"workspace:{name}".encode()).hexdigest()
    return f"{raw[:8]}-{raw[8:12]}-{raw[12:16]}-{raw[16:20]}-{raw[20:32]}"
