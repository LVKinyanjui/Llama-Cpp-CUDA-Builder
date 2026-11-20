#!/usr/bin/env bash
# Resolves the build matrix for the CUDA sm_75 release pipeline.
#
# Env in:  GH_TOKEN, SOURCE (all|llama-cpp|turboquant), REF (optional), FORCE (true|false)
# Env out: matrix=<json array> appended to $GITHUB_OUTPUT
set -euo pipefail

SOURCE="${SOURCE:-all}"
REF="${REF:-}"
FORCE="${FORCE:-false}"

# Targets to build. Phase 1 & 2: Kaggle (Ubuntu 22.04 + CUDA 12.8) and Colab (Ubuntu 24.04 + CUDA 13.0).
TARGETS=(
  "22.04:12.8:12-8:ubuntu:22.04"
  "24.04:13.0:13-0:"
)

case "$SOURCE" in
  all|llama-cpp|turboquant) ;;
  *) echo "invalid SOURCE: $SOURCE (expected all|llama-cpp|turboquant)" >&2; exit 1 ;;
esac

resolve_sha() { # <repo> <ref> -> commit sha
  local repo="$1" ref="$2" sha
  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then echo "$ref"; return; fi
  sha=$(git ls-remote "https://github.com/$repo" "refs/tags/$ref^{}" | awk '{print $1}' | head -n1)
  [[ -z "$sha" ]] && sha=$(git ls-remote "https://github.com/$repo" "refs/tags/$ref" | awk '{print $1}' | head -n1)
  [[ -z "$sha" ]] && sha=$(git ls-remote "https://github.com/$repo" "refs/heads/$ref" | awk '{print $1}' | head -n1)
  [[ -z "$sha" ]] && sha=$(git ls-remote "https://github.com/$repo" "$ref" | awk '{print $1}' | head -n1)
  [[ -z "$sha" ]] && sha=$(gh api "repos/$repo/commits/$ref" --jq .sha)
  [[ -z "$sha" ]] && { echo "could not resolve $repo@$ref" >&2; exit 1; }
  echo "$sha"
}

# Resolve one source to (repo, ref, sha, tag, prerelease). Sets globals.
resolve_source() { # <name>
  local name="$1"
  case "$name" in
    llama-cpp)
      REPO="ggml-org/llama.cpp"
      if [[ -n "$REF" ]]; then
        REF_RESOLVED="$REF"
        SHA=$(resolve_sha "$REPO" "$REF")
        if [[ "$REF" =~ ^b[0-9]+$ ]]; then
          TAG="llama-cpp-$REF"; PRERELEASE=false
        elif [[ "$REF" =~ ^refs/pull/([0-9]+)/head$ ]]; then
          TAG="llama-cpp-pr${BASH_REMATCH[1]}-${SHA:0:7}"; PRERELEASE=true
        else
          TAG="llama-cpp-${SHA:0:7}"; PRERELEASE=true
        fi
      else
        # bNNNN tags are prereleases; releases/latest returns v1.0.0, so list and filter.
        REF_RESOLVED=$(gh api "repos/$REPO/releases?per_page=30" --jq '[.[] | select(.tag_name | test("^b[0-9]+$"))][0].tag_name')
        [[ -z "$REF_RESOLVED" || "$REF_RESOLVED" == "null" ]] && { echo "no bNNNN release found for $REPO" >&2; exit 1; }
        SHA=$(resolve_sha "$REPO" "$REF_RESOLVED")
        TAG="llama-cpp-$REF_RESOLVED"; PRERELEASE=false
      fi
      ;;
    turboquant)
      REPO="TheTom/llama-cpp-turboquant"
      if [[ -n "$REF" ]]; then
        REF_RESOLVED="$REF"
        SHA=$(resolve_sha "$REPO" "$REF")
        if [[ "$REF" =~ ^refs/pull/([0-9]+)/head$ ]]; then
          TAG="turboquant-pr${BASH_REMATCH[1]}-${SHA:0:7}"; PRERELEASE=true
        else
          TAG="turboquant-${SHA:0:7}"; PRERELEASE=true
        fi
      else
        REF_RESOLVED=$(gh api "repos/$REPO" --jq .default_branch)
        SHA=$(git ls-remote "https://github.com/$REPO" "refs/heads/$REF_RESOLVED" | awk '{print $1}' | head -n1)
        [[ -z "$SHA" ]] && { echo "could not resolve $REPO default branch $REF_RESOLVED" >&2; exit 1; }
        local cdate day
        cdate=$(gh api "repos/$REPO/commits/$SHA" --jq .commit.committer.date)
        day=$(date -u -d "$cdate" +%Y%m%d)
        TAG="turboquant-${day}-${SHA:0:7}"; PRERELEASE=false
      fi
      ;;
  esac
}

ENTRIES=()
for name in llama-cpp turboquant; do
  [[ "$SOURCE" != "all" && "$SOURCE" != "$name" ]] && continue
  resolve_source "$name"

  if gh release view "$TAG" >/dev/null 2>&1 && [[ "$FORCE" != "true" ]]; then
    echo "skip: release $TAG already exists (use force=true to rebuild)"
    continue
  fi

  for target in "${TARGETS[@]}"; do
    IFS=: read -r ubuntu cuda cuda_mm container <<< "$target"
    # Append short SHA to asset name to prevent clobbering
    asset="${TAG}-${SHA:0:7}-bin-ubuntu${ubuntu}-x64-cuda${cuda}-sm75.tar.gz"
    ENTRIES+=("$(jq -nc \
      --arg name "$name" --arg repo "$REPO" --arg sha "$SHA" --arg ref "$REF_RESOLVED" \
      --arg tag "$TAG" --argjson prerelease "$PRERELEASE" \
      --arg ubuntu "$ubuntu" --arg cuda "$cuda" --arg cuda_mm "$cuda_mm" \
      --arg container "$container" --arg asset "$asset" \
      '{name:$name, repo:$repo, sha:$sha, ref:$ref, tag:$tag, prerelease:$prerelease,
        ubuntu:$ubuntu, cuda:$cuda, cuda_mm:$cuda_mm, container:$container, asset:$asset}')")
  done
done

# If release exists, check if all assets exist. If so, skip.
if [[ "$FORCE" != "true" && "$(gh release view "$TAG" --json assets --jq '.assets[].name' 2>/dev/null)" ]]; then
  echo "release $TAG exists. checking for missing assets..."
  MISSING_ASSETS=()
  for row in $(jq -r '.[] | @base64' <<< "$MATRIX"); do
    _jq() { echo "${row}" | base64 --decode | jq -r "${1}"; }
    asset=$(_jq '.asset')
    if ! gh release view "$TAG" --json assets --jq ".assets[].name" | grep -q "^$asset$"; then
      MISSING_ASSETS+=("$asset")
    fi
  done
  if [[ ${#MISSING_ASSETS[@]} -eq 0 ]]; then
    echo "all assets exist for release $TAG. skipping."
    MATRIX='[]'
  else
    echo "missing assets: ${MISSING_ASSETS[*]}. rebuilding."
  fi
fi

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
  MATRIX='[]'
else
  MATRIX=$(printf '%s\n' "${ENTRIES[@]}" | jq -cs .)
fi
echo "matrix=$MATRIX" >> "$GITHUB_OUTPUT"
echo "matrix: $MATRIX"
