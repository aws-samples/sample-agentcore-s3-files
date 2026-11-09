"""Bindings used by the deployed AgentCore integration tests."""

import os
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
TERRAFORM_DIR = REPO_ROOT / "terraform"
SRC_DIR = REPO_ROOT / "src"


def _terraform_output(name: str) -> str:
    result = subprocess.run(
        ["terraform", f"-chdir={TERRAFORM_DIR}", "output", "-raw", name],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return result.stdout.strip()


os.environ.setdefault("AWS_DEFAULT_REGION", _terraform_output("aws_region"))
os.environ.setdefault("GATEWAY_URL", _terraform_output("gateway_url"))
sys.path.insert(0, str(SRC_DIR))

from shared.a2a_client import deterministic_session_id  # noqa: E402,F401
from shared.gateway_tools import call_gateway_tool  # noqa: E402


def call_mcp(tool_name: str, arguments: dict, session_id: str | None = None) -> str:
    """Call a deployed MCP tool through the AWS_IAM-protected AgentCore Gateway."""
    del session_id  # The gateway client owns and reuses its negotiated MCP session.
    return call_gateway_tool(tool_name, arguments)
