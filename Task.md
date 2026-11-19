# Task: CUDA sm_75 release pipeline for llama.cpp and TurboQuant

Living progress tracker for this repo. Read at the start of each major task; update at reasonable milestones. The design spec is `CUDA sm_75 release pipeline for llama.cpp and TurboQuant.md` — keep the two in sync.

## Goal

GitHub Actions workflow(s) that build sm_75 CUDA binaries of llama.cpp and TurboQuant for the two runtimes, package them, and publish one immutable release per (source, ref) plus rolling `-latest` releases.

- **Kaggle (first deliverable):** Ubuntu 22.04 + CUDA 12.8, built in an `ubuntu:22.04` container.
- **Colab (second):** Ubuntu 24.04 + CUDA 13.0, built on `ubuntu-24.04`.

## Settled decisions (2026-11-18)

- Repo `LVKinyanjui/Llama-Cpp-CUDA-Builder`: public, default branch `main`, not a fork, no license yet (deferred).
- Both sources: upstream `ggml-org/llama.cpp` (latest `bNNNN` **prerelease** tag — `releases/latest` returns `v1.0.0`, so query the releases API for the newest `bNNNN`) and `TheTom/llama-cpp-turboquant` (HEAD of `feature/turboquant-kv-cache`, resolved via API, never hard-coded).
- First deliverable includes the full pipeline: twice-weekly poller (Mon/Thu 04:17 UTC) + `workflow_dispatch` (`source`/`ref`/`force`), idempotency by tag, all-or-nothing release, checksums + `manifest.json`, rolling `llama-cpp-latest` / `turboquant-latest`, restore-only `warm` job, prune to **8** immutable releases per source.
- `GGML_CUDA_FA_ALL_QUANTS=OFF` initially (rapid prototyping); flip to `ON` in Phase 3 — required for TurboQuant's turbo4 K / turbo3 V (not in the default FA kernel set). Plain llama.cpp has no turbo types.
- No HF mirror — GitHub assets are sufficient.
- `ggml-org/ccache-action`, pinned by full commit SHA (upstream CI uses it as `@v1.2.24`; it is a fork of `hendrikmuhs/ccache-action`).
- Live-run validation via authenticated `gh` CLI (`repo` + `workflow` scopes): `gh run list`, `gh run view <id> --log`, `gh run watch <id>` (poll, don't block). No MCP server needed.
- Loose TDD: verification gates first; validate layer by layer (scripts → workflow → live run) before relying on it.
- Target model for functional testing: `Qwen3.8-27B-GSQ-RCO-IQ2_S-mtp.gguf` from `ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF` (9.26 GB, arch `qwen35`, hybrid SSM/attention, MTP head `blk.64`). GSQ-RCO assigns **standard** GGUF quant types per tensor — no compile-time weight-quant selection exists or is needed; runs unmodified in llama.cpp.
- Five targets: `llama-server llama-cli llama-bench llama-quantize llama-perplexity`.
- Linking: **dynamic cudart/cuBLAS/cuBLASLt by major soname** (static cudart + dynamic cuBLAS is not viable — `libcublas.so.12` NEEDs `libcudart.so.12`; ggml links `CUDA::cudart` shared by default); nothing from NVIDIA bundled; `CMAKE_CUDA_ARCHITECTURES=75-real`; `GGML_NATIVE=OFF`; `BUILD_SHARED_LIBS=OFF`; `-static-libgcc -static-libstdc++ -s` (symbols stripped — smaller archives).
- **Two workflows, one per source** (`cuda-t4-release-llama-cpp.yml`, `cuda-t4-release-turboquant.yml`), sharing `.github/scripts/` — each source iterates independently. Each: twice-weekly cron + `workflow_dispatch` (`ref`, `force`).
- **Releases published with `softprops/action-gh-release`** (v3.0.4, SHA `8a0cd651e5b2365bd640854a3fa5dfc70e4875f3`) — the de-facto canonical action. Shell keeps only: all-or-nothing check, `SHA256SUMS`/`manifest.json` generation, rolling `-latest` asset renaming, pruning (`prune-releases.sh`).
- **Web UI (per source):** llama-cpp uses the HF prebuilt UI (`LLAMA_BUILD_UI=OFF`, `LLAMA_USE_PREBUILT_UI=ON`, no npm — upstream's refactored UI embedding matches the current `latest` bucket); turboquant builds the UI from source with npm (`LLAMA_BUILD_UI=ON`, `LLAMA_USE_PREBUILT_UI=OFF`, node 22 via `actions/setup-node` with `cache: npm`) — the fork's old `embed.cpp` requires `workbox[hash].js`, which the current `latest` bucket no longer ships.

## Milestones

### Phase 0 — confirm the unknowns

- [x] Runtime check: both runtimes register `libcudart`, `libcublas`, `libcublasLt` in the loader cache (done before this task)
- [x] TurboQuant default branch `feature/turboquant-kv-cache`, HEAD `4185b90` (2026-11-11); ships `src/models/qwen35.cpp` (verified via contents API — code search is stale)
- [x] Upstream supports `qwen35` (`src/models/qwen35.cpp`); `bNNNN` tags are prereleases (latest `b12503`, 2026-11-18); `v1.0.0` (2026-11-13) is stable "latest"
- [x] `GGML_CCACHE=ON` (default) sets `RULE_LAUNCH_COMPILE=ccache` **globally** (covers CUDA) — caused a double `ccache ccache nvcc`; fixed with `GGML_CCACHE=OFF` + explicit `CMAKE_C/CXX/CUDA_COMPILER_LAUNCHER=ccache`
- [x] `ggml-org/ccache-action` exists; kept per decision, pin by SHA
- [x] Upstream CUDA CI installs `libgomp1`; notes `GGML_CUDA_CCCL_VERSION=v3.4.3` may be needed for CTK < 13.5
- [x] Exact apt package names for CUDA 12.8 (`ubuntu2204`) and 13.0 (`ubuntu2404`) — verified in NVIDIA's apt repo 2026-11-18
- [x] `GGML_CUDA_CCCL_VERSION` not needed by default (fork uses opt-in `GGML_CUDA_CUB_3DOT2` → CCCL v3.2.0 FetchContent); revisit only if configure fails
- [ ] ccache-action entry naming/save behavior; per-cell `max-size`; measure real cache sizes
- [ ] TurboQuant build flags review (`cmake -LH`)
- [ ] Runtimes' CPU flags (`GGML_AVX2`/`GGML_FMA`/`GGML_F16C`)

### Phase 1 — Kaggle deliverable (first milestone)

- [x] Scaffold: `.github/workflows/cuda-t4-release.yml`, `.github/scripts/{plan,install-cuda,package,release}.sh`, `check-runtime.sh`, `BUILD_INFO.json` (generated by `package.sh`)
- [x] `plan.sh`: resolve sources → SHAs (`git ls-remote` + releases API for newest `bNNNN`), idempotency by release existence (skip if release exists, unless `force`), emit matrix JSON
- [x] `build` job: `ubuntu:22.04` container; install `git build-essential cmake ninja-build ccache libssl-dev jq libgomp1`; CUDA 12.8 via NVIDIA network repo (minimal packages); ccache; configure (`75-real`, `FA_ALL_QUANTS=OFF`, dynamic cudart/cuBLAS); build the five targets
- [x] Verification gates: `ldd` — no `not found` except driver-provided `libcuda.so.1`, needed CUDA sonames exactly `libcudart.so.12` + `libcublas.so.12` + `libcublasLt.so.12`; `cuobjdump --list-elf` — only `sm_75`; `llama-server --version` / `llama-cli --version` warn-only (driver absent on GPU-less runners); archive size within expected range
- [x] `package.sh`: tar + `LICENSE` + `BUILD_INFO.json` + `check-runtime.sh` → `dist/`
- [x] `release` job: download artifacts; all-or-nothing per source; `SHA256SUMS` + `manifest.json`; immutable release + rolling `-latest` via `softprops/action-gh-release`; prune to 8 (`prune-releases.sh`)
- [ ] `warm` job: restore-only for sources with nothing new (not yet implemented — see note below)
- [x] Live-run validation via `gh` CLI — both workflows green (runs 44317051305, 44317061640, 44320495564, 44320504399). Releases published: `llama-cpp-b12503` (155 MB), `turboquant-20261111-4185b90` (266 MB), plus rolling `llama-cpp-latest` / `turboquant-latest` pre-releases. ccache effective (rebuilds ~3–4 min). `-s` stripping barely reduced size (CUDA fatbin dominates); archive cap raised to 500 MB.
- [ ] Kaggle T4 functional test: download archive, run `check-runtime.sh`, run `Qwen3.8-27B-GSQ-RCO-IQ2_S-mtp.gguf` (turbo5 K / turbo3 V or f16 KV — turbo4 K / turbo3 V needs Phase 3)
- [x] **Web UI re-enabled after initial verification** — per source: llama-cpp uses the HF prebuilt UI (no npm); turboquant builds from source with npm (node 22, `cache: npm`). Verify `llama-server` serves the UI on the T4 (pending Kaggle test).

### Phase 2 — Colab target

- [ ] Ubuntu 24.04 + CUDA 13.0 cell (no container); verify on a Colab T4; tune cache keys

### Phase 3 — validatable binaries

- [ ] Flip `GGML_CUDA_FA_ALL_QUANTS=ON`; T4 test: `llama-bench -fa 1 -ctk turbo4 -ctv turbo3`; serve test with those cache types + flash attention

### Phase 4 — hardening

- [ ] SHA-pin all actions + Dependabot; keep-alive (scheduled workflows disable after 60 days idle); failure notifications; build-provenance attestation (optional)

## Verification log

- 2026-11-18 — Phase 0 research via `gh` API + Hugging Face (full details in design doc §3, "Verified 18 Nov 2026"). Repo confirmed public, default branch `main`, no license (deferred). `gh` CLI authenticated as `LVKinyanjui` with `repo` + `workflow` scopes. Design doc updated to the clarified spec (Kaggle-first, `FA_ALL_QUANTS=OFF` initially, no HF mirror, keep 8, `ggml-org/ccache-action`, `bNNNN` tracking, `gh`-based live-run validation).
- 2026-11-18 — First green runs. Fixes applied across iterations: `CUDA_HOME` path (dotted, not `cuda_mm`); `cuobjdump` via `$CUDA_HOME/bin`; Gate 1 allows driver-provided `libcuda.so.1` missing; Gate 3 (`--version`) warn-only; dynamic cudart/cuBLAS/cuBLASLt (static cudart + dynamic cuBLAS not viable — `libcublas.so.12` NEEDs `libcudart.so.12`); `-s` strip; archive cap 500 MB; two per-source workflows; `softprops/action-gh-release`. Releases: `llama-cpp-b12503`, `turboquant-20261111-4185b90`, rolling `-latest` pre-releases.
- 2026-11-18 — `tools/` gitignored and untracked (binaries must not enter version control); local validation tools documented in `README.md` (shellcheck 0.11.0, jq 1.8.2, actionlint 1.7.12, with SHA-256 hashes). Repo convention added: decide deliberately whether any new tool/dependency belongs in VCS. Initial push to `origin/main` completed (`ac1fb79`).
- 2026-11-18 — Phase 0 network checks done: NVIDIA apt repo has `cuda-compiler-12-8` / `cuda-libraries-dev-12-8` / `cuda-cuobjdump-12-8` / `cuda-nvml-dev-12-8` (ubuntu2204) and `cuda-compiler-13-0` / `cuda-libraries-dev-13-0` / `cuda-cuobjdump-13-0` / `cuda-nvml-dev-13-0` (ubuntu2404); `cuda-keyring_1.1-1_all.deb` exists for both distros. `cuda-nvml-dev-MM` added to `install-cuda.sh` (upstream b12534 includes `<nvml.h>` unconditionally). Action SHAs pinned: checkout v7.0.1 `3d3c42e`, upload-artifact v7.0.2 `cf430e0`, download-artifact v8.0.2 `9000827`, ggml-org/ccache-action v1.2.24 `f09c25b`. `GGML_CUDA_CCCL_VERSION` not needed by default (fork uses opt-in `GGML_CUDA_CUB_3DOT2` → CCCL v3.2.0 FetchContent); revisit only if configure fails. Embedded `tools/` (shellcheck 0.11.0, jq 1.8.2, actionlint 1.7.12) for local validation.

## Notes (2026-11-18, second round)

- **Web UI is required.** Dropped for the initial build only; it MUST be present in subsequent builds after initial verification. The TurboQuant fork's `embed.cpp` requires `workbox[hash].js`, which the current HF `latest` UI bucket no longer ships (fork is ~7 days behind upstream), so the HF-download path fails. Plan: build the UI from source with npm (`LLAMA_BUILD_UI=ON`, `LLAMA_USE_PREBUILT_UI=OFF`, node installed in the build job) for both sources; verify `llama-server` serves the UI on the T4.
- **Canonical release approach (confirmed 2026-11-18).** `softprops/action-gh-release` (v3.0.4, commit `8a0cd651e5b2365bd640854a3fa5dfc70e4875f3`, 5.8k stars, actively maintained) is the de-facto standard for creating GitHub releases from a workflow: creates the release if missing, uploads assets, overwrites by default, handles `prerelease`/`body`/tag creation. Upstream llama.cpp uses a custom forked action + REST API (not a model to copy). The `gh` CLI is supported but reimplements create-or-update/clobber/notes orchestration. The release job now uses `softprops/action-gh-release` (SHA-pinned); shell keeps only the all-or-nothing check, `SHA256SUMS`/`manifest.json` generation, rolling `-latest` asset renaming, and pruning.
- **Separate build processes per source (confirmed 2026-11-18).** Split the single matrix workflow into two workflow files — `cuda-t4-release-llama-cpp.yml` and `cuda-t4-release-turboquant.yml` — sharing `.github/scripts/`, so each source can be iterated on independently (different flags, UI handling, schedules).

## Open questions

- None blocking. See design doc §15.

## Notes

- The `warm` job (restore-only ccache for sources with nothing new) is designed but not yet implemented; the twice-weekly cadence keeps caches inside the 7-day eviction window for sources that build, but a skipped source's cache can still age out. Add in Phase 1 follow-up or Phase 4.
