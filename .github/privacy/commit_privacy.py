#!/usr/bin/env python3
"""Check that every new commit uses a public author and committer identity.

Runs inside the history-privacy job and publishes the commit-privacy check on
the exact head. Reads metadata through the GitHub API only; never echoes names,
emails or commit subjects.
"""

import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request

from history_privacy import select_event

# Public GitHub handles and approved public display names only.
# Never put private names, emails, or the denylist here.
PROTECTED_LOGINS = {"petertoday"}
PUBLIC_DISPLAY_NAMES = {"petertoday": {"Peter"}}
# Public automation identities; do not exempt an entire actor or commit.
PUBLIC_BOT_IDENTITIES = {"noreply@anthropic.com": {"claude", "claude code"}}
BOT_DISPLAY_NAMES = {
    "claude[bot]": {"claude", "claude code"},
    "claude-code-action[bot]": {"claude", "claude code"},
}
NOREPLY = re.compile(r"(?:[0-9]+\+)?([A-Za-z0-9-]+(?:\[bot\])?)@users\.noreply\.github\.com", re.IGNORECASE)
SHA = re.compile(r"[0-9a-f]{40}")


class CheckError(Exception):
    pass


def valid_public_identity(name, email):
    if name == "GitHub" and email == "noreply@github.com":
        return True
    if name.casefold() in PUBLIC_BOT_IDENTITIES.get(email.casefold(), set()):
        return True
    match = NOREPLY.fullmatch(email)
    if match is None:
        return False
    login = match.group(1).casefold()
    approved = {login} | {value.casefold() for value in PUBLIC_DISPLAY_NAMES.get(login, set())}
    if login.endswith("[bot]"):
        approved |= {login[:-5]} | BOT_DISPLAY_NAMES.get(login, set())
    return name.casefold() in approved


def invalid_fields(commit):
    """Every author and committer needs a public identity. Anything that looks
    like the protected account must also use that account's own noreply."""
    protected_names = {display.casefold() for login in PROTECTED_LOGINS
                       for display in PUBLIC_DISPLAY_NAMES.get(login, set())}
    invalid = []
    for field in ("author", "committer"):
        raw = commit["commit"][field]
        name, email = raw["name"], raw["email"]
        login = (commit.get(field) or {}).get("login", "").casefold()
        match = NOREPLY.fullmatch(email)
        public_login = match.group(1).casefold() if match else ""
        protected = bool({login, name.casefold(), public_login} & (PROTECTED_LOGINS | protected_names))
        if not valid_public_identity(name, email) or (protected and public_login not in PROTECTED_LOGINS):
            invalid.append(field)
    return invalid


def collect_commits(base, head, request):
    """All commits in base...head; refuse partial results rather than trust them."""
    if not SHA.fullmatch(base) or not SHA.fullmatch(head):
        raise CheckError("Invalid commit range.")
    if base == head:
        return []
    commits = []
    total = None
    page = 1
    while True:
        result = request(f"/compare/{base}...{head}?per_page=100&page={page}")
        if total is None:
            total = result["total_commits"]
        elif total != result["total_commits"]:
            raise CheckError("Commit range changed while checking it.")
        batch = result["commits"]
        commits.extend(batch)
        if len(commits) >= total:
            break
        if not batch:
            raise CheckError("Incomplete commit range; check refused.")
        page += 1
    if len(commits) != total or len({c["sha"] for c in commits}) != total:
        raise CheckError("Incomplete or duplicate commit range; check refused.")
    return commits


