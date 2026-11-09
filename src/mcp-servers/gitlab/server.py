"""GitLab MCP Server — read-only clone + review + comment (NO branches/commits/push/MRs).

Scope for this pattern:
  Repo (read-only, on the dedicated S3 Files mount at /mnt/repositories/):
    - clone_or_update_repo : shallow read-only clone of the MR source branch (once,
                             reused across the workflow). No branch/commit/push.
    - read_repo_file       : read any file from the clone (full context, not just the diff)
    - list_repo_dir        : list a directory in the clone
  GitLab API:
    - gl_fetch_mr          : MR metadata
    - gl_fetch_mr_diff     : changed files + diffs + diff_refs
    - gl_comment           : general MR comment
    - gl_inline_comment    : inline comment on a specific file + line

Why clone to S3 Files: a diff shows only changed hunks. Real review needs the FULL
source (open unchanged files, trace callers/imports). The clone lives on the shared S3
Files mount so the analyzer clones once and the reviewer reads the SAME clone — no
re-download. The clone is strictly READ-ONLY: this server never creates branches,
commits, pushes, or opens merge requests.

Mount: /mnt/repositories (dedicated access point mounted automatically by AgentCore).
Owns:  /mnt/repositories/{repo_name}/{mr_id}/
"""
import base64
import json
import logging
import os
import re
import subprocess
from urllib.parse import quote, urlparse

import httpx
from botocore.exceptions import BotoCoreError, ClientError
from mcp.server.fastmcp import FastMCP

# Bind to all interfaces: this server runs inside an AgentCore-managed container
# with no published host port — it is reachable only through the gateway on the
# private VPC network, so binding 0.0.0.0 is required and does not widen exposure.
mcp = FastMCP(host="0.0.0.0", stateless_http=True, json_response=True)  # nosec B104

S3_MOUNT = os.getenv("S3_MOUNT_PATH", "/mnt")
REPOS_DIR = os.path.join(S3_MOUNT, "repositories")
GITLAB_URL = os.getenv("GITLAB_URL", "https://gitlab.com").rstrip("/")

_SAFE_NAME = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$")
_SAFE_REF = re.compile(r"^(?!-)(?!.*\.\.)[A-Za-z0-9._/-]{1,200}$")
_SAFE_PROJECT = re.compile(r"^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+$")
_SAFE_MR_IID = re.compile(r"^[1-9][0-9]*$")
_SAFE_SHA = re.compile(r"^[0-9a-fA-F]{40}$")
_QUICK_ACTION = re.compile(r"(?m)^[ \t]*/[A-Za-z_]+(?:[ \t]|$)")
_REF_DEFINITION = re.compile(r"(?m)^ {0,3}\[[^\]\n]+\]:")
_RAW_HTML = re.compile(r"<\s*/?\s*[A-Za-z][^>]*>")
_URL_LIKE = re.compile(
    r"(?i)(?:\b[a-z][a-z0-9+.-]*:)?//[^\s<>)\]]+|\bwww\.[^\s<>)\]]+|\bmailto:[^\s<>)\]]+"
)
_LINK_DESTINATION = re.compile(r"\]\(\s*<?([^)\s>]+)")
_MAX_COMMENT_LENGTH = 10000
_REPOS_BASE = os.path.realpath(REPOS_DIR)
_GITLAB_PARSED = urlparse(GITLAB_URL)
_GITLAB_HOST = _GITLAB_PARSED.hostname
_GITLAB_PORT = _GITLAB_PARSED.port
_ALLOWED_COMMENT_LINK_HOSTS = {
    host.strip().lower()
    for host in os.getenv("GITLAB_ALLOWED_COMMENT_LINK_HOSTS", _GITLAB_HOST or "").split(",")
    if host.strip()
}
logger = logging.getLogger(__name__)


