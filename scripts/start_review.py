#!/usr/bin/env python3
# /// script
# requires-python = ">=3.13"
# dependencies = [
#     "boto3==1.43.122",
#     "httpx==0.28.1",
# ]
# ///
"""Kick off the review workflow by invoking the ANALYZER agent (Agent 1).

This script only starts the first agent. The analyzer writes the combined technical +
security analysis and then hands off to the reviewer (finalizer) itself via A2A — no
external orchestrator sequences them.

A unique correlation_id is generated per invocation to isolate concurrent/repeated
reviews on the same MR and provide end-to-end traceability.

Env:
  AWS_ACCOUNT_ID        (account comes from your AWS credentials/profile)
  AWS_REGION            optional; else read from `terraform output -raw aws_region`
  ANALYZER_RUNTIME_ID   optional; else read from `terraform output -raw analyzer_runtime_id`

Usage:
  python scripts/start_review.py --repo-name demo-repo --mr-id 42 \
      --project-id 123 --mr-iid 7 --repo-url https://gitlab.com/acme/demo-repo

  # Supply your own correlation_id (e.g. from a CI pipeline):
  python scripts/start_review.py --repo-name demo-repo --mr-id 42 \
      --correlation-id "ci-pipeline-12345" ...
"""
import argparse
import os
import sys
from datetime import datetime, timezone
from uuid import uuid4

# Region — single source of truth is the Terraform var-file (exposed as the
# aws_region output). Resolve it (env wins) and set AWS_DEFAULT_REGION BEFORE
# importing a2a_client, which reads that env var at import time.
def _resolve_region() -> str:
    env = os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION")
    if env:
        return env
    tf_dir = os.path.join(os.path.dirname(__file__), "..", "terraform")
    try:
        import subprocess
        out = subprocess.run(["terraform", f"-chdir={tf_dir}", "output", "-raw", "aws_region"],
                             capture_output=True, text=True, timeout=30)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return ""


_region = _resolve_region()
if not _region:
    sys.exit(
        "Could not resolve an AWS Region. Set AWS_REGION/AWS_DEFAULT_REGION or run "
        "after Terraform has produced the aws_region output."
    )
os.environ.setdefault("AWS_DEFAULT_REGION", _region)


def _resolve_analyzer_runtime_id() -> str:
    """Resolve the analyzer runtime id: env var wins, else `terraform output`."""
    env = os.getenv("ANALYZER_RUNTIME_ID")
    if env:
        return env
    tf_dir = os.path.join(os.path.dirname(__file__), "..", "terraform")
    try:
        import subprocess
        out = subprocess.run(["terraform", f"-chdir={tf_dir}", "output", "-raw", "analyzer_runtime_id"],
                             capture_output=True, text=True, timeout=30)
        if out.returncode == 0 and out.stdout.strip() and out.stdout.strip() != "null":
            return out.stdout.strip()
    except Exception:
        pass
    return ""


def _generate_correlation_id() -> str:
    """Generate a unique, human-readable correlation_id.

    Format: YYYYMMDD-HHMMSS-<short_uuid>  (e.g. 20260804-134500-a1b2c3d4)
    This is both sortable (by date) and unique (UUID suffix).
    """
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    short_uuid = uuid4().hex[:8]
    return f"{ts}-{short_uuid}"


# Reuse the shared A2A client.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
from shared.a2a_client import invoke_agent_a2a, build_runtime_session_id  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser(description="Start the review by invoking the analyzer agent")
    ap.add_argument("--repo-name", required=True)
    ap.add_argument("--mr-id", required=True, help="Workspace MR id (folder key)")
    ap.add_argument("--repo-url", default="")
    ap.add_argument("--project-id", default="")
    ap.add_argument("--mr-iid", default="")
    ap.add_argument("--correlation-id", default="",
                    help="Optional: supply your own correlation_id (e.g. from CI). "
                         "If omitted, one is generated automatically.")
    args = ap.parse_args()

    runtime_id = _resolve_analyzer_runtime_id()
    if not runtime_id:
        sys.exit(
            "Could not resolve the analyzer runtime id. Set ANALYZER_RUNTIME_ID, or run from "
            "the repo after a successful Phase 2 apply so `terraform output -raw analyzer_runtime_id` "
            "returns it (empty means create_runtimes is still false or the apply hasn't finished)."
        )

    correlation_id = args.correlation_id or _generate_correlation_id()

    message = (
        f"Set up the workspace for MR {args.mr_id} of repo {args.repo_name} "
        f"(repo_url={args.repo_url}, project_id={args.project_id}, mr_iid={args.mr_iid}). "
        f"correlation_id={correlation_id}. "
        f"Write a combined technical + security review to reviews/analysis.md, then hand off to the reviewer."
    )
    print(f"[start_review] correlation_id={correlation_id}")
    print(f"[start_review] invoking analyzer {runtime_id} ...")
    result = invoke_agent_a2a(
        runtime_id,
        message,
        session_id=build_runtime_session_id(
            agent_id="review",
            scenario_id=args.mr_id,
            differentiator=f"{args.repo_name}-{correlation_id}",
        ),
    )
    print(result)


if __name__ == "__main__":
    main()
