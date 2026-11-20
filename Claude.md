u # Claude.md — how to work on this project

**Read this first.** This file is the working guide for any agent (human or AI) contributing to `Llama-Cpp-CUDA-Builder`. It defines the protocol and conventions for working on the repo. For *what* we are building, see `CUDA sm_75 release pipeline for llama.cpp and TurboQuant.md` (the design spec) and `Task.md` (the living progress tracker). Keep all three in sync.

## Reporting protocol (mandatory)

1. **Before any `git add` / `git commit` / `git push`, tell the user what you have done and what you are about to do**, and wait for approval. Never push first and report after. This exists so mistakes (e.g. pushing large binaries to GitHub) are caught before they land.
2. **Flag consequential factors explicitly in every approval report.** At minimum, call out:
   - dependency pull size and build-time impact (e.g. `npm ci` pulling hundreds of MB, added minutes per build)
   - network dependencies introduced (npm registry, HF bucket, NVIDIA apt repo, …)
   - cache behavior (what is cached, what is not, expected hit rates)
   - archive size, runner minutes, and anything else that could surprise the user later
   - "what does this cost and what does it depend on" is a required section of every report.
3. **Do not commit large binaries or vendored dependencies.** When adding any tool or dependency, decide deliberately whether it belongs in version control. If it is large, a binary, or easily re-downloadable, gitignore it and document how to obtain it instead. `tools/` is gitignored for this reason.
4. **Loose TDD:** verification gates first; validate layer by layer (scripts → workflow → live run) before relying on anything.

## Validation

- Local validation tools live in `tools/` (gitignored, not committed): `shellcheck.exe`, `jq.exe`, `actionlint.exe`. See `README.md` for versions, hashes, and download URLs.
- Run `tools/shellcheck.exe` on shell scripts and `tools/actionlint.exe` on workflow YAML before committing.
- Shell scripts and workflow YAML use LF line endings (enforced by `.gitattributes`).
- Live-run validation uses the authenticated `gh` CLI (`repo` + `workflow` scopes): `gh run list`, `gh run view <id> --log`, `gh run watch <id>` (poll, don't block). No MCP server needed.

## Workflow procedure & release gotchas (mandatory)

1. **Rebuilding or Adding Matrix Targets (`force=true`)**: `plan.sh` checks if the release tag (`$TAG`) already exists. If it exists and `force` is `false`, it skips the source. If you add a new target (e.g. adding Ubuntu 24.04 / CUDA 13.0) to an existing tag/commit, you **must** pass `force=true` on manual dispatch, otherwise `plan.sh` returns `[]` and nothing builds.
2. **Scheduled Biweekly Runs**: Scheduled runs evaluate the latest upstream commit/tag and safely skip if no new upstream tag/commit exists (idempotent, preventing wasted runner minutes).
3. **Reproducible "Time Travel" Releases**: To build and release binaries corresponding to specific historical commits or tags, pass the specific ref or SHA via `workflow_dispatch` input (`ref`) along with `force=true`. Rerunning a failed/completed workflow run via `gh run rerun` reuses existing artifacts if available, but for building specific past commits, use `workflow_dispatch` with `ref` and `force=true`.

- Default branch `main`; public repo; no license yet (deferred).
- Two workflows, one per source: `cuda-t4-release-llama-cpp.yml`, `cuda-t4-release-turboquant.yml`, sharing `.github/scripts/`.
- Releases are published with `softprops/action-gh-release` (SHA-pinned); shell keeps only the all-or-nothing check, `SHA256SUMS`/`manifest.json`, rolling `-latest` renaming, and pruning.
- `Task.md` is the living progress tracker: read it at the start of each major task; update it at reasonable milestones.
- The design doc is the spec; keep it in sync with `Task.md`.

## Commit style

- Subject ≤ 50 chars, imperative mood, no trailing period, capitalized.
- Body only when it adds useful information; wrap at 72 chars; don't repeat the subject.
- Do not commit unless the user asks; do not create branches unless the user asks.

## Key project facts (see the design doc for detail)

- Targets: Ubuntu 22.04 + CUDA 12.8 (Kaggle, first deliverable) and Ubuntu 24.04 + CUDA 13.0 (Colab, second).
- Sources: `ggml-org/llama.cpp` (latest `bNNNN` prerelease) and `TheTom/llama-cpp-turboquant` (HEAD of `feature/turboquant-kv-cache`).
- Linking: dynamic cudart/cuBLAS/cuBLASLt by major soname; nothing from NVIDIA bundled.
- `GGML_CUDA_FA_ALL_QUANTS=OFF` initially; `ON` in the validatable-binaries phase (needed for turbo4 K / turbo3 V).
- Web UI: built from source with npm for TurboQuant; HF prebuilt for llama.cpp (see design doc §15).