# ─── Token / URL helpers ─────────────────────────────────────
def _get_token():
    token = os.getenv("GITLAB_TOKEN", "")
    if token:
        return token
    secret_arn = os.getenv("GITLAB_SECRET_ARN", "")
    if secret_arn:
        region = os.getenv("AWS_DEFAULT_REGION") or os.getenv("AWS_REGION")
        if not region:
            logger.error("AWS_DEFAULT_REGION or AWS_REGION is required to read the GitLab secret")
            return None
        try:
            import boto3
            client = boto3.client("secretsmanager", region_name=region)
            s = client.get_secret_value(SecretId=secret_arn).get("SecretString", "")
            if s:
                try:
                    data = json.loads(s)
                    for k in ["token", "gitlab_token", "access_token", "GITLAB_TOKEN"]:
                        if data.get(k):
                            return data[k]
                except json.JSONDecodeError:
                    return s.strip()
        except ClientError as exc:
            logger.error(
                "Unable to read the GitLab secret: %s",
                exc.response.get("Error", {}).get("Code", "ClientError"),
            )
            return None
        except BotoCoreError as exc:
            logger.error("Unable to read the GitLab secret: %s", type(exc).__name__)
            return None
    return None


def _git_base_env():
    """Return a non-interactive environment for all Git subprocesses."""
    env = os.environ.copy()
    env["GIT_TERMINAL_PROMPT"] = "0"
    return env


def _git_auth_env(token):
    """Return an environment that authenticates without persisting the token."""
    env = _git_base_env()
    if token:
        basic = base64.b64encode(f"oauth2:{token}".encode()).decode()
        env.update({
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.extraHeader",
            "GIT_CONFIG_VALUE_0": f"Authorization: Basic {basic}",
        })
    return env


def _git_local_env():
    """Return a non-interactive environment without command-scoped Git auth."""
    env = _git_base_env()
    env.pop("GIT_CONFIG_COUNT", None)
    for key in list(env):
        if key.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")):
            env.pop(key)
    return env


def _safe(text, token, n=600):
    text = text or ""
    if token:
        text = text.replace(token, "***")
    return text[:n]


def _validate_safe_name(value, field):
    value = str(value or "")
    if not _SAFE_NAME.fullmatch(value):
        raise ValueError(
            f"Invalid {field}: 1-100 alphanumerics, dots, hyphens, underscores only"
        )
    return value


def _validate_branch(branch):
    branch = str(branch or "")
    if (
        not _SAFE_REF.fullmatch(branch)
        or branch.endswith(("/", "."))
        or any(part in ("", ".", "..") or part.endswith(".lock") for part in branch.split("/"))
    ):
        raise ValueError("Invalid branch")
    return branch


