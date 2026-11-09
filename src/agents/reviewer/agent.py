"""Reviewer agent (Agent 2) — finalizer.

Reads the Analyzer's combined review from shared storage, ranks the findings,
writes a prioritized 'plans/final_plan.md' to shared storage, and posts the
summary comment to GitLab. This is the ONLY agent that writes GitLab comments.
"""
import os
from pathlib import Path

from strands import Agent
from strands.tools.executors import ConcurrentToolExecutor

from shared.bedrock_model import load_model, system_cache_point
from tools import (
    ws_setup, ws_read_file, ws_write_file, ws_append_file,
    gl_fetch_mr_diff, gl_read_repo_file, gl_comment, gl_inline_comment,
)


def _system_prompt() -> list:
    text = (Path(__file__).parent / "prompts" / "system_prompt.md").read_text(encoding="utf-8")
    return [{"text": text}, system_cache_point()]


def create_agent() -> Agent:
    os.environ["BYPASS_TOOL_CONSENT"] = "true"
    return Agent(
        agent_id="reviewer",
        name="Reviewer Agent (Finalizer)",
        model=load_model(
            model_id=os.environ["BEDROCK_MODEL_ID"],
            temperature=0.2,
        ),
        system_prompt=_system_prompt(),
        tool_executor=ConcurrentToolExecutor(),
        tools=[
            ws_setup, ws_read_file, ws_write_file, ws_append_file,
            gl_fetch_mr_diff, gl_read_repo_file, gl_comment, gl_inline_comment,
        ],
    )
