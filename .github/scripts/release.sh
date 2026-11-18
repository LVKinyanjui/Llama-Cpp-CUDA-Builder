#!/usr/bin/env bash
# Publishes one immutable release per source (only if all of the source's
# assets exist), refreshes the rolling <name>-latest release, and prunes old
# immutable releases (keep last 8 per source).
# Env in: GH_TOKEN, MATRIX (json array from the plan job)
set -euo pipefail

: "${MATRIX:?}"
DIST=dist
[[ -d "$DIST" ]] || { echo "no $DIST/ directory (no artifacts downloaded?)" >&2; exit 1; }

KEEP=8
WORK_ROOT=$(mktemp -d)
trap 'rm -rf "$WORK_ROOT"' EXIT

names=$(jq -r '.[].name' <<< "$MATRIX" | sort -u)
for name in $names; do
  entries=$(jq -c --arg n "$name" '[.[] | select(.name == $n)]' <<< "$MATRIX")
  tag=$(jq -r '.[0].tag' <<< "$entries")
  prerelease=$(jq -r '.[0].prerelease' <<< "$entries")
  repo=$(jq -r '.[0].repo' <<< "$entries")
  ref=$(jq -r '.[0].ref' <<< "$entries")
  sha=$(jq -r '.[0].sha' <<< "$entries")

  echo "=== $name ($tag) ==="

  # All-or-nothing: every asset in the matrix for this source must exist.
  ok=1
  while IFS= read -r asset; do
    if [[ ! -f "$DIST/$asset" ]]; then
      echo "missing asset: $asset" >&2
      ok=0
    fi
  done < <(jq -r '.[].asset' <<< "$entries")
  if [[ "$ok" != "1" ]]; then
    echo "skipping $name: not all assets present"
    continue
  fi

  work="$WORK_ROOT/$name"
  mkdir -p "$work"
  while IFS= read -r asset; do
    cp "$DIST/$asset" "$work/$asset"
  done < <(jq -r '.[].asset' <<< "$entries")

  (cd "$work" && jq -r '.[].asset' <<< "$entries" | xargs sha256sum > SHA256SUMS)

  # manifest.json: one per release, covering all assets of the source.
  {
    echo '{'
    echo "  \"source\": {\"name\": \"$name\", \"repo\": \"$repo\", \"ref\": \"$ref\", \"sha\": \"$sha\", \"url\": \"https://github.com/$repo/tree/$sha\"},"
    echo "  \"tag\": \"$tag\","
    echo "  \"prerelease\": $prerelease,"
    echo "  \"build_date_utc\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo '  "assets": ['
    first=1
    while IFS= read -r asset; do
      ubuntu=$(jq -r --arg a "$asset" '.[] | select(.asset == $a) | .ubuntu' <<< "$entries")
      cuda=$(jq -r --arg a "$asset" '.[] | select(.asset == $a) | .cuda' <<< "$entries")
      sum=$(sha256sum "$work/$asset" | awk '{print $1}')
      [[ "$first" == "1" ]] && first=0 || echo ','
      printf '    {"name": "%s", "ubuntu": "%s", "cuda": "%s", "sha256": "%s"}' "$asset" "$ubuntu" "$cuda" "$sum"
    done < <(jq -r '.[].asset' <<< "$entries")
    echo
    echo '  ]'
    echo '}'
  } > "$work/manifest.json"

  notes=$(cat <<EOF
Automated sm_75 CUDA build of \`$repo\` @ \`$sha\` (\`$ref\`).

- Arch: sm_75 (75-real); static cudart; dynamic cuBLAS/cuBLASLt by major soname
- \`GGML_CUDA_FA_ALL_QUANTS=OFF\`
- Requires: NVIDIA driver >= 525 (CUDA 12.x) and the CUDA toolkit libraries registered in the loader cache (\`libcublas.so.12\`, \`libcublasLt.so.12\`). See \`check-runtime.sh\` in the archive.
EOF
)

  prerelease_flag=()
  [[ "$prerelease" == "true" ]] && prerelease_flag=(--prerelease)

  if gh release view "$tag" >/dev/null 2>&1; then
    echo "release $tag exists; replacing assets"
    gh release upload "$tag" "$work"/* --clobber
    gh release edit "$tag" --notes "$notes" "${prerelease_flag[@]}"
  else
    gh release create "$tag" "$work"/* --title "$tag" --notes "$notes" "${prerelease_flag[@]}"
  fi

  # Rolling <name>-latest release with ref-less, stable asset names.
  latest="${name}-latest"
  latest_work="$WORK_ROOT/${name}-latest"
  mkdir -p "$latest_work"
  while IFS= read -r asset; do
    stable="${name}-${asset#"${tag}"-}"
    cp "$DIST/$asset" "$latest_work/$stable"
  done < <(jq -r '.[].asset' <<< "$entries")
  latest_notes=$(cat <<EOF
Rolling latest build of \`$repo\` @ \`$sha\` (\`$ref\`), built $(date -u +%Y-%m-%d).

Assets are replaced on each successful build. Marked pre-release so it never takes the repo-wide "Latest" flag.
EOF
)
  if gh release view "$latest" >/dev/null 2>&1; then
    gh release upload "$latest" "$latest_work"/* --clobber
    gh release edit "$latest" --notes "$latest_notes" --prerelease
  else
    gh release create "$latest" "$latest_work"/* --title "$latest" --notes "$latest_notes" --prerelease
  fi

  # Prune immutable releases: keep the last $KEEP per source (exclude <name>-latest).
  mapfile -t old < <(gh release list --limit 100 --json tagName,createdAt \
    --jq "[.[] | select(.tagName | startswith(\"${name}-\")) | select(.tagName != \"${latest}\")] | sort_by(.createdAt) | reverse | .[${KEEP}:] | .[].tagName")
  for t in "${old[@]}"; do
    echo "pruning old release $t"
    gh release delete "$t" --yes --cleanup-tag
  done
done
