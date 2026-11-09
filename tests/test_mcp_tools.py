"""Deployed MCP tool lifecycle test: setup -> write -> read -> cleanup."""
import json
from uuid import uuid4

from _helpers import call_mcp


def test_workspace_lifecycle():
    correlation_id = f"test-run-{uuid4().hex[:12]}"
    result = call_mcp("setup_workspace", {
        "repo_name": "my-repo", "mr_id": "42", "correlation_id": correlation_id
    })
    data = json.loads(result)
    assert data["storage_mode"] == "s3files"
    assert data["correlation_id"] == correlation_id

    result = call_mcp(
        "write_file",
        {
            "repo_name": "my-repo",
            "mr_id": "42",
            "correlation_id": correlation_id,
            "file_path": "plans/test.md",
            "content": "# Test Plan\nThis is a test.",
        },
    )
    assert json.loads(result)["status"] == "written"

    result = call_mcp(
        "read_file",
        {
            "repo_name": "my-repo",
            "mr_id": "42",
            "correlation_id": correlation_id,
            "file_path": "plans/test.md",
        },
    )
    assert "Test Plan" in result

    result = call_mcp("cleanup_workspace", {
        "repo_name": "my-repo", "mr_id": "42", "correlation_id": correlation_id
    })
    assert json.loads(result)["status"] == "cleaned"


def test_correlation_id_isolation():
    """Two runs on the same MR with different correlation_ids are isolated."""
    run_suffix = uuid4().hex[:12]
    correlation_id_a = f"run-a-{run_suffix}"
    correlation_id_b = f"run-b-{run_suffix}"
    call_mcp("setup_workspace", {
        "repo_name": "iso-repo", "mr_id": "10", "correlation_id": correlation_id_a
    })
    call_mcp("setup_workspace", {
        "repo_name": "iso-repo", "mr_id": "10", "correlation_id": correlation_id_b
    })

    # Write only to the first run.
    call_mcp("write_file", {
        "repo_name": "iso-repo", "mr_id": "10", "correlation_id": correlation_id_a,
        "file_path": "reviews/analysis.md", "content": "Run AAA analysis",
    })

    # The second run should not see the first run's file.
    result = call_mcp("read_file", {
        "repo_name": "iso-repo", "mr_id": "10", "correlation_id": correlation_id_b,
        "file_path": "reviews/analysis.md",
    })
    assert "File not found" in result

    # Cleanup both
    call_mcp("cleanup_workspace", {
        "repo_name": "iso-repo", "mr_id": "10", "correlation_id": correlation_id_a
    })
    call_mcp("cleanup_workspace", {
        "repo_name": "iso-repo", "mr_id": "10", "correlation_id": correlation_id_b
    })
