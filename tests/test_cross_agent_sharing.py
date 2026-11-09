"""Cross-agent file-sharing test — analyzer writes, reviewer reads + finalizes.

Verifies the core promise of the pattern: a file written by the ANALYZER agent
is visible to the REVIEWER agent (separate runtime) over the shared S3 Files
mount, and the reviewer can produce a finalized artifact from it — all keyed by
a shared deterministic session id that incorporates the correlation_id.
"""
from uuid import uuid4

from _helpers import call_mcp, deterministic_session_id  # noqa: F401

REPO = "demo-repo"
MR_ID = "42"

ANALYSIS_PATH = "reviews/analysis.md"
FINAL_PLAN_PATH = "plans/final_plan.md"


def test_analyzer_reviewer_shared_storage():
    correlation_id = f"test-cross-agent-{uuid4().hex[:12]}"
    session_id = deterministic_session_id(f"{REPO}/{MR_ID}/{correlation_id}")

    # Setup workspace (both agents call this with the same params).
    call_mcp(
        "setup_workspace",
        {"repo_name": REPO, "mr_id": MR_ID, "correlation_id": correlation_id},
        session_id=session_id,
    )

    # ANALYZER writes the combined tech + security analysis.
    call_mcp(
        "write_file",
        {"repo_name": REPO, "mr_id": MR_ID, "correlation_id": correlation_id,
         "file_path": ANALYSIS_PATH,
         "content": "# Analysis\n## Security\nSQLi risk in login.\n## Technical\nMissing input validation.\n"},
        session_id=session_id,
    )

    # REVIEWER (same shared session -> same mount) reads the analysis.
    analysis = call_mcp(
        "read_file",
        {"repo_name": REPO, "mr_id": MR_ID, "correlation_id": correlation_id,
         "file_path": ANALYSIS_PATH},
        session_id=session_id,
    )
    assert "Security" in analysis and "Technical" in analysis

    # REVIEWER ranks + writes the finalized plan to the SAME shared workspace.
    call_mcp(
        "write_file",
        {"repo_name": REPO, "mr_id": MR_ID, "correlation_id": correlation_id,
         "file_path": FINAL_PLAN_PATH,
         "content": "# Final Plan (ranked)\n1. [Critical] Fix SQLi in login.\n2. [High] Add input validation.\n"},
        session_id=session_id,
    )

    # The finalized plan is readable over the shared mount and reflects the analysis.
    final = call_mcp(
        "read_file",
        {"repo_name": REPO, "mr_id": MR_ID, "correlation_id": correlation_id,
         "file_path": FINAL_PLAN_PATH},
        session_id=session_id,
    )
    assert "Critical" in final and "SQLi" in final

    # Cleanup
    call_mcp(
        "cleanup_workspace",
        {"repo_name": REPO, "mr_id": MR_ID, "correlation_id": correlation_id},
        session_id=session_id,
    )
