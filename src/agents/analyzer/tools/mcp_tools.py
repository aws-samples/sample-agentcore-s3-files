"""MCP tool wrappers — call the Workspace + GitLab MCP servers via the AgentCore Gateway.

Agents reach shared storage ONLY through these MCP-backed tools (Lesson 7), and
the calls now route through the AgentCore Gateway (GATEWAY_URL) rather than
invoking the MCP runtimes directly — the gateway aggregates both MCP servers into
one governed, SigV4-authenticated tool surface. The low-level MCP/session/SigV4
plumbing lives in shared.gateway_tools; these are thin @tool wrappers over it.
"""
from strands import tool

from shared.gateway_tools import call_gateway_tool


# ── Workspace MCP tools (via gateway) ──
@tool
def ws_setup(repo_name: str, mr_id: str, correlation_id: str) -> str:
    """Create/attach the shared workspace for this workflow run.

    Args:
        repo_name: Repository name (folder key).
        mr_id: MR id (folder key).
        correlation_id: Unique identifier for this workflow run.
    """
    return call_gateway_tool("setup_workspace",
                             {"repo_name": repo_name, "mr_id": mr_id,
                              "correlation_id": correlation_id})


@tool
def ws_read_file(repo_name: str, mr_id: str, correlation_id: str, file_path: str) -> str:
    """Read a file from this run's shared workspace on S3.

    Args:
        repo_name: Repository name (folder key).
        mr_id: MR id (folder key).
        correlation_id: Workflow run identifier.
        file_path: Path RELATIVE to the workspace, e.g. "reviews/analysis.md".
    """
    return call_gateway_tool("read_file",
                             {"repo_name": repo_name, "mr_id": mr_id,
                              "correlation_id": correlation_id, "file_path": file_path})


@tool
def ws_write_file(repo_name: str, mr_id: str, correlation_id: str,
                  file_path: str, content: str) -> str:
    """Write a file into this run's shared workspace on S3.

    Args:
        repo_name: Repository name (folder key).
        mr_id: MR id (folder key).
        correlation_id: Workflow run identifier.
        file_path: Path RELATIVE to the workspace, e.g. "reviews/analysis.md" — the
                   server places it under workspaces/{repo_name}/{mr_id}/{correlation_id}/.
        content: File content.
    """
    return call_gateway_tool("write_file",
                             {"repo_name": repo_name, "mr_id": mr_id,
                              "correlation_id": correlation_id,
                              "file_path": file_path, "content": content})


# ── GitLab MCP tools (via gateway) ──
@tool
def gl_fetch_mr(project_id: str, mr_iid: str) -> str:
    """Fetch GitLab merge-request metadata."""
    return call_gateway_tool("gl_fetch_mr", {"project_id": project_id, "mr_iid": mr_iid})


@tool
def gl_fetch_mr_diff(project_id: str, mr_iid: str) -> str:
    """Fetch the MR's changed files + diffs (the material to review)."""
    return call_gateway_tool("gl_fetch_mr_diff", {"project_id": project_id, "mr_iid": mr_iid})


@tool
def gl_clone_repo(repo_url: str, repo_name: str, branch: str, mr_id: str) -> str:
    """Read-only shallow clone of the MR source onto shared S3 Files (for full context)."""
    return call_gateway_tool("clone_or_update_repo",
                             {"repo_url": repo_url, "repo_name": repo_name, "branch": branch, "mr_id": mr_id})


@tool
def gl_read_repo_file(repo_name: str, mr_id: str, file_path: str,
                      from_line: int = 0, to_line: int = 0) -> str:
    """Read any file from the cloned repo (full context beyond the diff)."""
    return call_gateway_tool("read_repo_file",
                             {"repo_name": repo_name, "mr_id": mr_id, "file_path": file_path,
                              "from_line": str(int(from_line or 0)), "to_line": str(int(to_line or 0))})


@tool
def gl_list_repo_dir(repo_name: str, mr_id: str, dir_path: str = ".") -> str:
    """List a directory in the cloned repo."""
    return call_gateway_tool("list_repo_dir",
                             {"repo_name": repo_name, "mr_id": mr_id, "dir_path": dir_path})
