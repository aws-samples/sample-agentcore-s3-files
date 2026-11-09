"""Structured JSON logging via structlog, integrated with OpenTelemetry.

In AgentCore Runtime, `opentelemetry-instrument` attaches an OTel LoggingHandler to the root
logger BEFORE our code runs, shipping stdlib `logging` output to the
`otel-rt-logs` CloudWatch stream. We route structlog THROUGH stdlib logging and
ALSO add a stdout handler, so application logs reach BOTH:
  * otel-rt-logs  (OTel-exported structured records)
  * the raw stdout/runtime-logs stream (fallback / debugging)

Usage:
    from shared.logging_config import configure_logging, get_logger
    configure_logging()
    logger = get_logger(__name__)
    logger.info("hello", key="value")
"""

import logging
import os
import sys

import structlog

_CONFIGURED = False
_SERVICE_NAME = os.getenv("SERVICE_NAME", "")


def _log_level() -> int:
    lvl = logging.getLevelName(os.getenv("LOG_LEVEL", "INFO").upper())
    return lvl if isinstance(lvl, int) else logging.INFO


def _add_service_name(logger, method_name, event_dict):
    if _SERVICE_NAME:
        event_dict.setdefault("service", _SERVICE_NAME)
    return event_dict


def configure_logging() -> None:
    """Configure structlog to emit structured JSON via stdlib logging + stdout.

    Idempotent — safe to call more than once (double-config corrupts the handler
    list and can make stdout logs vanish).
    """
    global _CONFIGURED
    if _CONFIGURED:
        return
    _CONFIGURED = True

    level = _log_level()

    # Tame noisy third-party loggers so real signal is visible.
    for name, lvl in {
        "botocore": logging.WARNING,
        "botocore.credentials": logging.WARNING,
        "boto3": logging.WARNING,
        "urllib3": logging.WARNING,
        "httpx": logging.WARNING,
        "httpcore": logging.WARNING,
        "strands": logging.INFO,
    }.items():
        logging.getLogger(name).setLevel(lvl)

    shared_processors = [
        structlog.contextvars.merge_contextvars,
        _add_service_name,
        structlog.processors.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
    ]

    formatter = structlog.stdlib.ProcessorFormatter(
        processors=[
            structlog.stdlib.ProcessorFormatter.remove_processors_meta,
            structlog.processors.JSONRenderer(),
        ],
        foreign_pre_chain=shared_processors,
    )

    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(formatter)

    root = logging.getLogger()
    # Keep OTel's handler (added by opentelemetry-instrument) so logs still reach
    # otel-rt-logs; drop any other pre-existing handlers to avoid duplicate stdout.
    otel_handlers = [h for h in root.handlers if type(h).__module__.startswith("opentelemetry")]
    root.handlers = otel_handlers
    root.addHandler(handler)
    root.setLevel(level)

    structlog.configure(
        processors=[*shared_processors, structlog.stdlib.ProcessorFormatter.wrap_for_formatter],
        wrapper_class=structlog.stdlib.BoundLogger,
        context_class=dict,
        logger_factory=structlog.stdlib.LoggerFactory(),
        cache_logger_on_first_use=True,
    )


def get_logger(module_name: str = ""):
    """Return a structlog logger. Calls configure_logging() lazily if needed."""
    if not _CONFIGURED:
        configure_logging()
    return structlog.get_logger(module_name)
