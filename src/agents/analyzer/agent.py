"""Analyzer agent (Agent 1) — combined technical + security review.

Analyzes the change, writes a single combined review to shared storage, then
hands off to the Reviewer. Deliberately has NO gl_comment tool — it must not
write GitLab comments (only the Reviewer does).
"""
import os
from pathlib import Path

from strands import Agent
from strands.tools.executors import ConcurrentToolExecutor

from shared.bedrock_model import load_model, system_cache_point
from tools import (
    ws_setup, ws_write_file, ws_read_file,
    gl_fetch_mr, gl_fetch_mr_diff, gl_clone_repo, gl_read_repo_file, gl_list_repo_dir,
    handoff_to_reviewer,
)


def _system_prompt() -> list:
    text = (Path(__file__).parent / "prompts" / "system_prompt.md").read_text(encoding="utf-8")
    # Cache the (large, static) system prompt; TTL matches the tool/history cache.
    return [{"text": text}, system_cache_point()]


def create_agent() -> Agent:
    os.environ["BYPASS_TOOL_CONSENT"] = "true"
    return Agent(
        agent_id="analyzer",
        name="Analyzer Agent (Tech + Security)",
        model=load_model(
            model_id=os.environ["BEDROCK_MODEL_ID"],
            temperature=0.2,
        ),
        system_prompt=_system_prompt(),
        tool_executor=ConcurrentToolExecutor(),
        tools=[
            ws_setup, ws_write_file, ws_read_file,
            gl_fetch_mr, gl_fetch_mr_diff, gl_clone_repo, gl_read_repo_file, gl_list_repo_dir,
            handoff_to_reviewer,
        ],
    )
