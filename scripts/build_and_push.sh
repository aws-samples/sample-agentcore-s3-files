#!/usr/bin/env bash
# =============================================================================
# build_and_push.sh — build all 4 images and push them to their ECR repos.
#
# Reads the ECR push targets straight from Terraform output
# (ecr_repository_urls, a map of image-name -> repo URL created in Phase 1),
# logs into ECR once, then builds each image from its Dockerfile and pushes it.
#
# Image name -> build context mapping (matches the derived ECR repo names):
#   analyzer-agent -> src/agents/analyzer
#   reviewer-agent -> src/agents/reviewer
#   workspace-mcp  -> src/mcp-servers/workspace
#   gitlab-mcp     -> src/mcp-servers/gitlab
#
# NOTE: written for portability — no bash 4 associative arrays, so it runs on
# the macOS system bash 3.2 as well as Linux CI.
#
# Config (all overridable via env — nothing hardcoded):
#   AWS_REGION       AWS region  (default: terraform output aws_region)
#   IMAGE_TAG        tag to push             (default: <UTC-timestamp>-<git-sha>)
#                    ECR repos are IMMUTABLE — a tag cannot be overwritten, so the
#                    default is unique per build. Override with a fixed tag only if
#                    you know it has not been pushed before.
#   PLATFORM         docker build platform   (default: linux/arm64)
#   NO_CACHE         set to 1 to force --no-cache (bust the layer cache; needed when a
#                    floating dep pin like mcp== changes but the RUN line does not)
#   TERRAFORM_DIR    path to the tf root     (default: ../terraform relative to this script)
#
# Usage:
#   ./scripts/build_and_push.sh                       # all four
#   ./scripts/build_and_push.sh analyzer-agent gitlab-mcp   # a subset
# =============================================================================
set -euo pipefail

# ECR repositories are IMMUTABLE (terraform ecr module default): a tag cannot be
# re-pushed. Default to a unique tag per build (UTC timestamp + short git sha) so
# repeated runs never collide. Override with IMAGE_TAG=<tag> for a one-off.
_default_tag="$(date -u +%Y%m%d%H%M%S)-$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
IMAGE_TAG="${IMAGE_TAG:-${_default_tag}}"
PLATFORM="${PLATFORM:-linux/arm64}"
NO_CACHE="${NO_CACHE:-}"   # set NO_CACHE=1 to force a clean rebuild (bypass Docker layer cache)
# Container CLI — defaults to docker; set DOCKER=finch (or nerdctl) for a Docker-compatible
# alternative. Finch/nerdctl accept the same login/build/push flags used below.
DOCKER="${DOCKER:-docker}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TERRAFORM_DIR="${TERRAFORM_DIR:-${REPO_ROOT}/terraform}"

# Region — single source of truth is the Terraform var-file (exposed as the
# aws_region output). Explicit AWS_REGION env wins; otherwise read it from
# terraform output. Fail closed if neither is available.
AWS_REGION="${AWS_REGION:-$(terraform -chdir="${TERRAFORM_DIR}" output -raw aws_region 2>/dev/null || true)}"
if [ -z "${AWS_REGION}" ] || [ "${AWS_REGION}" = "null" ]; then
  echo "ERROR: AWS_REGION is unset and Terraform has no aws_region output." >&2
  exit 1
fi

# image-name -> build context (bash 3.2 compatible: a case function, not an assoc array)
context_for() {
  case "$1" in
    analyzer-agent) echo "src/agents/analyzer" ;;
    reviewer-agent) echo "src/agents/reviewer" ;;
    workspace-mcp)  echo "src/mcp-servers/workspace" ;;
    gitlab-mcp)     echo "src/mcp-servers/gitlab" ;;
    *)              echo "" ;;
  esac
}

ALL_IMAGES="analyzer-agent reviewer-agent workspace-mcp gitlab-mcp"

# Which images to build (args override; default = all)
if [ "$#" -gt 0 ]; then
  IMAGES="$*"
else
  IMAGES="${ALL_IMAGES}"
fi

echo "==> Reading ECR repository URLs from Terraform (${TERRAFORM_DIR})"
ECR_JSON="$(terraform -chdir="${TERRAFORM_DIR}" output -json ecr_repository_urls)"
if [ -z "${ECR_JSON}" ] || [ "${ECR_JSON}" = "null" ] || [ "${ECR_JSON}" = "{}" ]; then
  echo "ERROR: ecr_repository_urls is empty. Apply Phase 1 first (terraform apply)." >&2
  exit 1
fi

# Registry host for docker login (derive from any repo URL: <acct>.dkr.ecr.<region>.amazonaws.com)
REGISTRY="$(echo "${ECR_JSON}" | python3 -c "import json,sys; v=json.load(sys.stdin); print(next(iter(v.values())).split('/')[0])")"

echo "==> Logging in to ECR registry: ${REGISTRY}"
aws ecr get-login-password --region "${AWS_REGION}" \
  | "${DOCKER}" login --username AWS --password-stdin "${REGISTRY}"

for image in ${IMAGES}; do
  context="$(context_for "${image}")"
  if [ -z "${context}" ]; then
    echo "WARN: unknown image '${image}' — skipping" >&2
    continue
  fi

  repo_url="$(echo "${ECR_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('${image}',''))")"
  if [ -z "${repo_url}" ]; then
    echo "ERROR: no ECR repo URL for '${image}' in terraform output — is it in agentcore.agents/mcp_servers?" >&2
    exit 1
  fi

  full_tag="${repo_url}:${IMAGE_TAG}"
  dockerfile="${REPO_ROOT}/${context}/Dockerfile"
  echo ""
  echo "==> Building ${image}  (-f ${context}/Dockerfile, context=repo root)  ->  ${full_tag}"
  # Build context is the REPO ROOT so each Dockerfile can COPY the shared package
  # (src/shared) plus its own component dir. The Dockerfile path selects the image.
  cache_flag=""
  [ -n "${NO_CACHE}" ] && cache_flag="--no-cache"
  "${DOCKER}" build ${cache_flag} --platform "${PLATFORM}" -f "${dockerfile}" -t "${full_tag}" "${REPO_ROOT}"

  echo "==> Pushing ${full_tag}"
  "${DOCKER}" push "${full_tag}"
done

echo ""
echo "==> Done. Runtime images default to these ECR repos automatically (config.yaml"
echo "    container_uri is an optional override). Flip agentcore.create_runtimes: true and"
echo "    run Phase 2."
