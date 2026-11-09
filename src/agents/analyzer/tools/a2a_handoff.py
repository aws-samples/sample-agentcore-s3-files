"""A2A handoff — the Analyzer hands off to the Reviewer (finalizer) directly.

True agent-to-agent: the analyzer invokes the reviewer's runtime itself (no
external orchestrator). The reviewer attaches to the SAME shared workspace
(same repo/mr/correlation_id -> same deterministic session id) and reads the
analysis file.
"""
import os

from strands import tool

from shared.a2a_client import invoke_agent_a2a, build_runtime_session_id


@tool
def handoff_to_reviewer(repo_name: str, mr_id: str, correlation_id: str,
                        analysis_path: str, project_id: str = "",
                        mr_iid: str = "") -> str:
    """Hand off to the Reviewer agent via A2A after writing the analysis.

    Args:
        repo_name: Repository name (e.g. "demo-repo").
        mr_id: Workspace MR id (folder key, e.g. "42").
        correlation_id: Workflow run identifier (passed to the reviewer so it
                        attaches to the same workspace).
        analysis_path: Path to the analysis you just wrote (e.g. reviews/analysis.md).
        project_id: GitLab numeric project id (the reviewer posts the comment).
        mr_iid: GitLab MR iid.
    """
    runtime_id = os.environ.get("REVIEWER_RUNTIME_ID", "")
    if not runtime_id:
        return "Error: REVIEWER_RUNTIME_ID not set — cannot hand off to the reviewer."

    message = (
        f"Finalize the code review.\n"
        f"Call ws_setup(repo_name=\"{repo_name}\", mr_id=\"{mr_id}\", "
        f"correlation_id=\"{correlation_id}\") to attach to the same shared workspace, "
        f"then read the analysis with ws_read_file(repo_name=\"{repo_name}\", "
        f"mr_id=\"{mr_id}\", correlation_id=\"{correlation_id}\", "
        f"file_path=\"{analysis_path}\") (the combined technical + security analysis "
        f"written by the Analyzer). Rank the findings by severity, write "
        f"plans/final_plan.md with the prioritized remediation plan, and post a summary "
        f"comment to GitLab (project_id={project_id}, mr_iid={mr_iid}).\n"
        f"\n"
        f"Context: repo_name={repo_name}, mr_id={mr_id}, correlation_id={correlation_id}"
    )
    return invoke_agent_a2a(
        runtime_id=runtime_id,
        message=message,
        session_id=build_runtime_session_id(
            agent_id="review",
            scenario_id=mr_id,
            differentiator=f"{repo_name}-{correlation_id}",
        ),
    )