def regression_checks():
    # Synthetic identities only: no real personal identifiers in tests or logs.
    def fixture(name, email, login=None):
        raw = {"name": name, "email": email}
        account = {"login": login} if login else None
        return {"commit": {"author": raw, "committer": raw}, "author": account, "committer": account}
    for name, email in (
        ("example-user", "123+example-user@users.noreply.github.com"),
        ("example-user", "example-user@users.noreply.github.com"),
        ("github-actions[bot]", "41898282+github-actions[bot]@users.noreply.github.com"),
        ("dependabot[bot]", "49699333+dependabot[bot]@users.noreply.github.com"),
        ("GitHub", "noreply@github.com"),
        ("Claude", "noreply@anthropic.com"),
        ("Claude Code", "noreply@anthropic.com"),
        ("CLAUDE", "NOREPLY@ANTHROPIC.COM"),
        ("Claude", "209825114+claude[bot]@users.noreply.github.com"),
        ("Claude Code", "208546643+claude-code-action[bot]@users.noreply.github.com"),
    ):
        assert valid_public_identity(name, email), (name, email)
        assert invalid_fields(fixture(name, email)) == []
    for name, email in (
        ("Example Person", "noreply@anthropic.com"),
        ("Claude", "example@anthropic.com"),
        ("Claude", "noreply@anthropic.com.example.invalid"),
        ("Example Person", "123+example-automation[bot]@users.noreply.github.com"),
        ("Example Person", "123+example-user@users.noreply.github.com"),
        ("example-user", "example@example.invalid"),
    ):
        assert not valid_public_identity(name, email), (name, email)
    # Every contributor needs a public identity, not only the protected account.
    assert invalid_fields(fixture("Example Contributor", "contributor@example.invalid", "other")) == ["author", "committer"]
    assert PROTECTED_LOGINS == {"petertoday"}
    protected = "petertoday"
    assert invalid_fields(fixture(protected, "171875562+petertoday@users.noreply.github.com", protected)) == []
    assert invalid_fields(fixture("example-previous-handle", "123+example-previous-handle@users.noreply.github.com", protected)) == ["author", "committer"]
    assert invalid_fields(fixture("Example Person", "example@example.invalid", protected)) == ["author", "committer"]
    # A public bot identity cannot disguise the protected human account.
    assert invalid_fields(fixture("Claude", "noreply@anthropic.com", protected)) == ["author", "committer"]
    mixed = fixture(protected, protected + "@users.noreply.github.com", protected)
    mixed["commit"]["committer"] = {"name": "Example Person", "email": "example@example.invalid"}
    assert invalid_fields(mixed) == ["committer"]
    for display in PUBLIC_DISPLAY_NAMES[protected]:
        assert invalid_fields(fixture(display, "123+" + protected + "@users.noreply.github.com", protected)) == []
        assert invalid_fields(fixture(display, protected + "@users.noreply.github.com", None)) == []
        # The approved display name cannot ride on someone else's noreply.
        assert invalid_fields(fixture(display, "example-user@users.noreply.github.com", "other")) == ["author", "committer"]
        assert invalid_fields(fixture(display.casefold(), "example@example.invalid", None)) == ["author", "committer"]
    assert collect_commits("a" * 40, "a" * 40, None) == []
    # Cover more than 250 commits; never rely on truncated commit lists.
    calls = []
    def paginated(path):
        page = int(path.rsplit("=", 1)[1])
        calls.append(page)
        start = (page - 1) * 100
        return {"total_commits": 251, "commits": [{"sha": f"{i:040x}"} for i in range(start, min(start + 100, 251))]}
    assert len(collect_commits("a" * 40, "b" * 40, paginated)) == 251
    assert calls == [1, 2, 3]
    try:
        collect_commits("a" * 40, "b" * 40, lambda path: {"total_commits": 2, "commits": []})
    except CheckError:
        pass
    else:
        raise AssertionError("Incomplete history was accepted")


def main():
    regression_checks()
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as stream:
        event = json.load(stream)
    api = os.environ["GITHUB_API_URL"].rstrip("/")
    repository = os.environ["GITHUB_REPOSITORY"]

    def request(path, method="GET", payload=None):
        # Reads use the job's read-only token; only check publication uses the App token.
        token = os.environ["GH_TOKEN" if method in ("POST", "PATCH") else "GH_READ_TOKEN"]
        req = urllib.request.Request(api + "/repos/" + repository + path, method=method,
            data=json.dumps(payload).encode("utf-8") if payload is not None else None, headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return json.load(response)
        except (urllib.error.URLError, ValueError):
            raise CheckError("GitHub could not supply commit metadata; retry the check.") from None

    _, _, head = select_event(os.environ["GITHUB_EVENT_NAME"], event, os.environ["GITHUB_SHA"])
    if head is None:
        print("Reference deletion: no new commits to check.")
        return 0
    baseline = json.loads(Path(__file__).with_name("policy.json").read_text(encoding="utf-8"))["baseline"]
    report = request("/check-runs", method="POST", payload={
        "name": "commit-privacy", "head_sha": head, "status": "in_progress"})
    passed = False
    try:
        commits = collect_commits(baseline, head, request)
        failures = 0
        for commit in commits:
            for field in invalid_fields(commit):
                print(f"::error::An incoming commit has noncompliant {field} metadata. Use an approved public "
                      "name and GitHub noreply email; run git-privacy-guard verify before pushing.")
                failures += 1
        print(f"Checked {len(commits)} commits; {failures} identity violations.")
        passed = failures == 0
        return 0 if passed else 1
    finally:
        request("/check-runs/" + str(report["id"]), method="PATCH", payload={
            "status": "completed", "conclusion": "success" if passed else "failure",
            "output": {"title": "Commit privacy " + ("passed" if passed else "failed"),
                       "summary": "Author and committer identities checked; identifying values withheld."}})


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - never echo unexpected details
        message = str(error) if isinstance(error, CheckError) else "Commit privacy verification failed; details redacted."
        print("::error::" + message)
        sys.exit(1)
