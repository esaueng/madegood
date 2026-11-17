#!/usr/bin/env python3
"""Audit new Git history for denylisted identifiers.

Every newly reachable commit, tree, blob, annotated tag and ref name is read as
data and checked against keyed fingerprints of the operator's private denylist.
Incoming code is never checked out or executed, and failures never echo the
matched value, path or object ID.
"""

import argparse
import base64
import hmac
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

OID = re.compile(r"[0-9a-f]{40}")
HEX256 = re.compile(r"[0-9a-f]{64}")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
CHUNK = 1024 * 1024
POLICY_VERSION = 2
# Never handed to Git subprocesses (GH_READ_TOKEN only to fetches, see git()).
PRIVATE_ENV = ("HISTORY_PRIVACY_HMAC_KEY", "GH_TOKEN", "GH_READ_TOKEN")


class PrivacyError(Exception):
    """Messages intentionally contain no incoming content or identifiers."""


def fingerprint(key, domain, value):
    return hmac.digest(key, domain + b"\0" + value, "sha256").hex()


class Policy:
    """Keyed fingerprints of denylisted values; the plaintext never leaves the operator."""

    def __init__(self, path, key):
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8"))
            self.key = bytes.fromhex(key)
            if len(self.key) != 32 or data["version"] != POLICY_VERSION:
                raise ValueError()
            if not hmac.compare_digest(data["verification_digest"], fingerprint(self.key, b"key", b"history-privacy-v1")):
                raise ValueError()
            self.baseline = data["baseline"]
            if not OID.fullmatch(self.baseline):
                raise ValueError()
            tokens = data["identifiers"]
            if not tokens:
                raise ValueError()
            wanted = {}
            for token in tokens:
                length = token["length"]
                if (not isinstance(length, int) or not 3 <= length <= 4096 or
                        not HEX256.fullmatch(token["digest"]) or
                        not HEX256.fullmatch(token["prefix_digest"])):
                    raise ValueError()
                wanted.setdefault(token["prefix_digest"], []).append(token)
            # Recover only the two-byte prefixes, in memory, using the key. They
            # pick candidate offsets; full values are compared by HMAC alone.
            self.prefixes = {}
            for number in range(65536):
                prefix = number.to_bytes(2, "big")
                digest = fingerprint(self.key, b"prefix", prefix)
                if digest in wanted:
                    self.prefixes[prefix] = wanted.pop(digest)
            if wanted:
                raise ValueError()
            self.find = re.compile(b"(?=(" + b"|".join(re.escape(p) for p in self.prefixes) + b"))")
            # Bytes carried between streamed chunks so a value split across a
            # chunk boundary is still seen whole.
            self.overlap = max(t["length"] for t in tokens) - 1
        except (KeyError, TypeError, ValueError, OSError, OverflowError):
            raise PrivacyError("Privacy policy or secret key is missing, invalid, or mismatched.") from None

    def check(self, data):
        folded = data.lower()
        for match in self.find.finditer(folded):
            for token in self.prefixes[match[1]]:
                candidate = folded[match.start():match.start() + token["length"]]
                if len(candidate) == token["length"] and hmac.compare_digest(
                        fingerprint(self.key, b"value", candidate), token["digest"]):
                    raise PrivacyError("Denylisted identifier found in incoming Git data; details withheld.")


def git_env(fetch_auth=False):
    # Drop the key, tokens and any inherited Git config injection.
    env = {k: v for k, v in os.environ.items() if k not in PRIVATE_ENV and not k.startswith("GIT_CONFIG_")}
    env.update(GIT_NO_REPLACE_OBJECTS="1", GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")
    token = os.environ.get("GH_READ_TOKEN", "")
    if fetch_auth and token:
        # This repository is private: fetches need the job's contents-read
        # token. Pass it through the environment (never argv), scoped to
        # github.com, and only to fetch.
        basic = base64.b64encode(("x-access-token:" + token).encode("utf-8")).decode("ascii")
        env.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="http.https://github.com/.extraheader",
                   GIT_CONFIG_VALUE_0="AUTHORIZATION: basic " + basic)
    return env


