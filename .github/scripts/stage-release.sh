#!/usr/bin/env bash
# Stages release assets for one source (the matrix of a per-source workflow).
# Env in:  MATRIX (json array, single source)
# Outputs (GITHUB_OUTPUT): publish, name, tag, prerelease, latest_tag,
#                          assets_dir, latest_dir, notes, latest_notes
set -euo pipefail

: "${MATRIX:?}"
DIST=dist
[[ -d "$DIST" ]] || { echo "no $DIST/ directory (no artifacts downloaded?)" >&2; exit 1; }

name=$(jq -r '.[0].name' <<< "$MATRIX")
tag=$(jq -r '.[0].tag' <<< "$MATRIX")
prerelease=$(jq -r '.[0].prerelease' <<< "$MATRIX")
repo=$(jq -r '.[0].repo' <<< "$MATRIX")
ref=$(jq -r '.[0].ref' <<< "$MATRIX")
sha=$(jq -r '.[0].sha' <<< "$MATRIX")

echo "=== staging $name ($tag) ==="

# All-or-nothing: every asset in the matrix must exist.
ok=1
while IFS= read -r asset; do
  if [[ ! -f "$DIST/$asset" ]]; then
    echo "missing asset: $asset" >&2
    ok=0
  fi
done < <(jq -r '.[].asset' <<< "$MATRIX")

if [[ "$ok" != "1" ]]; then
  echo "publish=false" >> "$GITHUB_OUTPUT"
  echo "not all assets present for $name; skipping release"
  exit 0
fi

WORK="${RUNNER_TEMP:-/tmp}/release-$name"
rm -rf "$WORK"
mkdir -p "$WORK/assets" "$WORK/latest"
while IFS= read -r asset; do
  cp "$DIST/$asset" "$WORK/assets/$asset"
  stable="${name}-${asset#"${tag}"-}"
  cp "$DIST/$asset" "$WORK/latest/$stable"
done < <(jq -r '.[].asset' <<< "$MATRIX")

(cd "$WORK/assets" && jq -r '.[].asset' <<< "$MATRIX" | xargs sha256sum > SHA256SUMS)

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
    ubuntu=$(jq -r --arg a "$asset" '.[] | select(.asset == $a) | .ubuntu' <<< "$MATRIX")
    cuda=$(jq -r --arg a "$asset" '.[] | select(.asset == $a) | .cuda' <<< "$MATRIX")
    sum=$(sha256sum "$WORK/assets/$asset" | awk '{print $1}')
    [[ "$first" == "1" ]] && first=0 || echo ','
    printf '    {"name": "%s", "ubuntu": "%s", "cuda": "%s", "sha256": "%s"}' "$asset" "$ubuntu" "$cuda" "$sum"
  done < <(jq -r '.[].asset' <<< "$MATRIX")
  echo
  echo '  ]'
  echo '}'
} > "$WORK/assets/manifest.json"

cat > "$WORK/notes.md" <<EOF
Automated sm_75 CUDA build of \`$repo\` @ \`$sha\` (\`$ref\`).

- Arch: sm_75 (75-real); static cudart; dynamic cuBLAS/cuBLASLt by major soname
- \`GGML_CUDA_FA_ALL_QUANTS=OFF\`
- Requires: NVIDIA driver >= 525 (CUDA 12.x) and the CUDA toolkit libraries registered in the loader cache (\`libcublas.so.12\`, \`libcublasLt.so.12\`). See \`check-runtime.sh\` in the archive.
EOF

cat > "$WORK/latest-notes.md" <<EOF
Rolling latest build of \`$repo\` @ \`$sha\` (\`$ref\`), built $(date -u +%Y-%m-%d).

Assets are replaced on each successful build. Marked pre-release so it never takes the repo-wide "Latest" flag.
EOF

{
  echo "publish=true"
  echo "name=$name"
  echo "tag=$tag"
  echo "prerelease=$prerelease"
  echo "latest_tag=${name}-latest"
  echo "assets_dir=$WORK/assets"
  echo "latest_dir=$WORK/latest"
  echo "notes=$WORK/notes.md"
  echo "latest_notes=$WORK/latest-notes.md"
} >> "$GITHUB_OUTPUT"
