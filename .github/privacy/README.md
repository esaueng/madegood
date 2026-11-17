# Privacy checks

Two required checks keep private information out of MadeGood's history. Both
are published by the **Esau History Privacy** GitHub App from one protected job,
`.github/workflows/history-privacy.yml`.

| Check | Looks at | Fails when |
|---|---|---|
| `history-privacy` | Every new commit, tree, blob, annotated tag and branch/tag name, including files deleted again before the tip | A value on the operator's private denylist appears anywhere, in any letter case |
| `commit-privacy` | Author and committer of every new commit | An identity is not a GitHub noreply address or an approved bot, or the protected account uses anything but its own noreply |

They back up the local `git-privacy-guard` hooks, which stay the first line of
defence: CI runs after GitHub already has the push, so it blocks the merge but
cannot retract a pushed branch. They also cover commits that never pass through
those hooks (GitHub web edits, cloud agents, bots). Neither check looks for
general secrets such as API keys.

## Denylist fingerprints

The denylist itself is never committed. `policy.json` holds, for each entry,
its length and HMAC-SHA256 fingerprints of the lower-cased value and of its
first two bytes. The 256-bit key is the `history-privacy` environment secret
`HISTORY_PRIVACY_HMAC_KEY`, used only by this repository. The scanner recovers
the two-byte prefixes in memory to find candidate offsets and compares full
values by HMAC only. Failures never print the value, path or object ID.

`baseline` is an audited clean commit. Pull requests are scanned from the
baseline to their head, so earlier commits on a branch cannot hide behind a
clean tip. Because a check run belongs to a commit, not a branch, a PR audit
also checks the name of every branch and tag (and every annotated tag object)
pointing at the same head; a clean twin branch cannot overwrite a failure.
Pushes to `main`, the daily run and a plain manual dispatch scan every branch
and tag in full, and `commit-privacy` then checks identities on all of them,
since unmerged branches become public with the repository.

## Trust boundary

- Every trigger (`pull_request_target`, `push` to `main`, `schedule`,
  `workflow_dispatch`) runs the workflow and scanner as they exist on `main`;
  the scanner is checked out at `github.workflow_sha`, never the PR head. A PR
  that edits the scanner is audited by the current one.
- The `history-privacy` environment releases its secrets to `main` only.
- Incoming objects are fetched into a fresh bare repository as data. Nothing is
  checked out, built or executed. Git subprocesses get no key or App token;
  only `git fetch` gets the job's read-only `GITHUB_TOKEN`, through Git's
  environment configuration, because this repository is private.
- `pull_request_target` runs on the base commit, so the job publishes both
  checks on the exact PR head through the App. Branch protection must bind both
  checks to that App: a check with the same name from any other source, such as
  a workflow on a PR branch, does not satisfy it.

## Setup

1. Install the Esau History Privacy App on this repository (checks: write,
   metadata: read).
2. Create the `history-privacy` environment with deployment branches limited to
   `main`. Add environment secrets `HISTORY_PRIVACY_HMAC_KEY` and
   `HISTORY_PRIVACY_APP_PRIVATE_KEY`, and repository variable
   `HISTORY_PRIVACY_APP_CLIENT_ID`.
3. After the first App-published run passes on `main`, require
   `history-privacy` and `commit-privacy` from the App on `main`.

Merge queues are not supported: candidates would never receive these checks.

## Changing the policy

- **Denylist entries:** regenerate `policy.json` locally from the private
  denylist with the current key. Never commit plaintext values or unkeyed hashes.
- **Key rotation:** regenerate every fingerprint and `verification_digest` with
  the new key, then replace the secret. Rotating only the secret makes every
  run fail.
- **Approved identities:** edit `PROTECTED_LOGINS`, `PUBLIC_DISPLAY_NAMES` or
  the bot tables in `commit_privacy.py`. Public handles only.

## Tests

```sh
python3 -m unittest discover -s .github/privacy -p 'test_*.py'
```

They use synthetic identifiers and throwaway repositories, need no key, and run
in `privacy-tests.yml` on changes to these files. A local full-history audit:
`HISTORY_PRIVACY_HMAC_KEY=… python3 .github/privacy/history_privacy.py --repo . --full --head <sha>`.
