"""Gitlab MCP container entrypoint — streamable HTTP.

configure_logging() runs first so structured logs reach CloudWatch (otel-rt-logs
+ raw stdout). Startup is wrapped so a boot failure prints a full traceback
instead of dying silently under opentelemetry-instrument.
"""
import sys
import traceback

from shared.logging_config import configure_logging, get_logger

configure_logging()
_log = get_logger("entrypoint")


def _main() -> None:
    from server import mcp

    _log.info("entrypoint.starting_mcp_server", transport="streamable-http")
    mcp.run(transport="streamable-http")


if __name__ == "__main__":
    try:
        _main()
    except Exception:
        try:
            _log.exception("entrypoint.fatal")
        except Exception:
            pass
        print("[entrypoint] FATAL: MCP server failed to start", flush=True)
        traceback.print_exc()
        sys.stdout.flush()
        sys.stderr.flush()
        raise
