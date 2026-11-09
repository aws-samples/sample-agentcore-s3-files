"""Security and storage-boundary regression tests for the Workspace MCP server."""

import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch


SERVER_PATH = (
    Path(__file__).resolve().parents[1]
    / "src"
    / "mcp-servers"
    / "workspace"
    / "server.py"
)
SPEC = importlib.util.spec_from_file_location("workspace_mcp_server", SERVER_PATH)
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


def test_storage_mode_checks_the_dedicated_workspace_mount():
    with TemporaryDirectory() as workspace_mount:
        with patch.object(server, "WORKSPACES_DIR", workspace_mount):
            with patch.object(
                server.os.path,
                "ismount",
                side_effect=lambda path: path == workspace_mount,
            ) as ismount:
                result = json.loads(
                    server.setup_workspace("demo", "1", "test-correlation")
                )

    assert result["storage_mode"] == "s3files"
    ismount.assert_called_once_with(workspace_mount)


def test_workspace_names_require_a_full_regex_match():
    result = json.loads(server.setup_workspace("demo\n", "1", "test-correlation"))

    assert result["error"].startswith("Invalid repo_name")