def git(repo, *args, data=None, fetch_auth=False):
    result = subprocess.run(["git", "-C", str(repo), *args], input=data,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=git_env(fetch_auth))
    if result.returncode:
        raise PrivacyError("Git history is unavailable or incomplete; verification refused.")
    return result.stdout


def scan(repo, policy, heads, excludes=(), refs=()):
    """Check every object reachable from heads but not from excludes."""
    if not heads:
        raise PrivacyError("No history selected for verification.")
    for oid in [*heads, *excludes]:
        if not OID.fullmatch(oid):
            raise PrivacyError("Invalid Git range.")
    if git(repo, "rev-parse", "--is-shallow-repository").strip() != b"false":
        raise PrivacyError("Shallow history cannot be verified.")
    for ref in refs:
        policy.check(ref.encode("utf-8"))
    revisions = "\n".join([*heads, *("^" + oid for oid in excludes)]) + "\n"
    objects = git(repo, "rev-list", "--objects", "--no-object-names", "--stdin", data=revisions.encode("ascii"))
    ids = set(objects.decode("ascii").splitlines())
    # rev-list peels annotated tags; add each tag object (and nested tags).
    for head in heads:
        oid, seen = head, set()
        while True:
            if oid in seen:
                raise PrivacyError("Invalid tag chain.")
            seen.add(oid)
            ids.add(oid)
            kind = git(repo, "cat-file", "-t", oid).strip()
            if kind != b"tag":
                if kind != b"commit":
                    raise PrivacyError("References must resolve to commits.")
                break
            tag = git(repo, "cat-file", "tag", oid)
            policy.check(tag)
            oid = tag.splitlines()[0].split()[1].decode("ascii")
            if not OID.fullmatch(oid):
                raise PrivacyError("Invalid tag target.")
    ordered = sorted(ids)
    # Stream objects through files rather than pipes: no deadlocks, and Git
    # diagnostics (which can name paths) are never printed.
    with tempfile.TemporaryFile() as requests, tempfile.TemporaryFile() as errors:
        requests.write(("\n".join(ordered) + "\n").encode("ascii"))
        requests.seek(0)
        process = subprocess.Popen(["git", "-C", str(repo), "cat-file", "--batch"], stdin=requests,
                                   stdout=subprocess.PIPE, stderr=errors, env=git_env())
        try:
            for oid in ordered:
                header = process.stdout.readline().split()
                if len(header) != 3 or header[0].decode("ascii") != oid or header[1] not in (b"commit", b"tree", b"blob", b"tag"):
                    raise PrivacyError("Git object could not be read completely.")
                remaining = int(header[2])
                tail = b""
                while remaining:
                    block = process.stdout.read(min(CHUNK, remaining))
                    if not block:
                        raise PrivacyError("Truncated Git object; verification refused.")
                    remaining -= len(block)
                    joined = tail + block
                    policy.check(joined)
                    tail = joined[-policy.overlap:]
                if process.stdout.read(1) != b"\n":
                    raise PrivacyError("Invalid Git object framing.")
            if process.wait():
                raise PrivacyError("Git object scan failed.")
        finally:
            process.stdout.close()
            if process.poll() is None:
                process.terminate()
                process.wait()
    return len(ordered)


def select_event(name, event, default_head):
    """Return (heads, ref names, head to report on) for a trusted event."""
    if name == "pull_request_target":
        pr = event["pull_request"]
        return [pr["head"]["sha"]], [pr["head"]["ref"]], pr["head"]["sha"]
    if name == "push":
        if event.get("deleted"):
            return [], [], None
        head = event["after"]
        if not OID.fullmatch(head):
            raise PrivacyError("Invalid audit target.")
        return [head], [], head
    if name in ("workflow_dispatch", "schedule"):
        head = (event.get("inputs") or {}).get("audit_head") or default_head
        if not OID.fullmatch(head):
            raise PrivacyError("Invalid audit target.")
        return [head], [], head
    # pull_request and merge_group run branch-controlled definitions; they
    # never reach the credentials, and the scanner refuses them too.
    raise PrivacyError("Unsupported event; verification refused.")


def audit_all_refs(name, event):
    # Pushes to main, the daily run and a plain dispatch audit every branch and
    # tag, so tags and branches without a pull request are covered too.
    return name in ("push", "schedule") or (
        name == "workflow_dispatch" and not (event.get("inputs") or {}).get("audit_head"))


