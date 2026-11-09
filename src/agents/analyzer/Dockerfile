# Analyzer agent (Agent 1: tech + security) runtime image.
# Deliberately DIFFERENT from the MCP server images:
#   * NO NFS / S3 Files mount tooling — agents have no S3 Files mount (design decision #4).
#   * NO local file tools in the agent code — the only path to shared storage is the
#     MCP-backed tools (Lesson 7).
# Serve over A2A so the orchestrator can invoke it.
#
# BUILD CONTEXT = REPO ROOT (so the shared package under src/shared is available):
#   docker build --platform linux/arm64 -f src/agents/analyzer/Dockerfile -t analyzer-agent .
FROM public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:28a08196a0bbf69de31f481c74aebbfdc2c70a39b4a2002a4b30662ca5548062
WORKDIR /app

# dnf package versions are intentionally unpinned: Amazon Linux 2023 uses rolling
# repos where exact builds are garbage-collected, so pins make builds fail over
# time. The base image itself is pinned by immutable digest. The KICS
# "Missing Version Specification In dnf install" rule is formally accepted for this
# repo in .gitlab/sast-ruleset.toml.
RUN dnf install -y --setopt=install_weak_deps=False --allowerasing \
    tar gzip curl ca-certificates which findutils \
    python3.13 python3.13-pip python3.13-devel \
    && dnf clean all

RUN alternatives --install /usr/bin/python3 python3 /usr/bin/python3.13 1 && \
    alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3.13 1

RUN pip3 install --no-cache-dir "uv==0.11.8"

# Install the frozen, hash-verified dependency graph.
COPY src/agents/analyzer/pyproject.toml src/agents/analyzer/uv.lock /app/
RUN uv export --frozen --no-dev --no-emit-project --format requirements-txt \
      --output-file /app/requirements.txt && \
    uv pip install --system --no-cache --require-hashes -r /app/requirements.txt

# ─── App code (shared modules now come from the installed `shared` package) ──
COPY src/shared/ /app/shared/
COPY src/agents/analyzer/agent.py src/agents/analyzer/entrypoint.py /app/
COPY src/agents/analyzer/tools/ /app/tools/
COPY src/agents/analyzer/prompts/ /app/prompts/

ENV PYTHONUNBUFFERED=1
# If OTel span export starts failing (400s) and silences logs, uncomment:
# ENV OTEL_TRACES_EXPORTER=none

# Run as non-root (CIS Docker Benchmark, KICS critical finding).
RUN echo "appuser:x:1000:1000::/app:/sbin/nologin" >> /etc/passwd && \
    chown -R 1000:1000 /app
USER 1000

EXPOSE 9000
# Liveness probe: confirm the A2A server is accepting TCP connections on 9000.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf -o /dev/null http://127.0.0.1:9000/ || exit 1
CMD ["opentelemetry-instrument", "python3", "entrypoint.py"]
