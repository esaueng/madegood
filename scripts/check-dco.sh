#!/usr/bin/env bash
# Checks that every non-merge commit in BASE..HEAD carries a
# "Signed-off-by: <author name> <author email>" trailer (DCO 1.1).
# Bot authors (…[bot]) are exempt. Usage: scripts/check-dco.sh BASE HEAD
set -euo pipefail

base="${1:?usage: check-dco.sh BASE HEAD}"
head="${2:?usage: check-dco.sh BASE HEAD}"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Resolve the range first so an unknown revision fails the check instead of
# silently yielding zero commits.
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "Unknown base revision: $base"; exit 2; }
git rev-parse --verify --quiet "$head^{commit}" >/dev/null || { echo "Unknown head revision: $head"; exit 2; }
shas=$(git rev-list --no-merges "$base..$head")

failed=0
checked=0
for sha in $shas; do
  checked=$((checked + 1))
  name=$(git show -s --format='%an' "$sha")
  email=$(git show -s --format='%ae' "$sha")
  subject=$(git show -s --format='%s' "$sha")

  case "$email" in
    *'[bot]@users.noreply.github.com') echo "skip  ${sha:0:12} (bot: $name)"; continue ;;
  esac

  expected=$(lower "Signed-off-by: $name <$email>")
  found=0
  while IFS= read -r line; do
    line="${line%$'\r'}"
    if [ "$(lower "$line")" = "$expected" ]; then
      found=1
      break
    fi
  done < <(git show -s --format='%(trailers:key=Signed-off-by,unfold=true)' "$sha")

  if [ "$found" -eq 1 ]; then
    echo "ok    ${sha:0:12} $subject"
  else
    echo "FAIL  ${sha:0:12} $subject"
    echo "      expected trailer: Signed-off-by: $name <$email>"
    failed=$((failed + 1))
  fi
done

echo "Checked $checked commit(s)."
if [ "$failed" -gt 0 ]; then
  cat <<'MSG'

Some commits are missing a DCO sign-off that matches the commit author.
Fix the last commit:   git commit --amend -s --no-edit
Fix all commits:       git rebase --signoff origin/main
Then force-push your branch. See CONTRIBUTING.md.
MSG
  exit 1
fi
