"""Gateway MCP client — low-level plumbing for AgentCore Gateway communication.

The agents reach the workspace + gitlab MCP servers THROUGH the AgentCore Gateway
(not by invoking the MCP runtimes directly). This module handles MCP session
initialization, tool discovery, SigV4 authentication, and JSON-RPC transport.
The @tool wrappers that agents actually call live in each agent's tools/ package
and delegate here via _call_gateway_tool().

Environment:
    GATEWAY_URL         — Gateway MCP endpoint
                          (https://{id}.gateway.bedrock-agentcore.{region}.amazonaws.com/mcp)
    AWS_DEFAULT_REGION  — region for SigV4 signing
"""

import json
import os
import threading
from uuid import uuid4

import boto3
import httpx
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

from shared.logging_config import get_logger

logger = get_logger("gateway_tools")

REGION = os.getenv("AWS_DEFAULT_REGION") or os.getenv("AWS_REGION")
if not REGION:
    raise RuntimeError("AWS_DEFAULT_REGION or AWS_REGION must be set")
GATEWAY_URL = os.getenv("GATEWAY_URL", "")

# MCP session state — one session per agent process, initialized lazily.
_session_id = ""
_initialized = False
_initialization_error: str | None = None
_init_lock = threading.Lock()
_tool_name_map: dict[str, str] = {}  # short name -> full (prefixed) gateway tool name


def _mcp_post(method: str, params: dict, timeout: int = 60) -> dict:
    """Send a SigV4-signed JSON-RPC request to the Gateway MCP endpoint."""
    global _session_id

    if not GATEWAY_URL:
        return {"error": "GATEWAY_URL not set"}

    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": str(uuid4()),
        "method": method,
        "params": params,
    })

    creds = boto3.Session(region_name=REGION).get_credentials()
    if not creds:
        return {"error": "Unable to retrieve AWS credentials"}
    frozen = creds.get_frozen_credentials()

    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
    }
    # Include the gateway-assigned session id on every call after initialize.
    if _session_id:
        headers["Mcp-Session-Id"] = _session_id

    req = AWSRequest(method="POST", url=GATEWAY_URL, data=payload, headers=headers)
    SigV4Auth(frozen, "bedrock-agentcore", REGION).add_auth(req)

    try:
        resp = httpx.post(GATEWAY_URL, content=payload, headers=dict(req.headers), timeout=timeout)

        # Capture the gateway-assigned session id from the response header.
        resp_session_id = resp.headers.get("mcp-session-id", "")
        if resp_session_id:
            _session_id = resp_session_id

        if resp.status_code != 200:
            return {"error": f"HTTP {resp.status_code}: {resp.text[:500]}"}

        text = resp.text.strip()
        # Gateway may reply as SSE (data: {...}) — take the last data line.
        if "data:" in text:
            data_lines = [ln for ln in text.split("\n") if ln.startswith("data:")]
            if data_lines:
                return json.loads(data_lines[-1].replace("data:", "").strip())
        return json.loads(text)
    except Exception as e:
        logger.error("gateway_mcp_call_failed", method=method, error=str(e))
        return {"error": str(e)}


def _ensure_initialized() -> str | None:
    """Initialize the MCP session and discover tool names (once per process).

    Thread-safe (double-checked locking) so ConcurrentToolExecutor can call
    multiple tools without racing the handshake. Initialization failures are
    cached so later calls fail fast instead of retrying the full handshake.
    """
    global _initialized, _initialization_error, _tool_name_map

    if _initialized:
        return _initialization_error

    with _init_lock:
        if _initialized:
            return _initialization_error

        init = _mcp_post("initialize", {
            "protocolVersion": "2025-03-26",
            "capabilities": {},
            "clientInfo": {"name": "agentcore-s3files-agent", "version": "1.0"},
        })
        if "error" in init:
            error = init["error"]
            _initialization_error = (
                error.get("message", str(error))
                if isinstance(error, dict)
                else str(error)
            )
            _initialized = True
            logger.error(
                "gateway_initialize_failed",
                error=_initialization_error,
            )
            return _initialization_error

        # Required by the MCP protocol after initialize.
        _mcp_post("notifications/initialized", {})

        # Discover tools — paginate (the gateway returns a bounded page size).
        cursor = None
        all_tools: list[dict] = []
        while True:
            params = {"cursor": cursor} if cursor else {}
            listed = _mcp_post("tools/list", params)
            if "result" not in listed:
                break
            all_tools.extend(listed["result"].get("tools", []))
            cursor = listed["result"].get("nextCursor")
            if not cursor:
                break

        # Gateway prefixes tool names as "<target>___<tool>". Map the short name
        # (what the agent code calls) to the full prefixed name.
        for t in all_tools:
            full = t.get("name", "")
            short = full.split("___", 1)[1] if "___" in full else full
            _tool_name_map[short] = full

        logger.info("gateway_tools_discovered", count=len(all_tools),
                    tools=list(_tool_name_map.keys()))
        _initialized = True
        return None


def call_gateway_tool(tool_name: str, arguments: dict, timeout: int = 120) -> str:
    """Call a gateway tool by its short name; returns the tool's text result.

    Handles lazy session init and short->prefixed name mapping. Errors are
    returned as a JSON string so the calling @tool surfaces them to the model.
    """
    initialization_error = _ensure_initialized()
    if initialization_error:
        return json.dumps({
            "error": f"Gateway initialization failed: {initialization_error}"
        })

    actual = _tool_name_map.get(tool_name, tool_name)
    result = _mcp_post("tools/call", {"name": actual, "arguments": arguments}, timeout=timeout)

    if "error" in result:
        err = result["error"]
        msg = err.get("message", str(err)) if isinstance(err, dict) else str(err)
        return json.dumps({"error": msg})

    content = result.get("result", {}).get("content", [])
    if content and isinstance(content, list):
        text = content[0].get("text", "")
        # Some tools wrap their payload as {"result": ...}; unwrap when present.
        try:
            parsed = json.loads(text)
            if isinstance(parsed, dict) and "result" in parsed:
                return parsed["result"] if isinstance(parsed["result"], str) else json.dumps(parsed["result"])
        except (json.JSONDecodeError, TypeError):
            pass
        return text

    return json.dumps(result)
