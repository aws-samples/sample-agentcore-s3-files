"""Security regression tests for the GitLab MCP trust boundary."""

import importlib.util
import json

import pytest
from pathlib import Path
from unittest.mock import patch


SERVER_PATH = (
    Path(__file__).resolve().parents[1]
    / "src"
    / "mcp-servers"
    / "gitlab"
    / "server.py"
)
SPEC = importlib.util.spec_from_file_location("gitlab_mcp_server", SERVER_PATH)
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)


def test_mr_id_cannot_escape_repository_root():
    assert "Invalid mr_id" in json.loads(
        server.read_repo_file("demo", "/", "etc/passwd")
    )["error"]
    assert "Invalid mr_id" in json.loads(
        server.list_repo_dir("demo", "../..", ".")
    )["error"]


def test_clone_rejects_untrusted_hosts_before_reading_token():
    with patch.object(server, "_get_token") as get_token:
        result = json.loads(
            server.clone_or_update_repo(
                "https://example.com/a/b", "demo", "main", "1"
            )
        )
    assert result["error"] == "repo_url must be https://gitlab.com/..."
    get_token.assert_not_called()


def test_clone_rejects_git_option_in_branch():
    result = json.loads(
        server.clone_or_update_repo(
            "https://gitlab.com/a/b", "demo", "--upload-pack=x", "1"
        )
    )
    assert result["error"] == "Invalid branch"


def test_mr_iid_and_project_id_are_validated():
    assert json.loads(server.gl_fetch_mr("123", "1/../.."))["error"] == (
        "mr_iid must be numeric"
    )
    assert "project_id" in json.loads(server.gl_fetch_mr("../etc/passwd", "1"))[
        "error"
    ]


def test_authentication_uses_header_not_repository_url():
    env = server._git_auth_env("secret-token")
    assert env["GIT_CONFIG_KEY_0"] == "http.extraHeader"
    assert env["GIT_CONFIG_VALUE_0"].startswith("Authorization: Basic ")
    assert "secret-token" not in env["GIT_CONFIG_VALUE_0"]


def test_local_git_environment_disables_prompts_without_the_auth_header():
    with patch.dict(
        server.os.environ,
        {
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "http.extraHeader",
            "GIT_CONFIG_VALUE_0": "Authorization: Basic secret",
        },
    ):
        env = server._git_local_env()

    assert env["GIT_TERMINAL_PROMPT"] == "0"
    assert "GIT_CONFIG_COUNT" not in env
    assert "GIT_CONFIG_KEY_0" not in env
    assert "GIT_CONFIG_VALUE_0" not in env


def test_inline_comment_rejects_invalid_position():
    with patch.object(server, "_get_token", return_value="test-token"):
        result = json.loads(
            server.gl_inline_comment(
                "group/project",
                "1",
                "review comment",
                "src/app.py\nX-Injected: true",
                "not-a-line",
            )
        )

    assert result["error"] in {"Invalid new_path", "new_line must be a positive integer"}


def test_comment_output_validation_rejects_unsafe_rendered_content():
    unsafe_bodies = [
        "Review result <img src=https://example.com/tracker>",
        "See [external instructions](https://example.com/fix)",
        "![remote image](https://gitlab.com/tracker.png)",
        "Control character: \x1b",
    ]
    for body in unsafe_bodies:
        with patch.object(server, "_get_token") as get_token:
            result = json.loads(server.gl_comment("group/project", "1", body))
        assert "error" in result
        get_token.assert_not_called()


def test_comment_output_validation_allows_safe_markdown_and_code_samples():
    body = (
        "## Finding\n"
        "- See [the merge request](https://gitlab.com/group/project/-/merge_requests/1).\n"
        "- Replace `<script>` and `https://example.com/sample` in the code."
    )
    assert server._validate_comment_body(body) == body


def test_comment_validation_rejects_quick_actions_and_reference_images():
    for body in [
        "Looks fine.\n\n/merge",
        "LGTM\n/approve",
        "```\n/merge\n```",
        "![x][r]\n\n[r]: //attacker.example/p.png?d=1",
        "![r][]\n\n[r]: http://attacker.example/p.png",
        "````![x](https://attacker.example/p.png)```",
        "see http://attacker.example/x",
        "see www.attacker.example/x",
    ]:
        with pytest.raises(ValueError):
            server._validate_comment_body(body)


def test_empty_mr_id_is_rejected():
    assert "Invalid mr_id" in json.loads(server.list_repo_dir("demo", "", "."))["error"]
    assert "Invalid mr_id" in json.loads(server.read_repo_file("demo", "", "x"))["error"]
    with patch.object(server, "_get_token") as get_token:
        result = json.loads(
            server.clone_or_update_repo("https://gitlab.com/a/b", "demo", "main", "")
        )
    assert "Invalid mr_id" in result["error"]
    get_token.assert_not_called()
