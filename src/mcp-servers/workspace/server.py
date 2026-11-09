"""Workspace MCP Server — reviews/ + plans/ on the shared S3 Files mount.

Owns /mnt/workspaces/{repo_name}/{mr_id}/{correlation_id}/. AgentCore mounts
S3 Files natively, so no mount logic is needed here.

The correlation_id isolates concurrent or repeated runs on the same MR, provides
an audit trail, and enables end-to-end traceability across agents.
"""
import json
import os
import shutil
from pathlib import Path

from mcp.server.fastmcp import FastMCP

# Bind to all interfaces: this server runs inside an AgentCore-managed container
# with no published host port — it is reachable only through the gateway on the
# private VPC network, so binding 0.0.0.0 is required and does not widen exposure.
mcp = FastMCP(host="0.0.0.0", stateless_http=True, json_response=True)  # nosec B104

S3_MOUNT = os.getenv("S3_MOUNT_PATH", "/mnt")
WORKSPACES_DIR = os.path.join(S3_MOUNT, "workspaces")


def _resolve_path(file_path: str, allowed_root: str):
    """Resolve a caller-supplied path to an absolute path inside allowed_root.

    Accepts the path shapes an LLM commonly produces so a legitimate workspace
    file is not mistaken for a traversal attempt:
      * absolute inside root   ("/mnt/workspaces/<repo>/<mr>/<cid>/reviews/x.md")
      * root-relative           ("reviews/x.md", "./reviews/x.md")
      * leading-slash root-rel  ("/reviews/x.md" -> "reviews/x.md")

    Returns (real_path, root). Genuine escapes ("../../etc/passwd") resolve
    outside root and are rejected by _is_safe_path.
    """
    root = os.path.realpath(allowed_root)
    candidate = (file_path or "").strip()
    if os.path.isabs(candidate):
        abs_candidate = os.path.realpath(candidate)
        if abs_candidate == root or abs_candidate.startswith(root + os.sep):
            return abs_candidate, root
        candidate = candidate.lstrip("/")
    real = os.path.realpath(os.path.join(root, candidate))
    return real, root


def _is_safe_path(file_path: str, allowed_root: str) -> bool:
    real, root = _resolve_path(file_path, allowed_root)
    return real == root or real.startswith(root + os.sep)


import re as _re
_SAFE_NAME = _re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$")


def _validate_name(value: str, field: str):
    if not value or not _SAFE_NAME.fullmatch(value):
        return f"Invalid {field}: 1-100 alphanumerics, dots, hyphens, underscores only"
    return None


def _workspace_root(repo_name: str, mr_id: str, correlation_id: str) -> str:
    """Per-run workspace root: /mnt/workspaces/{repo_name}/{mr_id}/{correlation_id}/.

    File tools resolve caller paths RELATIVE to this root, so the model can pass a
    simple 'reviews/analysis.md' (plus the repo_name, mr_id, and correlation_id it
    already knows) and the file always lands inside the correct per-run workspace.
    """
    return os.path.join(WORKSPACES_DIR, repo_name, mr_id, correlation_id)


@mcp.tool()
def setup_workspace(repo_name: str, mr_id: str, correlation_id: str) -> str:
    """Create or reconnect to a workspace for a workflow run (idempotent).

    Args:
        repo_name: Repository name (folder key).
        mr_id: MR id (folder key).
        correlation_id: Unique identifier for this workflow run — isolates
                        concurrent/repeated reviews on the same MR.
    """
    for val, name in [(repo_name, "repo_name"), (mr_id, "mr_id"), (correlation_id, "correlation_id")]:
        err = _validate_name(val, name)
        if err:
            return json.dumps({"error": err})
    workspace_path = _workspace_root(repo_name, mr_id, correlation_id)
    # The dedicated access point is mounted at WORKSPACES_DIR, while S3_MOUNT is
    # only its parent directory. Check the actual mount point so deployments with
    # split access points are reported accurately.
    storage_mode = "s3files" if os.path.ismount(WORKSPACES_DIR) else "local"
    reconnected = os.path.exists(workspace_path)
    for sub in ["reviews", "plans"]:
        os.makedirs(os.path.join(workspace_path, sub), exist_ok=True)
    return json.dumps({"workspace_path": workspace_path, "storage_mode": storage_mode,
                       "reconnected": reconnected, "correlation_id": correlation_id}, indent=2)


