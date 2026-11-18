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
- Linking: static cudart, dynamic cuBLAS/cuBLASLt by major soname; nothing from NVIDIA bundled; `CMAKE_CUDA_ARCHITECTURES=75-real`; `GGML_NATIVE=OFF`; `BUILD_SHARED_LIBS=OFF`; `-static-libgcc -static-libstdc++`.

## Milestones

### Phase 0 — confirm the unknowns

- [x] Runtime check: both runtimes register `libcudart`, `libcublas`, `libcublasLt` in the loader cache (done before this task)
- [x] TurboQuant default branch `feature/turboquant-kv-cache`, HEAD `4185b90` (2026-11-11); ships `src/models/qwen35.cpp` (verified via contents API — code search is stale)
- [x] Upstream supports `qwen35` (`src/models/qwen35.cpp`); `bNNNN` tags are prereleases (latest `b12503`, 2026-11-18); `v1.0.0` (2026-11-13) is stable "latest"
- [x] `GGML_CCACHE=ON` (default) auto-detects ccache for C/CXX only (`ggml/src/CMakeLists.txt`); `CMAKE_CUDA_COMPILER_LAUNCHER=ccache` required
- [x] `ggml-org/ccache-action` exists; kept per decision, pin by SHA
- [x] Upstream CUDA CI installs `libgomp1`; notes `GGML_CUDA_CCCL_VERSION=v3.4.3` may be needed for CTK < 13.5
- [ ] Exact apt package names for CUDA 12.8 (`ubuntu2204`) and 13.0 (`ubuntu2404`) — verify on first run
- [ ] `GGML_CUDA_CCCL_VERSION` needed for CUDA 12.8? (spike)
- [ ] ccache-action entry naming/save behavior; per-cell `max-size`; measure real cache sizes
- [ ] TurboQuant build flags review (`cmake -LH`)
- [ ] Runtimes' CPU flags (`GGML_AVX2`/`GGML_FMA`/`GGML_F16C`)

### Phase 1 — Kaggle deliverable (first milestone)

- [ ] Scaffold: `.github/workflows/cuda-t4-release.yml`, `.github/scripts/{plan,install-cuda,package,release}.sh`, `check-runtime.sh`, `BUILD_INFO.json` template
- [ ] `plan.sh`: resolve sources → SHAs (`git ls-remote` + releases API for newest `bNNNN`), idempotency by tag (skip if release exists, unless `force`), emit matrix JSON
- [ ] `build` job: `ubuntu:22.04` container; install `git build-essential cmake ninja-build ccache libssl-dev jq libgomp1`; CUDA 12.8 via NVIDIA network repo (minimal packages); ccache; configure (`75-real`, `FA_ALL_QUANTS=OFF`, static cudart, dynamic cuBLAS); build the five targets
- [ ] Verification gates: `ldd` — no `not found`, needed CUDA sonames exactly `libcublas.so.12` + `libcublasLt.so.12`; `cuobjdump --list-elf` — only `sm_75`; `llama-server --version` / `llama-cli --version` exit 0; archive size within expected range
- [ ] `package.sh`: tar + `LICENSE` + `BUILD_INFO.json` + `check-runtime.sh` → `dist/`
- [ ] `release` job: download artifacts; all-or-nothing per source; `SHA256SUMS` + `manifest.json`; immutable release + rolling `-latest` (`--clobber`, pre-release); prune to 8
- [ ] `warm` job: restore-only for sources with nothing new
- [ ] Live-run validation via `gh` CLI; record cold/warm times, ccache hit rate, archive size, `ldd`/`cuobjdump` output
- [ ] Kaggle T4 functional test: download archive, run `check-runtime.sh`, run `Qwen3.8-27B-GSQ-RCO-IQ2_S-mtp.gguf` (turbo5 K / turbo3 V or f16 KV — turbo4 K / turbo3 V needs Phase 3)

### Phase 2 — Colab target

- [ ] Ubuntu 24.04 + CUDA 13.0 cell (no container); verify on a Colab T4; tune cache keys

### Phase 3 — validatable binaries

- [ ] Flip `GGML_CUDA_FA_ALL_QUANTS=ON`; T4 test: `llama-bench -fa 1 -ctk turbo4 -ctv turbo3`; serve test with those cache types + flash attention

### Phase 4 — hardening

- [ ] SHA-pin all actions + Dependabot; keep-alive (scheduled workflows disable after 60 days idle); failure notifications; build-provenance attestation (optional)

## Verification log

- 2026-11-18 — Phase 0 research via `gh` API + Hugging Face (full details in design doc §3, "Verified 18 Nov 2026"). Repo confirmed public, default branch `main`, no license (deferred). `gh` CLI authenticated as `LVKinyanjui` with `repo` + `workflow` scopes. Design doc updated to the clarified spec (Kaggle-first, `FA_ALL_QUANTS=OFF` initially, no HF mirror, keep 8, `ggml-org/ccache-action`, `bNNNN` tracking, `gh`-based live-run validation).

## Open questions

- None blocking. See design doc §15.
