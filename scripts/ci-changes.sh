#!/usr/bin/env bash
# Prints which CI areas a change touches, as GitHub Actions outputs:
#   waterkit=true|false  apple=true|false  web=true|false
# Reads the event from env (set by .github/workflows/ci.yml). Pushes to main, manual
# runs, and anything whose range can't be resolved run everything.
set -euo pipefail

all() { printf 'waterkit=true\napple=true\nweb=true\n'; exit 0; }

case "${EVENT:-}" in
  pull_request) base="${PR_BASE:-}"; head="${PR_HEAD:-}" ;;
  merge_group) base="${MQ_BASE:-}"; head="${MQ_HEAD:-}" ;;
  *) all ;;
esac
if [ -z "$base" ] || [ -z "$head" ] \
  || ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null \
  || ! git rev-parse --verify --quiet "$head^{commit}" >/dev/null; then
  all
fi

# --no-renames lists both sides of a move, so moving a file out of an area still
# triggers that area's checks.
files=$(git diff --name-only --no-renames "$base...$head")
echo "Changed files:" >&2
printf '  %s\n' $files >&2

matches() { printf '%s\n' "$files" | grep -Eq "$1" && echo true || echo false; }

# Changing CI itself runs everything.
if [ "$(matches '^(\.github/workflows/ci\.yml|scripts/ci-changes\.sh)$')" = true ]; then all; fi

echo "waterkit=$(matches '^(packages/WaterKit/|fixtures/|scripts/anonymize-track$)')"
# WaterKit tests and fixtures don't affect the apps; its package and sources do.
echo "apple=$(matches '^(apps/apple/|packages/WaterKit/(Package\.swift$|Sources/)|\.mise\.toml$|scripts/pick-simulator$)')"
echo "web=$(matches '^(web/|package\.json$|pnpm-lock\.yaml$|pnpm-workspace\.yaml$|biome\.json$|\.nvmrc$)')"