def _validate_repo_url(repo_url):
    """Allow credentials only to the configured GitLab HTTPS origin."""
    parsed = urlparse(str(repo_url or ""))
    expected_port = _GITLAB_PORT or 443
    actual_port = parsed.port or 443
    if (
        not _GITLAB_HOST
        or parsed.scheme != "https"
        or parsed.hostname != _GITLAB_HOST
        or actual_port != expected_port
        or parsed.username
        or parsed.password
        or not parsed.path.strip("/")
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError(f"repo_url must be https://{_GITLAB_HOST}/...")
    return parsed.geturl()


def _repo_path(repo_name, mr_id):
    """Per-MR clone path on S3 Files — isolates concurrent reviews."""
    repo_name = _validate_safe_name(repo_name, "repo_name")
    mr_id = _validate_safe_name(mr_id, "mr_id")
    path = os.path.realpath(os.path.join(_REPOS_BASE, repo_name, mr_id))
    if not path.startswith(_REPOS_BASE + os.sep):
        raise ValueError("Path escapes the repositories directory")
    return path


def _resolve_repo_path(file_path, repo_dir):
    """Resolve a caller-supplied path to an absolute path inside repo_dir.

    Accepts the path shapes an LLM commonly produces and normalizes them so a
    legitimate file is not mistaken for a traversal attempt:
      * repo-relative            ("src/app.py", "./src/app.py")
      * leading-slash root-rel    ("/src/app.py"  -> "src/app.py")
      * fully-qualified inside     ("/mnt/repositories/<repo>/<mr>/src/app.py")

    Returns (real_path, root). Genuine escapes (e.g. "../../etc/passwd") still
    resolve outside root and are rejected by _is_safe_repo_path.
    """
    root = os.path.realpath(repo_dir)
    candidate = (file_path or "").strip()
    if os.path.isabs(candidate):
        abs_candidate = os.path.realpath(candidate)
        if abs_candidate == root or abs_candidate.startswith(root + os.sep):
            return abs_candidate, root
        # Treat a leading slash as root-relative, not filesystem-absolute.
        candidate = candidate.lstrip("/")
    real = os.path.realpath(os.path.join(root, candidate))
    return real, root


def _is_safe_repo_path(file_path, repo_dir):
    real, root = _resolve_repo_path(file_path, repo_dir)
    return real == root or real.startswith(root + os.sep)


def _headers(token):
    return {"PRIVATE-TOKEN": token}


def _encode_project(project_id):
    """GitLab accepts either a numeric project id or a URL-encoded 'namespace/project'
    path. A raw 'org/repo' string 404s unless the slashes are percent-encoded, so
    encode any validated non-numeric id."""
    pid = str(project_id).strip()
    if pid.isdigit():
        return pid
    if not _SAFE_PROJECT.fullmatch(pid) or any(
        part in ("", ".", "..") for part in pid.split("/")
    ):
        raise ValueError("project_id must be numeric or a valid namespace/project path")
    return quote(pid, safe="")


def _mr_base(project_id, mr_iid):
    mr_iid = str(mr_iid).strip()
    if not _SAFE_MR_IID.fullmatch(mr_iid):
        raise ValueError("mr_iid must be numeric")
    return (
        GITLAB_URL
        + "/api/v4/projects/"
        + _encode_project(project_id)
        + "/merge_requests/"
        + mr_iid
    )


def _mr_base_or_error(project_id, mr_iid):
    try:
        return _mr_base(project_id, mr_iid), None
    except ValueError as exc:
        return "", json.dumps({"error": str(exc)})


def _validate_diff_path(path, field, required=True):
    path = str(path or "")
    if (
        (required and not path)
        or len(path) > 1024
        or "\x00" in path
        or "\r" in path
        or "\n" in path
    ):
        raise ValueError(f"Invalid {field}")
    return path


def _validate_positive_line(value, field, required=True):
    if not required and value == "":
        return None
    try:
        value = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field} must be a positive integer") from exc
    if value < 1:
        raise ValueError(f"{field} must be a positive integer")
    return value


def _validate_sha(value, field):
    value = str(value or "")
    if value and not _SAFE_SHA.fullmatch(value):
        raise ValueError(f"{field} must be a 40-character Git SHA")
    return value


def _strip_fenced_code(text):
    """Drop CommonMark fenced code blocks (line-anchored, closing fence >= opening)."""
    kept, fence = [], None
    for line in text.splitlines(keepends=True):
        stripped = line.rstrip("\r\n")
        if fence is None:
            m = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", stripped)
            if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
                fence = (m.group(1)[0], len(m.group(1)))
                continue
            kept.append(line)
        elif re.match(
            r"^ {0,3}" + re.escape(fence[0]) + r"{%d,}[ \t]*$" % fence[1], stripped
        ):
            fence = None
    return "".join(kept)


