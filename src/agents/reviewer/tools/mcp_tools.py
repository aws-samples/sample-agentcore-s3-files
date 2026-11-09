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
        file_path: Path RELATIVE to the workspace, e.g. "plans/final_plan.md" — the
                   server places it under workspaces/{repo_name}/{mr_id}/{correlation_id}/.
        content: File content.
    """
    return call_gateway_tool("write_file",
                             {"repo_name": repo_name, "mr_id": mr_id,
                              "correlation_id": correlation_id,
                              "file_path": file_path, "content": content})


@tool
def ws_append_file(repo_name: str, mr_id: str, correlation_id: str,
                   file_path: str, content: str) -> str:
    """Append to an existing file in this run's shared workspace (update without overwrite).

    Args:
        repo_name: Repository name (folder key).
        mr_id: MR id (folder key).
        correlation_id: Workflow run identifier.
        file_path: Path RELATIVE to the workspace, e.g. "plans/final_plan.md".
        content: Content to append.
    """
    return call_gateway_tool("write_file",
                             {"repo_name": repo_name, "mr_id": mr_id,
                              "correlation_id": correlation_id,
                              "file_path": file_path, "content": content, "append": True})


# ── GitLab MCP tools (via gateway) ──
@tool
def gl_fetch_mr_diff(project_id: str, mr_iid: str) -> str:
    """Fetch the MR's changed files + diffs and diff_refs (to anchor inline comments)."""
    return call_gateway_tool("gl_fetch_mr_diff", {"project_id": project_id, "mr_iid": mr_iid})


@tool
def gl_read_repo_file(repo_name: str, mr_id: str, file_path: str,
                      from_line: int = 0, to_line: int = 0) -> str:
    """Read a file from the cloned repo (to confirm a finding against full source)."""
    return call_gateway_tool("read_repo_file",
                             {"repo_name": repo_name, "mr_id": mr_id, "file_path": file_path,
                              "from_line": str(int(from_line or 0)), "to_line": str(int(to_line or 0))})


@tool
def gl_comment(project_id: str, mr_iid: str, body: str) -> str:
    """Post a comment on a GitLab merge request."""
    return call_gateway_tool("gl_comment", {"project_id": project_id, "mr_iid": mr_iid, "body": body})


@tool
def gl_inline_comment(project_id: str, mr_iid: str, body: str, new_path: str, new_line: str,
                      base_sha: str = "", start_sha: str = "", head_sha: str = "",
                      old_path: str = "", old_line: str = "") -> str:
    """Post an INLINE comment on a specific file + line of the MR diff.

    new_path/new_line target a line on the MR's new side. diff_refs
    (base/start/head_sha) are auto-resolved by the server if omitted.
    """
    return call_gateway_tool("gl_inline_comment", {
        "project_id": project_id, "mr_iid": mr_iid, "body": body,
        "new_path": new_path, "new_line": new_line,
        "base_sha": base_sha, "start_sha": start_sha, "head_sha": head_sha,
        "old_path": old_path, "old_line": old_line,
    })
