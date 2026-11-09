# GitLab MCP Server image — read-only clone (on S3 Files) + GitLab API review/comment.
# Needs git and the dedicated repositories access point at /mnt/repositories.
# No branches/commits/push.
#
# BUILD CONTEXT = REPO ROOT:
#   docker build --platform linux/arm64 -f src/mcp-servers/gitlab/Dockerfile -t gitlab-mcp .
FROM public.ecr.aws/amazonlinux/amazonlinux:2023@sha256:28a08196a0bbf69de31f481c74aebbfdc2c70a39b4a2002a4b30662ca5548062
WORKDIR /app

# dnf package versions are intentionally unpinned: Amazon Linux 2023 uses rolling
# repos where exact builds are garbage-collected, so pins make builds fail over
# time. The base image itself is pinned by immutable digest. The KICS
# "Missing Version Specification In dnf install" rule is formally accepted for this
# repo in .gitlab/sast-ruleset.toml.
RUN dnf install -y --setopt=install_weak_deps=False --allowerasing \
    tar gzip curl ca-certificates which findutils git \
    python3.13 python3.13-pip python3.13-devel \
    && dnf clean all

RUN alternatives --install /usr/bin/python3 python3 /usr/bin/python3.13 1 && \
    alternatives --install /usr/bin/pip3 pip3 /usr/bin/pip3.13 1

RUN pip3 install --no-cache-dir "uv==0.11.8"

# Install the frozen, hash-verified dependency graph.
COPY src/mcp-servers/gitlab/pyproject.toml src/mcp-servers/gitlab/uv.lock /app/
RUN uv export --frozen --no-dev --no-emit-project --format requirements-txt \
      --output-file /app/requirements.txt && \
    uv pip install --system --no-cache --require-hashes -r /app/requirements.txt

COPY src/shared/ /app/shared/
COPY src/mcp-servers/gitlab/server.py src/mcp-servers/gitlab/entrypoint.py /app/
RUN mkdir -p /mnt/repositories

# Run as non-root (CIS Docker Benchmark, KICS critical finding).
# The S3 Files access point enforces uid/gid 1000 and creates its root as 0750.
RUN echo "appuser:x:1000:1000::/app:/sbin/nologin" >> /etc/passwd && \
    chown -R 1000:1000 /app /mnt/repositories && \
    chmod 750 /mnt/repositories
USER 1000

ENV S3_MOUNT_PATH=/mnt PYTHONUNBUFFERED=1
# If OTel span export starts failing (400s) and silences logs, uncomment:
# ENV OTEL_TRACES_EXPORTER=none
EXPOSE 8000
# Liveness probe: confirm the MCP server is accepting TCP connections on 8000.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf -o /dev/null http://127.0.0.1:8000/mcp || exit 1
CMD ["opentelemetry-instrument", "python3", "entrypoint.py"]
