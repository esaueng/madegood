"""Synthetic regression fixtures only; no real identifiers or historical OIDs."""

import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("history_privacy", Path(__file__).with_name("history_privacy.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
KEY = "ab" * 32
REMOVED = b"fixture-person@example.invalid"


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.env = dict(os.environ, GIT_AUTHOR_NAME="example-user", GIT_COMMITTER_NAME="example-user",
                        GIT_AUTHOR_EMAIL="123+example-user@users.noreply.github.com",
                        GIT_COMMITTER_EMAIL="123+example-user@users.noreply.github.com")
        self.run_git("init", "--quiet")
        # A private temporary test repo has no project hooks to chain. The
        # production repository and its shared hooks are never altered.
        (self.root / "hooks").mkdir()
        self.run_git("config", "core.hooksPath", str(self.root / "hooks"))
        self.commit("safe.txt", b"safe", "fixture baseline")
        self.base = self.oid()
        self.policy_path = self.root / "policy.json"
        self.write_policy()
        self.policy = guard.Policy(self.policy_path, KEY)

    def tearDown(self):
        self.tmp.cleanup()

    def run_git(self, *args, data=None, env=None):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], input=data,
                                       env=env or self.env, stderr=subprocess.DEVNULL)

    def oid(self, ref="HEAD"):
        return self.run_git("rev-parse", ref).decode().strip()

    def commit(self, name, contents, message, env=None):
        (self.repo / name).write_bytes(contents)
        self.run_git("add", "--", name)
        self.run_git("commit", "--quiet", "-m", message, env=env)

    def write_policy(self, key=KEY):
        raw = bytes.fromhex(key)
        self.policy_path.write_text(json.dumps({
            "version": guard.POLICY_VERSION, "baseline": self.base,
            "verification_digest": guard.fingerprint(raw, b"key", b"history-privacy-v1"),
            "identifiers": [{"length": len(REMOVED),
                             "prefix_digest": guard.fingerprint(raw, b"prefix", REMOVED[:2]),
                             "digest": guard.fingerprint(raw, b"value", REMOVED)}]}))

    def inspect(self, *heads):
        return guard.scan(self.repo, self.policy, list(heads) or [self.oid()], [self.base])

    def test_clean_history_and_public_identity_pass(self):
        self.commit("clean.txt", b"normal contribution", "clean change")
        self.assertGreater(self.inspect(), 0)

    def test_dirty_older_commit_cannot_hide_behind_clean_tip(self):
        self.commit("deleted.txt", b"prefix " + REMOVED.upper() + b" suffix", "old data")
        self.run_git("rm", "--quiet", "deleted.txt")
        self.run_git("commit", "--quiet", "-m", "clean tip")
        with self.assertRaises(guard.PrivacyError):
            self.inspect()

    def test_removed_identifier_in_commit_message(self):
        self.commit("clean.txt", b"clean", REMOVED.decode())
        with self.assertRaises(guard.PrivacyError):
            self.inspect()

    def test_unrecognized_author_and_committer_are_scanned(self):
        for field in ("AUTHOR", "COMMITTER"):
            with self.subTest(field=field):
                env = dict(self.env, **{"GIT_" + field + "_EMAIL": REMOVED.decode()})
                self.commit(field + ".txt", b"clean", "metadata fixture", env=env)
                with self.assertRaises(guard.PrivacyError):
                    self.inspect()

    def test_removed_filename(self):
        self.commit(REMOVED.decode(), b"clean", "filename fixture")
        with self.assertRaises(guard.PrivacyError):
            self.inspect()

    def test_binary_and_chunk_boundary(self):
        self.commit("binary.dat", b"\xff\0" + b"x" * 61 + REMOVED + b"\0", "binary fixture")
        with patch.object(guard, "CHUNK", 64):
            with self.assertRaises(guard.PrivacyError):
                self.inspect()

    def test_annotated_and_nested_tags(self):
        self.run_git("tag", "-a", "inner", "-m", REMOVED.decode())
        self.run_git("tag", "-a", "outer", "inner", "-m", "safe outer tag")
        with self.assertRaises(guard.PrivacyError):
            self.inspect(self.oid("outer"))

    def test_reference_name(self):
        with self.assertRaises(guard.PrivacyError):
            guard.scan(self.repo, self.policy, [self.oid()], [self.base], ["refs/heads/" + REMOVED.decode()])

    def test_non_fast_forward_history_and_merge_parent_are_checked(self):
        self.commit("old.txt", REMOVED, "dirty side branch")
        old = self.oid()
        self.run_git("checkout", "--quiet", "--detach", self.base)
        self.commit("new.txt", b"clean", "clean branch")
        self.run_git("merge", "--quiet", "--no-ff", "-m", "merge fixture", old)
        with self.assertRaises(guard.PrivacyError):
            self.inspect()

    def test_shallow_and_missing_objects_fail_closed(self):
        with self.assertRaises(guard.PrivacyError):
            self.inspect("1" * 40)
        (self.repo / ".git" / "shallow").write_text(self.base + "\n")
        with self.assertRaises(guard.PrivacyError):
            self.inspect()

    def test_replace_refs_cannot_hide_dirty_commit(self):
        self.commit("dirty.txt", REMOVED, "original fixture")
        old = self.oid()
        self.run_git("replace", old, self.base)
        with self.assertRaises(guard.PrivacyError):
            self.inspect(old)

    def test_policy_missing_secret_wrong_secret_and_corruption_fail_closed(self):
        for key in ("", "cd" * 32):
            with self.assertRaises(guard.PrivacyError):
                guard.Policy(self.policy_path, key)
        valid = json.loads(self.policy_path.read_text())
        for corrupt in ({"version": 1}, {"identifiers": []}, {"baseline": "main"}):
            self.policy_path.write_text(json.dumps(dict(valid, **corrupt)))
            with self.subTest(corrupt=corrupt), self.assertRaises(guard.PrivacyError):
                guard.Policy(self.policy_path, KEY)

    def test_errors_do_not_echo_private_content_or_oid(self):
        self.commit("dirty.txt", REMOVED, "dirty fixture")
        env = dict(self.env, HISTORY_PRIVACY_HMAC_KEY=KEY)
        result = subprocess.run(["python3", str(Path(guard.__file__)), "--repo", str(self.repo),
                                 "--policy", str(self.policy_path), "--head", self.oid()],
                                env=env, capture_output=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(REMOVED, result.stdout + result.stderr)
        self.assertNotIn(self.oid().encode(), result.stdout + result.stderr)

    def test_trusted_events_select_exact_head(self):
        head = "b" * 40
        event = {"pull_request": {"head": {"sha": head, "ref": "topic"}}}
        self.assertEqual(guard.select_event("pull_request_target", event, self.base), ([head], ["topic"], head))
        self.assertEqual(guard.select_event("workflow_dispatch", {"inputs": {"audit_head": head}}, self.base),
                         ([head], [], head))
        self.assertEqual(guard.select_event("schedule", {}, self.base), ([self.base], [], self.base))
        self.assertEqual(guard.select_event("push", {"after": head}, self.base), ([head], [], head))
        self.assertEqual(guard.select_event("push", {"deleted": True}, self.base), ([], [], None))
        for name in ("pull_request", "merge_group", "workflow_run"):
            with self.subTest(name=name), self.assertRaises(guard.PrivacyError):
                guard.select_event(name, {}, self.base)
        self.assertTrue(guard.audit_all_refs("push", {}))
        self.assertTrue(guard.audit_all_refs("schedule", {}))
        self.assertTrue(guard.audit_all_refs("workflow_dispatch", {"inputs": {"audit_head": ""}}))
        self.assertFalse(guard.audit_all_refs("workflow_dispatch", {"inputs": {"audit_head": head}}))
        self.assertFalse(guard.audit_all_refs("pull_request_target", {}))
        with self.assertRaises(guard.PrivacyError):
            guard.select_event("workflow_dispatch", {"inputs": {"audit_head": "untrusted argument"}}, self.base)

    def test_main_push_audit_catches_annotated_tag_metadata_on_a_clean_commit(self):
        head = self.oid()
        self.run_git("tag", "-a", "dirty-metadata", "-m", REMOVED.decode())
        tag = self.oid("dirty-metadata")
        event = self.root / "tag-event.json"
        event.write_text(json.dumps({"ref": "refs/heads/main", "after": head}))
        env = dict(GITHUB_EVENT_PATH=str(event), GITHUB_EVENT_NAME="push",
                   GITHUB_SHA=self.base, GITHUB_REPOSITORY="example/repository",
                   HISTORY_PRIVACY_HMAC_KEY=KEY)
        real_git, real_scan = guard.git, guard.scan
        def fetch_fixture(repo, *args, **kwargs):
            if args[0] == "for-each-ref":
                return (tag + " refs/tags/dirty-metadata\n").encode()
            return b""
        def inspect_fixture(repo, policy, heads, excludes, refs):
            self.assertIn(head, heads)  # pushed head survives all-ref enumeration
            self.assertIn(tag, heads)   # annotated tag object, not only its peeled commit
            with patch.object(guard, "git", real_git):
                return real_scan(self.repo, policy, heads, excludes, refs)
        with patch.dict(os.environ, env), patch.object(guard, "git", side_effect=fetch_fixture), \
                patch.object(guard, "scan", side_effect=inspect_fixture), \
                patch.object(guard, "api", return_value={"id": 123}) as api:
            with self.assertRaises(guard.PrivacyError):
                guard.ci(self.policy_path)
        self.assertEqual(api.call_args_list[-1].args[2]["conclusion"], "failure")

    def test_refs_at_head_includes_branches_and_annotated_tags(self):
        head, other, tag = "a" * 40, "b" * 40, "c" * 40
        advertised = "\n".join(oid + "\t" + ref for oid, ref in (
            (head, "refs/heads/topic"), (head, "refs/heads/twin"), (other, "refs/heads/main"),
            (head, "refs/tags/light"), (tag, "refs/tags/annotated"), (head, "refs/tags/annotated^{}"),
            (tag, "refs/tags/elsewhere"), (other, "refs/tags/elsewhere^{}")))
        names, tags = guard.refs_at_head(advertised, head)
        self.assertEqual(names, ["refs/heads/topic", "refs/heads/twin", "refs/tags/annotated", "refs/tags/light"])
        self.assertEqual(tags, {"refs/tags/annotated": tag})
        with self.assertRaises(guard.PrivacyError):
            guard.refs_at_head("not-an-oid\trefs/heads/topic", head)

    def test_clean_twin_branch_cannot_pass_a_head_shared_with_a_denied_name(self):
        # Check runs belong to a commit: auditing the clean branch must still
        # fail while a denylisted branch name points at the same head.
        self.commit("clean.txt", b"clean", "clean change")
        head = self.oid()
        event = self.root / "event.json"
        event.write_text(json.dumps({"pull_request": {"head": {"sha": head, "ref": "clean-topic"}}}))
        env = dict(GITHUB_EVENT_PATH=str(event), GITHUB_EVENT_NAME="pull_request_target",
                   GITHUB_SHA=self.base, GITHUB_REPOSITORY="example/repository", HISTORY_PRIVACY_HMAC_KEY=KEY)
        real_git, real_scan = guard.git, guard.scan
        for twin, should_pass in (("other-topic", True), (REMOVED.decode(), False)):
            def fetch_fixture(repo, *args, **kwargs):
                if "ls-remote" in args:
                    lines = (head + "\trefs/heads/clean-topic", head + "\trefs/heads/" + twin,
                             self.base + "\trefs/heads/main")
                    return ("\n".join(lines) + "\n").encode()
                return b""
            def inspect_fixture(repo, policy, heads, excludes, refs):
                with patch.object(guard, "git", real_git):
                    return real_scan(self.repo, policy, heads, excludes, refs)
            with self.subTest(twin=twin), patch.dict(os.environ, env), \
                    patch.object(guard, "git", side_effect=fetch_fixture), \
                    patch.object(guard, "scan", side_effect=inspect_fixture), \
                    patch.object(guard, "api", return_value={"id": 123}) as api, \
                    contextlib.redirect_stdout(io.StringIO()):
                if should_pass:
                    guard.ci(self.policy_path)
                else:
                    with self.assertRaises(guard.PrivacyError):
                        guard.ci(self.policy_path)
                self.assertEqual(api.call_args_list[0].args[2]["head_sha"], head)
                self.assertEqual(api.call_args_list[-1].args[2]["conclusion"], "success" if should_pass else "failure")

    def test_incoming_program_is_never_executed(self):
        marker = self.root / "should-not-exist"
        program = "from pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\n"
        self.commit("incoming.py", program.encode(), "untrusted program fixture")
        self.inspect()
        self.assertFalse(marker.exists())

    def test_ci_failure_is_published_on_exact_pr_head(self):
        event = self.root / "event.json"
        head = "b" * 40
        event.write_text(json.dumps({"pull_request": {"head": {"sha": head, "ref": "topic"}}}))
        env = dict(GITHUB_EVENT_PATH=str(event), GITHUB_EVENT_NAME="pull_request_target",
                   GITHUB_SHA=self.base, GITHUB_REPOSITORY="example/repository",
                   HISTORY_PRIVACY_HMAC_KEY="")
        with patch.dict(os.environ, env), patch.object(guard, "api", return_value={"id": 123}) as api:
            with self.assertRaises(guard.PrivacyError):
                guard.ci(self.policy_path)
        self.assertEqual(api.call_args_list[0].args[2]["head_sha"], head)
        self.assertEqual(api.call_args_list[-1].args[2]["conclusion"], "failure")

    def test_git_subprocesses_do_not_inherit_key_or_token(self):
        with patch.dict(os.environ, HISTORY_PRIVACY_HMAC_KEY=KEY, GH_TOKEN="synthetic-api-token"):
            with patch.object(guard.subprocess, "run") as run:
                run.return_value.returncode = 0
                run.return_value.stdout = b"ok"
                guard.git(self.repo, "rev-parse", "HEAD")
        passed_env = run.call_args.kwargs["env"]
        self.assertNotIn("HISTORY_PRIVACY_HMAC_KEY", passed_env)
        self.assertNotIn("GH_TOKEN", passed_env)

    def test_only_fetches_receive_the_read_token_through_the_environment(self):
        token = "synthetic-read-token"
        env = dict(HISTORY_PRIVACY_HMAC_KEY=KEY, GH_TOKEN="synthetic-api-token", GH_READ_TOKEN=token,
                   GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="core.example", GIT_CONFIG_VALUE_0="inherited")
        with patch.dict(os.environ, env):
            with patch.object(guard.subprocess, "run") as run:
                run.return_value.returncode = 0
                run.return_value.stdout = b"ok"
                guard.git(self.repo, "rev-parse", "HEAD")
                plain = run.call_args
                guard.git(self.repo, "fetch", "origin", "a" * 40, fetch_auth=True)
                fetch = run.call_args
        for call in (plain, fetch):
            passed = call.kwargs["env"]
            for name in ("HISTORY_PRIVACY_HMAC_KEY", "GH_TOKEN", "GH_READ_TOKEN"):
                self.assertNotIn(name, passed)
            self.assertNotIn(token, " ".join(call.args[0]))
        self.assertFalse(any(key.startswith("GIT_CONFIG_") for key in plain.kwargs["env"]))
        header = base64.b64encode(("x-access-token:" + token).encode()).decode()
        self.assertEqual(fetch.kwargs["env"]["GIT_CONFIG_COUNT"], "1")
        self.assertEqual(fetch.kwargs["env"]["GIT_CONFIG_KEY_0"], "http.https://github.com/.extraheader")
        self.assertEqual(fetch.kwargs["env"]["GIT_CONFIG_VALUE_0"], "AUTHORIZATION: basic " + header)
        with patch.dict(os.environ, HISTORY_PRIVACY_HMAC_KEY=KEY):
            os.environ.pop("GH_READ_TOKEN", None)
            with patch.object(guard.subprocess, "run") as run:
                run.return_value.returncode = 0
                run.return_value.stdout = b"ok"
                guard.git(self.repo, "fetch", "origin", "a" * 40, fetch_auth=True)
        self.assertNotIn("GIT_CONFIG_COUNT", run.call_args.kwargs["env"])


if __name__ == "__main__":
    unittest.main()