def repository():
    value = os.environ["GITHUB_REPOSITORY"]
    if not REPOSITORY.fullmatch(value):
        raise PrivacyError("Invalid repository context.")
    return value


def api(method, path, body):
    request = urllib.request.Request("https://api.github.com/repos/" + repository() + path,
                                     data=json.dumps(body).encode("utf-8"), method=method, headers={
                                         "Authorization": "Bearer " + os.environ["GH_TOKEN"],
                                         "Accept": "application/vnd.github+json",
                                         "X-GitHub-Api-Version": "2022-11-28"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except (urllib.error.URLError, ValueError):
        raise PrivacyError("GitHub check result could not be published; retry required.") from None


def start_check(head):
    if not OID.fullmatch(head):
        raise PrivacyError("Invalid check head.")
    return api("POST", "/check-runs", {
        "name": "history-privacy", "head_sha": head, "status": "in_progress",
        "details_url": "https://github.com/" + repository() + "/actions/runs/" + os.environ.get("GITHUB_RUN_ID", "")})


def ci(policy_path):
    name = os.environ["GITHUB_EVENT_NAME"]
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    heads, refs, report_head = select_event(name, event, os.environ["GITHUB_SHA"])
    if not heads:
        print("Reference deletion: no incoming history.")
        return
    check = None
    passed = False
    try:
        # Publish on the exact head first, so any later failure is visible there.
        check = start_check(report_head)
        policy = Policy(policy_path, os.environ.get("HISTORY_PRIVACY_HMAC_KEY", ""))
        full_audit = audit_all_refs(name, event)
        with tempfile.TemporaryDirectory(prefix="history-privacy-") as directory:
            git(directory, "init", "--bare", "--quiet", ".")
            git(directory, "remote", "add", "origin", "https://github.com/" + repository() + ".git")
            for oid in sorted({policy.baseline, *heads}):
                git(directory, "-c", "protocol.file.allow=never", "-c", "protocol.ext.allow=never",
                    "fetch", "--quiet", "--no-tags", "--no-recurse-submodules", "origin", oid, fetch_auth=True)
            if full_audit:
                git(directory, "-c", "protocol.file.allow=never", "-c", "protocol.ext.allow=never",
                    "fetch", "--quiet", "--no-recurse-submodules", "origin",
                    "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*", fetch_auth=True)
                listed = git(directory, "for-each-ref", "--format=%(objectname) %(refname)",
                             "refs/heads", "refs/tags").decode("utf-8").splitlines()
                for line in listed:
                    oid, ref = line.split(" ", 1)
                    heads.append(oid)
                    refs.append(ref)
            count = scan(directory, policy, heads, excludes=[] if full_audit else [policy.baseline], refs=refs)
        print(f"PASS: inspected {count} incoming Git objects; privacy details withheld.")
        passed = True
    finally:
        if check is not None:
            api("PATCH", "/check-runs/" + str(check["id"]), {
                "status": "completed", "conclusion": "success" if passed else "failure",
                "output": {"title": "History privacy " + ("passed" if passed else "failed"),
                           "summary": "New history checked for denylisted identifiers without executing it."
                           if passed else "Verification failed. Values, paths and object IDs are withheld; "
                           "inspect the audit job and run git-privacy-guard locally."}})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", default=str(Path(__file__).with_name("policy.json")))
    parser.add_argument("--ci", action="store_true")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--head", action="append", default=[])
    parser.add_argument("--full", action="store_true", help="Also inspect the baseline's ancestry")
    args = parser.parse_args()
    try:
        if args.ci:
            ci(args.policy)
        else:
            policy = Policy(args.policy, os.environ.get("HISTORY_PRIVACY_HMAC_KEY", ""))
            count = scan(args.repo, policy, args.head, () if args.full else [policy.baseline])
            print(f"PASS: inspected {count} Git objects; privacy details withheld.")
        return 0
    except (PrivacyError, KeyError, TypeError, ValueError, OSError, UnicodeError):
        # Never echo exceptions, Git diagnostics, names, paths or object IDs.
        print("::error::History privacy verification failed; values and object IDs withheld.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
