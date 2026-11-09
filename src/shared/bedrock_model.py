"""Bedrock model loader — retry, rate-limit handling, and prompt caching.

Simplified single-account version (no cross-account assume-role): the runtime's
own execution role is used directly for Bedrock. This module centralizes the
resilience features:

  * Retries + timeouts via a botocore standard-retry config (handles Bedrock
    throttling / rate limits with exponential backoff).
  * Prompt caching for tool definitions AND conversation history, so re-sent
    context bills as a cheap cache-read instead of full input price.
  * A single CACHE_TTL shared by the system prompt (system_cache_point()), the
    tool cache, and the history cache — Bedrock rejects requests where a
    longer-TTL cache block follows a shorter-TTL one, so they MUST agree.

All cache features degrade gracefully on older Strands versions.
"""

import os

from botocore.config import Config as BotocoreConfig
from strands.models.bedrock import BedrockModel

# Single source of truth for the prompt-cache TTL across system prompt + tools + history.
CACHE_TTL = "1h"

# Per-TTL tool cache config — available on newer Strands only.
try:
    from strands.models.model import CacheToolsConfig
    _CACHE_TTL_SUPPORTED = True
except ImportError:
    CacheToolsConfig = None  # type: ignore[assignment]
    _CACHE_TTL_SUPPORTED = False

# Conversation-history caching — available on newer Strands only.
try:
    from strands.models.model import CacheConfig
    _CACHE_CONFIG_SUPPORTED = True
except ImportError:
    CacheConfig = None  # type: ignore[assignment]
    _CACHE_CONFIG_SUPPORTED = False


def system_cache_point() -> dict:
    """Cache-point block for an agent system prompt.

    TTL matches the tool/history cache (CACHE_TTL when supported, else Bedrock's
    default 5m). Agents MUST use this instead of hardcoding a ttl so all cache
    blocks agree.
    """
    if _CACHE_TTL_SUPPORTED:
        return {"cachePoint": {"type": "default", "ttl": CACHE_TTL}}
    return {"cachePoint": {"type": "default"}}


def _tool_cache_config():
    if _CACHE_TTL_SUPPORTED:
        return CacheToolsConfig(type="default", ttl=CACHE_TTL)
    return "default"


def load_model(
    model_id: str,
    max_attempts: int = 5,
    connect_timeout: float = 60.0,
    read_timeout: float = 300.0,
    temperature: float = 0.2,
    cache_tools: bool = True,
    cache_history: bool = True,
) -> BedrockModel:
    """Load a Bedrock model with retries, timeouts, and prompt caching.

    Args:
        model_id: Bedrock model id / inference-profile id (required).
        max_attempts: Max retry attempts for throttling/transient errors (botocore
            "standard" mode = exponential backoff with jitter).
        connect_timeout / read_timeout: Client timeouts in seconds.
        temperature: Sampling temperature.
        cache_tools: Cache tool definitions (Bedrock prompt cache).
        cache_history: Cache the re-sent conversation transcript each turn.
    """
    if not model_id:
        raise ValueError("model_id is required (set BEDROCK_MODEL_ID on the runtime).")

    boto_config = BotocoreConfig(
        retries={"mode": "standard", "max_attempts": max_attempts},
        connect_timeout=connect_timeout,
        read_timeout=read_timeout,
        user_agent_extra="agentcore-s3files",
    )

    model = BedrockModel(model_id=model_id, boto_client_config=boto_config)

    config_kwargs = {"temperature": temperature}
    if cache_tools:
        config_kwargs["cache_tools"] = _tool_cache_config()
    if cache_history and _CACHE_CONFIG_SUPPORTED:
        # strategy="anthropic" (not "auto"): "auto" gates on the model_id containing
        # "claude"/"anthropic"; an inference-profile id may contain neither, so "auto"
        # would silently no-op. We know Claude is behind the profile.
        config_kwargs["cache_config"] = CacheConfig(
            strategy="anthropic",
            ttl=CACHE_TTL if _CACHE_TTL_SUPPORTED else None,
        )
    model.update_config(**config_kwargs)
    return model
