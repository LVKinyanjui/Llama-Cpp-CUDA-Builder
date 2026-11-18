#!/usr/bin/env bash
# Keeps the last 8 immutable releases for one source (excludes <name>-latest).
# Env in: GH_TOKEN, NAME (source name, e.g. llama-cpp)
set -euo pipefail

: "${NAME:?}"
KEEP=8

mapfile -t old < <(gh release list --limit 100 --json tagName,createdAt \
  --jq "[.[] | select(.tagName | startswith(\"${NAME}-\")) | select(.tagName != \"${NAME}-latest\")] | sort_by(.createdAt) | reverse | .[${KEEP}:] | .[].tagName")

for t in "${old[@]}"; do
  echo "pruning old release $t"
  gh release delete "$t" --yes --cleanup-tag
done