def _strip_inline_code(paragraph):
    """Drop inline code spans; a span closes only on a backtick run of equal length."""
    out, i, n = [], 0, len(paragraph)
    while i < n:
        if paragraph[i] != "`":
            out.append(paragraph[i])
            i += 1
            continue
        j = i
        while j < n and paragraph[j] == "`":
            j += 1
        run, k, close = j - i, j, -1
        while k < n:
            if paragraph[k] != "`":
                k += 1
                continue
            m = k
            while m < n and paragraph[m] == "`":
                m += 1
            if m - k == run:
                close = k
                break
            k = m
        if close == -1:
            out.append(paragraph[i:j])  # an unmatched run is literal text
            i = j
        else:
            i = close + run
    return "".join(out)


def _rendered_prose(body):
    """Return only the text GitLab renders as active Markdown (code removed)."""
    text = _strip_fenced_code(body)
    # Code spans cannot cross a paragraph break, so pair backticks per paragraph.
    return "\n\n".join(
        _strip_inline_code(paragraph) for paragraph in re.split(r"\n[ \t]*\n", text)
    )


def _validate_comment_body(body):
    """Fail-closed validation of generated Markdown before it reaches GitLab."""
    if not isinstance(body, str):
        raise ValueError(f"body must be 1-{_MAX_COMMENT_LENGTH} characters")
    body = body.strip()
    if not body or len(body) > _MAX_COMMENT_LENGTH:
        raise ValueError(f"body must be 1-{_MAX_COMMENT_LENGTH} characters")
    if any(ord(char) < 32 and char not in "\t\n\r" for char in body):
        raise ValueError("body contains unsupported control characters")

    # GitLab runs quick actions (/merge, /approve, /close, ...) found on their own
    # line in a comment, using the posting user's permissions. Reject them everywhere.
    if _QUICK_ACTION.search(body):
        raise ValueError("body must not contain GitLab quick actions")

    prose = _rendered_prose(body)
    if _RAW_HTML.search(prose):
        raise ValueError("body must not contain raw HTML")
    if "![" in prose:
        raise ValueError("body must not embed remote images")
    if _REF_DEFINITION.search(prose):
        raise ValueError("body must not contain link reference definitions")
    for destination in _LINK_DESTINATION.findall(prose) + _URL_LIKE.findall(prose):
        parsed = urlparse(destination.strip("<>.,;:!?"))
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.hostname.lower() not in _ALLOWED_COMMENT_LINK_HOSTS
        ):
            raise ValueError("body links must use HTTPS and an approved GitLab host")
    return body


