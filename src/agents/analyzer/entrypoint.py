"""AgentCore Runtime entrypoint — serve the agent over the A2A protocol.

Startup is wrapped in a try/except that prints a FULL traceback to stdout and
flushes before exiting. Without this, a boot-time failure in create_agent()
(e.g. a missing BEDROCK_MODEL_ID env var, an import error, or a Bedrock model
load error) is swallowed by the opentelemetry-instrument wrapper and the runtime
returns an opaque 424 with EMPTY CloudWatch logs. Failing loudly makes the real
error visible in the runtime log stream.
"""
import sys
import traceback

from shared.logging_config import configure_logging, get_logger

configure_logging()
_log = get_logger("entrypoint")


def _main() -> None:
    from strands.multiagent.a2a.executor import StrandsA2AExecutor
    from bedrock_agentcore.runtime import serve_a2a

    from agent import create_agent

    _log.info("entrypoint.building_agent")
    agent = create_agent()
    _log.info("entrypoint.agent_built.starting_a2a_server")
    serve_a2a(StrandsA2AExecutor(agent))


if __name__ == "__main__":
    try:
        _main()
    except Exception:
        # Log via structlog AND print a raw traceback, so the failure shows up in
        # both otel-rt-logs and the raw stdout stream even if one path is broken.
        try:
            _log.exception("entrypoint.fatal")
        except Exception:
            pass
        print("[entrypoint] FATAL: agent failed to start", flush=True)
        traceback.print_exc()
        sys.stdout.flush()
        sys.stderr.flush()
        raise
