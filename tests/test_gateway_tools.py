"""Regression tests for AgentCore Gateway session initialization."""

import json
import os
from unittest.mock import patch

os.environ.setdefault("AWS_DEFAULT_REGION", "ap-southeast-1")

from shared import gateway_tools


def test_initialization_failure_is_cached_and_returned():
    with (
        patch.object(gateway_tools, "_initialized", False),
        patch.object(gateway_tools, "_initialization_error", None),
        patch.object(gateway_tools, "_tool_name_map", {}),
        patch.object(
            gateway_tools,
            "_mcp_post",
            return_value={"error": "gateway unavailable"},
        ) as mcp_post,
    ):
        first = json.loads(gateway_tools.call_gateway_tool("example", {}))
        second = json.loads(gateway_tools.call_gateway_tool("example", {}))

    assert first == {
        "error": "Gateway initialization failed: gateway unavailable"
    }
    assert second == first
    mcp_post.assert_called_once()