# ─── Repo tools (read-only clone on S3 Files) ────────────────
@mcp.tool()
def clone_or_update_repo(repo_url, repo_name, branch, mr_id):
    """Shallow READ-ONLY clone of the MR source branch onto the shared S3 Files mount.

    Clones once into /mnt/repositories/{repo_name}/{mr_id}/ and reuses it on later
    calls (git fetch). Uses --depth 1 for speed. Does NOT create branches, commit, or
    push — it only makes the source available for the agents to READ.
    """
    try:
        repo_url = _validate_repo_url(repo_url)
        branch = _validate_branch(branch)
        repo_dir = _repo_path(repo_name, mr_id)
    except (TypeError, ValueError) as exc:
        return json.dumps({"error": str(exc)})

    token = _get_token()
    env = _git_auth_env(token)

    try:
        if os.path.isdir(os.path.join(repo_dir, ".git")):
            # Remove credentials persisted by older versions before any network call.
            sanitized = subprocess.run(
                ["git", "-C", repo_dir, "remote", "set-url", "--", "origin", repo_url],
                capture_output=True,
                text=True,
                timeout=120,
            )
            if sanitized.returncode != 0:
                return json.dumps({"error": _safe(sanitized.stderr, token)})
            r = subprocess.run(
                ["git", "-C", repo_dir, "fetch", "--depth", "1", "--", repo_url, branch],
                env=env,
                capture_output=True,
                text=True,
                timeout=600,
            )
            if r.returncode == 0:
                r = subprocess.run(
                    ["git", "-C", repo_dir, "checkout", "-f", "FETCH_HEAD"],
                    env=_git_local_env(),
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
            action = "updated"
        else:
            os.makedirs(os.path.dirname(repo_dir), mode=0o750, exist_ok=True)
            r = subprocess.run(
                [
                    "git", "clone", "--depth", "1", "--branch", branch,
                    "--", repo_url, repo_dir,
                ],
                env=env,
                capture_output=True,
                text=True,
                timeout=1800,
            )
            action = "cloned"
    except subprocess.TimeoutExpired:
        return json.dumps({"error": "Git operation timed out"})
    if r.returncode != 0:
        return json.dumps({"error": _safe(r.stderr, token)})
    return json.dumps({"status": action, "repo_dir": repo_dir, "branch": branch})


@mcp.tool()
def read_repo_file(repo_name, mr_id, file_path, from_line=0, to_line=0):
    """Read a file from the cloned repo (full context beyond the diff).

    from_line/to_line (1-indexed) optionally return a slice; 0/0 returns the whole file.
    """
    try:
        repo_dir = _repo_path(repo_name, mr_id)
    except (TypeError, ValueError) as exc:
        return json.dumps({"error": str(exc)})
    full, root = _resolve_repo_path(file_path, repo_dir)
    if not (full == root or full.startswith(root + os.sep)):
        return json.dumps({"error": "Access denied: path traversal detected"})
    if not os.path.isfile(full):
        return json.dumps({"error": "File not found: " + file_path})
    # from_line/to_line may arrive as strings via the gateway JSON — coerce defensively
    # so a "10"/"20" doesn't blow up with "unsupported operand type(s) for -: str, int".
    try:
        from_line = int(from_line or 0)
        to_line = int(to_line or 0)
    except (TypeError, ValueError):
        return json.dumps({"error": "from_line/to_line must be integers"})
    with open(full, "r", encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()
    if from_line or to_line:
        lo = max(from_line - 1, 0)
        hi = to_line if to_line else len(lines)
        lines = lines[lo:hi]
    return ("".join(lines))[:20000]


@mcp.tool()
def list_repo_dir(repo_name, mr_id, dir_path="."):
    """List a directory in the cloned repo."""
    try:
        repo_dir = _repo_path(repo_name, mr_id)
    except (TypeError, ValueError) as exc:
        return json.dumps({"error": str(exc)})
    full, root = _resolve_repo_path(dir_path, repo_dir)
    if not (full == root or full.startswith(root + os.sep)):
        return json.dumps({"error": "Access denied: path traversal detected"})
    if not os.path.isdir(full):
        return json.dumps({"error": "Not a directory: " + dir_path})
    return json.dumps(sorted(os.listdir(full)))


# ─── GitLab API tools ────────────────────────────────────────
@mcp.tool()
def gl_fetch_mr(project_id, mr_iid):
    """Read merge-request metadata (title, branches, state, URL, diff_refs)."""
    base, error = _mr_base_or_error(project_id, mr_iid)
    if error:
        return error
    token = _get_token()
    if not token:
        return json.dumps({"error": "No GitLab token available"})
    r = httpx.get(base, headers=_headers(token), timeout=30)
    if r.status_code != 200:
        hint = " (check project_id — pass the numeric id or url-safe 'namespace/project', and confirm the token can see this project)" if r.status_code == 404 else ""
        return json.dumps({"error": "GitLab API " + str(r.status_code) + ": " + r.text[:300] + hint})
    mr = r.json()
    return json.dumps({k: mr.get(k) for k in
                       ["iid", "title", "description", "source_branch", "target_branch",
                        "state", "web_url", "sha", "diff_refs"]})


@mcp.tool()
def gl_fetch_mr_diff(project_id, mr_iid):
    """Read the MR's changed files and per-file diffs (what changed) + diff_refs."""
    base, error = _mr_base_or_error(project_id, mr_iid)
    if error:
        return error
    token = _get_token()
    if not token:
        return json.dumps({"error": "No GitLab token available"})
    r = httpx.get(base + "/changes", headers=_headers(token), timeout=60)
    if r.status_code != 200:
        return json.dumps({"error": "GitLab API " + str(r.status_code) + ": " + r.text[:300]})
    data = r.json()
    changes = [
        {"old_path": c.get("old_path"), "new_path": c.get("new_path"),
         "new_file": c.get("new_file"), "deleted_file": c.get("deleted_file"),
         "diff": (c.get("diff") or "")[:8000]}
        for c in data.get("changes", [])
    ]
    return json.dumps({"diff_refs": data.get("diff_refs", {}), "changes": changes})


@mcp.tool()
def gl_comment(project_id, mr_iid, body):
    """Post a general (non-inline) comment on the merge request."""
    base, error = _mr_base_or_error(project_id, mr_iid)
    if error:
        return error
    try:
        body = _validate_comment_body(body)
    except ValueError as exc:
        return json.dumps({"error": str(exc)})
    token = _get_token()
    if not token:
        return json.dumps({"error": "No GitLab token available"})
    r = httpx.post(base + "/notes",
                   headers=_headers(token), json={"body": body}, timeout=30)
    if r.status_code not in (200, 201):
        return json.dumps({"error": "GitLab API " + str(r.status_code) + ": " + r.text[:300]})
    return json.dumps({"status": "commented", "mr_iid": mr_iid})


@mcp.tool()
def gl_inline_comment(project_id, mr_iid, body, new_path, new_line,
                      base_sha="", start_sha="", head_sha="", old_path="", old_line=""):
    """Post an INLINE comment on a specific file + line of the MR diff.

    Creates a diff discussion via the GitLab discussions API with a `position`.
    diff_refs (base/start/head_sha) are auto-resolved from the MR if omitted.
    """
    base, error = _mr_base_or_error(project_id, mr_iid)
    if error:
        return error
    try:
        body = _validate_comment_body(body)
        new_path = _validate_diff_path(new_path, "new_path")
        new_line = _validate_positive_line(new_line, "new_line")
        old_path = _validate_diff_path(old_path, "old_path", required=False)
        old_line = _validate_positive_line(old_line, "old_line", required=False)
        base_sha = _validate_sha(base_sha, "base_sha")
        start_sha = _validate_sha(start_sha, "start_sha")
        head_sha = _validate_sha(head_sha, "head_sha")
    except ValueError as exc:
        return json.dumps({"error": str(exc)})

    token = _get_token()
    if not token:
        return json.dumps({"error": "No GitLab token available"})

    if not (base_sha and start_sha and head_sha):
        meta = httpx.get(base, headers=_headers(token), timeout=30)
        if meta.status_code != 200:
            return json.dumps({"error": "Could not resolve diff_refs: " + meta.text[:200]})
        refs = meta.json().get("diff_refs", {}) or {}
        base_sha = base_sha or refs.get("base_sha", "")
        start_sha = start_sha or refs.get("start_sha", "")
        head_sha = head_sha or refs.get("head_sha", "")
    if not (base_sha and start_sha and head_sha):
        return json.dumps({"error": "MR has no diff_refs (nothing to attach an inline comment to)"})

    position = {
        "position_type": "text",
        "base_sha": base_sha, "start_sha": start_sha, "head_sha": head_sha,
        "new_path": new_path, "new_line": new_line,
    }
    if old_path:
        position["old_path"] = old_path
    if old_line is not None:
        position["old_line"] = old_line

    r = httpx.post(base + "/discussions",
                   headers=_headers(token), json={"body": body, "position": position}, timeout=30)
    if r.status_code not in (200, 201):
        return json.dumps({"error": "GitLab API " + str(r.status_code) + ": " + r.text[:300]})
    return json.dumps({"status": "inline_commented", "file": new_path, "line": new_line})