@mcp.tool()
def write_file(repo_name: str, mr_id: str, correlation_id: str, file_path: str,
               content: str, append: bool = False) -> str:
    """Write (or append to) a file inside this run's workspace.

    Args:
        repo_name: Repository name (folder key).
        mr_id: MR id (folder key).
        correlation_id: Workflow run identifier.
        file_path: Path RELATIVE to the workspace, e.g. "reviews/analysis.md".
                   An absolute path already inside the workspace is also accepted.
        content: File content.
        append: Append instead of overwrite.
    """
    for val, name in [(repo_name, "repo_name"), (mr_id, "mr_id"), (correlation_id, "correlation_id")]:
        err = _validate_name(val, name)
        if err:
            return json.dumps({"error": err})
    ws_root = _workspace_root(repo_name, mr_id, correlation_id)
    full, root = _resolve_path(file_path, ws_root)
    if not (full == root or full.startswith(root + os.sep)):
        return json.dumps({"error": "Access denied: path escapes the workspace"})
    Path(full).parent.mkdir(parents=True, exist_ok=True)
    with open(full, "a" if append else "w", encoding="utf-8") as fh:
        fh.write(content)
    return json.dumps({"status": "appended" if append else "written",
                       "path": full, "bytes": len(content)})


@mcp.tool()
def read_file(repo_name: str, mr_id: str, correlation_id: str, file_path: str) -> str:
    """Read a file from this run's workspace.

    Args:
        repo_name: Repository name (folder key).
        mr_id: MR id (folder key).
        correlation_id: Workflow run identifier.
        file_path: Path RELATIVE to the workspace, e.g. "reviews/analysis.md".
    """
    for val, name in [(repo_name, "repo_name"), (mr_id, "mr_id"), (correlation_id, "correlation_id")]:
        err = _validate_name(val, name)
        if err:
            return json.dumps({"error": err})
    ws_root = _workspace_root(repo_name, mr_id, correlation_id)
    full, root = _resolve_path(file_path, ws_root)
    if not (full == root or full.startswith(root + os.sep)):
        return json.dumps({"error": "Access denied: path escapes the workspace"})
    if not os.path.exists(full):
        return json.dumps({"error": f"File not found: {file_path}"})
    return Path(full).read_text(encoding="utf-8")


@mcp.tool()
def list_dir(repo_name: str, mr_id: str, correlation_id: str, dir_path: str = ".") -> str:
    """List a directory in this run's workspace.

    Args:
        repo_name: Repository name (folder key).
        mr_id: MR id (folder key).
        correlation_id: Workflow run identifier.
        dir_path: Path RELATIVE to the workspace ("." for the workspace root).
    """
    for val, name in [(repo_name, "repo_name"), (mr_id, "mr_id"), (correlation_id, "correlation_id")]:
        err = _validate_name(val, name)
        if err:
            return json.dumps({"error": err})
    ws_root = _workspace_root(repo_name, mr_id, correlation_id)
    full, root = _resolve_path(dir_path, ws_root)
    if not (full == root or full.startswith(root + os.sep)):
        return json.dumps({"error": "Access denied: path escapes the workspace"})
    if not os.path.isdir(full):
        return json.dumps({"error": f"Not a directory: {dir_path}"})
    return json.dumps(sorted(os.listdir(full)))


@mcp.tool()
def cleanup_workspace(repo_name: str, mr_id: str, correlation_id: str) -> str:
    """Remove a single workflow run's workspace after completion.

    Args:
        repo_name: Repository name (folder key).
        mr_id: MR id (folder key).
        correlation_id: Workflow run identifier to clean up.
    """
    for val, name in [(repo_name, "repo_name"), (mr_id, "mr_id"), (correlation_id, "correlation_id")]:
        err = _validate_name(val, name)
        if err:
            return json.dumps({"error": err})
    workspace_path = _workspace_root(repo_name, mr_id, correlation_id)
    if not _is_safe_path(workspace_path, WORKSPACES_DIR):
        return json.dumps({"error": "Access denied: path traversal detected"})
    shutil.rmtree(workspace_path, ignore_errors=True)
    return json.dumps({"status": "cleaned", "path": workspace_path})
