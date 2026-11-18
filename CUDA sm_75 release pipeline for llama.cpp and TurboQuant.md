# CUDA sm\_75 release pipeline for llama.cpp and TurboQuant

*GitHub Actions design and implementation plan. Facts verified 17 Nov 2026; updated 18 Nov 2026 with Phase 0 research (see section 3). Items marked **\[verify\]** could not be confirmed from here and should be checked in the spike (Phase 1).*

## 1. Summary and recommendations

The notebook already contains the whole recipe: install CUDA, build with ccache for sm\_75, package, upload. The work is moving that recipe onto GitHub-hosted CPU runners, wrapping it in a matrix, and fixing four problems the notebook hides. These are listed below.

| # | Decision | Recommendation |
| --- | --- | --- |
| 1 | Repo topology | **One public, non-fork "builder" repo named `Llama-Cpp-CUDA-Builder`** (renamed 18 Nov 2026) with a matrix over both sources. Do not fork each project. Default branch: `main`. |
| 2 | Trigger | **Twice-weekly scheduled poll (Mon and Thu, 04:17 UTC) plus manual dispatch.** A workflow cannot listen to events on a repo you don't own, so "on PR closure upstream" is not possible. Gaps of 3–4 days keep ccache inside GitHub's 7-day eviction window. Manual dispatch (with `source` and `ref`) covers anything newer. |
| 3 | What to build | Both sources. Upstream: the latest `bNNNN` release tag (all `bNNNN` tags are prereleases; `v1.0.0` is the stable "latest" — we deliberately track `bNNNN` for the newest architecture support). TurboQuant: HEAD of its default branch (`feature/turboquant-kv-cache`, confirmed). Never every merge. |
| 4 | Targets | **Two per source, matched to your runtimes:** Ubuntu 24.04 + CUDA 13.0 (Colab) and Ubuntu 22.04 + CUDA 12.8 (Kaggle). The 22.04 build runs **inside an `ubuntu:22.04` container**, because GitHub retires the 22.04 runner on 17 Apr 2027. |
| 5 | Toolkit on the build runner | 13.0.x and 12.8.x: the **oldest minor you support**, from NVIDIA's apt network repo with minimal packages. Binaries keep working on later minors of the same major. |
| 6 | GPU arch | `CMAKE_CUDA_ARCHITECTURES=75-real`. |
| 7 | Linking | **Dynamic cudart/cuBLAS/cuBLASLt resolved from the runtime's toolkit by major soname** (`.12` or `.13`). Nothing from NVIDIA is bundled, so archives are as small as possible. (Static cudart + dynamic cuBLAS is not viable: `libcublas.so.12` NEEDs `libcudart.so.12`.) |
| 8 | KV-quant kernels | **`GGML_CUDA_FA_ALL_QUANTS=OFF` initially** (rapid prototyping; decided 18 Nov 2026). Flip to `ON` in the validatable-binaries phase — required for TurboQuant's turbo4 K / turbo3 V, which is not in the default FA kernel set. Plain llama.cpp has no turbo types. Compiles are long, so ccache is essential. |
| 9 | Releases | **One immutable release per (source, ref)** with two assets plus checksums, plus two moving releases (`llama-cpp-latest`, `turboquant-latest`) with stable asset names. Keep the last **8** immutable releases per source (settled 18 Nov 2026). GitHub assets are sufficient — no Hugging Face mirror. |
| 10 | Security | Build jobs have a read-only token and no secrets. A separate release job holds write access and never executes source code. |

**Matrix size:** 2 sources × 2 targets = 4 build jobs per run, 2 assets per source. Both runtimes report driver 580.x, which satisfies either CUDA series, so a cross pairing (for example 24.04 + CUDA 12.8) would be one extra matrix row if you ever want it.

## 2. What the notebook does and what changes in CI

| Notebook step | In CI |
| --- | --- |
| `git clone --depth 1`, optional `pull/N/head` | `actions/checkout` with `repository:` and a pinned SHA. PR builds via `workflow_dispatch` input. |
| Colab/Kaggle secrets (GH PAT, HF token) | Built-in `GITHUB_TOKEN` for releases. No HF mirror — GitHub assets are sufficient (settled 18 Nov 2026). |
| ccache tarball install | `apt install ccache` plus a cache action. |
| CUDA local `.deb` install (\~GB download) | NVIDIA **network** repo and minimal packages. Faster and smaller. |
| `nvcc --version` to name the package | Versions are matrix variables, so the name is known up front. |
| cmake + build two targets | Same, with a wider target list and a flag review (section 8). |
| `ldd` printout | Turned into **assertions** (section 11). |
| tar + HF upload + per-build GitHub release | Artifact → single release job → one release per source ref. |

### Problems found in the notebook (worth fixing before porting)

1. **nvcc output is not cached.** Only `CMAKE_C_COMPILER_LAUNCHER` and `CMAKE_CXX_COMPILER_LAUNCHER` are set, and CUDA compilation is the slow part. Set `CMAKE_CUDA_COMPILER_LAUNCHER` too. **Verified 18 Nov 2026:** the fork's `ggml/src/CMakeLists.txt` shows `GGML_CCACHE=ON` (default) auto-detects ccache and sets `RULE_LAUNCH_COMPILE` for C/CXX only — it never sets `CMAKE_CUDA_COMPILER_LAUNCHER`. Explicit `CMAKE_CUDA_COMPILER_LAUNCHER=ccache` is required.
2. **cuBLAS is a shared dependency.** `-DCMAKE_CUDA_RUNTIME_LIBRARY=Static` does not change ggml's link choice — ggml links `CUDA::cudart` (shared) by default, and `libcublas.so.12` NEEDs `libcudart.so.12` anyway, so dynamic cudart is unavoidable with dynamic cuBLAS. The binaries need `libcudart`, `libcublas` and `libcublasLt` from the runtime's toolkit. That suits your runtimes (section 9) and is confirmed with `ldd`.
3. **PR checkout is not conditional.** The `git fetch ... {pr_ID}` lines sit outside the `if`, so an empty PR field fails with a NameError.
4. **`repo_url` carries literal escaped quotes** in the dropdown value, and the `LD_LIBRARY_PATH` lines overwrite each other. Both are irrelevant in CI but would be copied if ported verbatim.
5. **Ubuntu 22.04 is hard-coded** in the CUDA repo URLs, so the notebook cannot produce 24.04 builds.

## 3. Facts that shape the design

**Upstream (ggml-org/llama.cpp).** Its own release workflow triggers on pushes to `master` filtered by source paths, plus manual dispatch. Release tags are `bNNNN`. A third-party tutorial that checked build b12110 on 12 Nov 2026 reports official Ubuntu x64 CUDA 12 (12.8 libraries) and CUDA 13 archives **\[verify on the releases page\]**. Official builds are multi-architecture. You have said there is a reason to build plain llama.cpp as well, so it stays in scope, and an sm\_75-only build is smaller and matched to your two runtimes.

**TurboQuant (TheTom/llama-cpp-turboquant).** Its README states the default branch is `feature/turboquant-kv-cache`, roughly 300 commits ahead of upstream, with continuous sync from upstream master (README snapshot from May 2026). Older third-party guides say `master` has no TurboQuant code. **Resolve the default branch through the API instead of hard-coding any branch name.** The sibling `turboquant_plus` README says prebuilt binaries exist for Mac (Metal) and Windows (CUDA), so a **Linux CUDA** build fills a real gap.

**Runners.** `ubuntu-22.04` runner images enter deprecation on 17 Sep 2026, have failing brownouts from 23 Mar 2027, and are unsupported from 17 Apr 2027. `ubuntu-latest` is moving to Ubuntu 26.04, so always use explicit labels.

**CUDA and drivers (NVIDIA release notes).**

| Toolkit | Driver needed on the T4 machine (minor-version compat) |
| --- | --- |
| 12.x | ≥ 525 (and < 580) |
| 13.x | ≥ 580 |

- CUDA 13.4 GA is 13.4.1 (9 Sep 2026) and its branch is R615.
- CUDA 13 dropped Maxwell, Pascal and Volta. **Turing (sm\_75) is still supported.**
- **Your runtimes, as reported:** Colab is Ubuntu 24.04.4, driver 580.82.07, nvcc 13.0 (V13.0.88). Kaggle is Ubuntu 22.04.5, driver 580.178.04, nvcc 12.8 (V12.8.93). Driver 580 satisfies both the ≥ 525 (12.x) and ≥ 580 (13.x) rows, so the driver is not a constraint. The OS and the toolkit major are.
- **Both runtimes register `libcudart`, `libcublas` and `libcublasLt` in the loader cache** under `/usr/local/cuda/targets/x86_64-linux/lib` (`.13` sonames on Colab, `.12` on Kaggle), so no RPATH is needed.

**Cross-repo triggers.** GitHub has no mechanism to start your workflow from someone else's push or PR event. Your options are polling or a webhook they would have to configure. Polling is the only practical choice.

**Verified 18 Nov 2026 (Phase 0 research).**

- **TurboQuant** (`TheTom/llama-cpp-turboquant`, public, fork of ggml-org/llama.cpp): default branch `feature/turboquant-kv-cache`, HEAD `4185b90` (2026-11-11), ~7 days behind upstream master. It **does** ship `src/models/qwen35.cpp` and `qwen35moe.cpp` (GitHub code search is stale — verify via the contents API, not search).
- **Upstream llama.cpp** supports `qwen35` (`src/models/qwen35.cpp`). All `bNNNN` tags are prereleases (latest `b12503`, 2026-11-18); `v1.0.0` (2026-11-13) is the stable "latest" release. We track `bNNNN`.
- **ccache-action:** `ggml-org/ccache-action` exists (fork of `hendrikmuhs/ccache-action`, used by upstream CI as `@v1.2.24`). Kept per decision 18 Nov 2026; pin by full SHA.
- **Upstream CUDA CI** (`build-cuda-ubuntu.yml`) installs `libgomp1` and notes `GGML_CUDA_CCCL_VERSION=v3.4.3` may be required for CTK < 13.5 — check for CUDA 12.8 in the spike.
- **Target model:** `Qwen3.8-27B-GSQ-RCO-IQ2_S-mtp.gguf` from `ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF` (9.26 GB, arch `qwen35`, hybrid SSM/attention, MTP head `blk.64` / `nextn.*`). GSQ-RCO assigns **standard** GGUF quant types per tensor (IQ1_M/S, IQ2_S/XS/XXS, IQ3_S/XXS, IQ4_XS, Q2_K, Q4_K, Q6_K, BF16, F32 — see the `-mtp` allocation dump). There is **no compile-time weight-quant selection** in llama.cpp and none is needed; the file runs unmodified.
- **KV cache:** turbo4 K / turbo3 V is **not** in the default FA kernel set — it requires `GGML_CUDA_FA_ALL_QUANTS=ON`. Default-build turbo3-V pairs: turbo5 K / turbo3 V and turbo6 K / turbo3 V. Plain llama.cpp has no turbo types; turbo KV cache is TurboQuant-only.

## 4. Decision 1: repository topology

| Option | Pros | Cons |
| --- | --- | --- |
| **A. Two forks, each with its own workflow** | Natural place for source patches. | Syncing a fork brings upstream's whole CI along, which you must disable. Scheduled workflows are off by default in forks. Workflow duplicated in two places. Merge conflicts on every sync. |
| **B. One builder repo, matrix over sources (recommended)** | Single workflow, single release feed. No merge conflicts. No inherited upstream CI. Adding a third source is one matrix row. | No git history for local patches. Use a `patches/<source>/*.patch` directory applied with `git apply` if you need any. |
| **C. Keep one fork and add the workflow to it** | You already have `LVKinyanjui/llama.cpp`. | Same inherited-CI and sync problems as A. |

**Recommendation: B.** Named `Llama-Cpp-CUDA-Builder` (renamed 18 Nov 2026), public, default branch `main`. Public repos get free standard runners, and private repos have a minutes quota and smaller runners **\[verify current limits\]**. Your existing fork can remain as a plain archive.

## 5. Decision 2: triggers

| Mechanism | Verdict |
| --- | --- |
| `schedule` (cron) polling upstream with `git ls-remote` | **Use.** Idempotent: skip if the release tag already exists. |
| `workflow_dispatch` with `source`, `ref`, `force` | **Use.** Covers PR builds (`refs/pull/N/head`), one-off rebuilds, and flag experiments. |
| `repository_dispatch` from upstream | Not possible without upstream's cooperation. |
| Push to your own repo (fork sync) | Works only if the sync is performed by a user or PAT. Pushes made with `GITHUB_TOKEN` don't trigger workflows. |
| Per-merge or per-PR-closure builds | Reject. Upstream master moves tens of builds per day, and 4 CUDA jobs per source each time is wasteful. A merged PR is just a master commit anyway. |

**Gotchas:**

- Scheduled workflows in public repos are **disabled after 60 days without repo activity**. Add a monthly keep-alive commit or an API call that re-enables it.
- Cron runs only from the default branch and can be delayed under load.
- **Cadence: twice weekly (Mon and Thu, 04:17 UTC).** GitHub deletes cache entries not accessed in over 7 days and caps a repo at 10 GB, so each cell must restore its cache at least once a week. Gaps of 3 and 4 days do that. A weekly cron sits on the edge, and one delayed run loses the cache.
- Upstream tags move daily and TurboQuant syncs continuously, so most runs build. When a source has nothing new, a **warm job** restores that source's caches without building, which keeps them alive.
- For anything newer than the last scheduled run, dispatch manually with `source` and `ref`.

## 6. Decision 3: OS matrix

Two targets cover both runtimes: **Ubuntu 24.04 for Colab** and **Ubuntu 22.04 for Kaggle**. A binary built on 24.04 (glibc 2.39) will not run on 22.04 (glibc 2.35), so each target is built on its own OS. **The Kaggle (22.04 + CUDA 12.8) cell is the first deliverable** (decided 18 Nov 2026); the Colab cell follows.

- **24.04 (Colab):** build directly on `runs-on: ubuntu-24.04`.
- **22.04 (Kaggle):** `container: ubuntu:22.04` on the same runner. This survives the runner retirement and still produces glibc 2.35 binaries. Install `git` early so `actions/checkout` can do a real clone. Install `libgomp1` too (upstream CUDA CI does).
- Alternative for 22.04: the `nvidia/cuda:12.8.1-devel-ubuntu22.04` image, which skips the toolkit install. Confirm the tag exists **\[verify\]**. It is less symmetric with your own "download the toolkit" requirement, so treat it as a fallback.
- Disk: container jobs can't free runner disk first. The minimal CUDA package set (\~3–4 GB) should fit; the full `cuda-toolkit-*` metapackage may not.

## 7. Decision 4: installing the toolkit

| Method | Notes |
| --- | --- |
| **NVIDIA apt network repo (recommended)** | `cuda-keyring_1.1-1_all.deb`, then `apt-get install` minimal packages. Distro path is `ubuntu2204` or `ubuntu2404`. Transparent, no third-party action, supports both OSes. |
| `Jimver/cuda-toolkit` action | Works on Linux with `method: network` and `sub-packages`. Convenient, but it's a third-party dependency, and its Linux support lags new CUDA releases. Pin by SHA if used. |
| Local `.deb` / `.run` installer (the notebook) | Multi-GB download. No benefit on CI. |

Minimal package set, with `MM` as `12-8` or `13-0` **\[verify exact names on first run\]**: `cuda-compiler-MM cuda-libraries-dev-MM cuda-cuobjdump-MM`

- Set `CUDA_HOME=/usr/local/cuda-13.0` (or `-12.8`) explicitly and pass `-DCMAKE_CUDA_COMPILER=$CUDA_HOME/bin/nvcc`. Don't rely on the `/usr/local/cuda` symlink.
- **Build with the oldest minor you support (12.8 and 13.0) and run on anything newer in the same major.** The binaries record only the major soname (`libcudart.so.12`, `libcublas.so.12` or `.13`), so a runtime that moves to 12.9 or 13.1 keeps working. Only a runtime below the build minor, or a new major, breaks it. ABI stability within a major is **\[verify\]** for cuBLAS: test one cross-minor pairing when a runtime next upgrades.
- apt resolves the latest patch of a minor version. To pin the patch, append `=<version>` to package names. Record the toolkit version actually used in `BUILD_INFO.json`.
- Upstream CI notes `GGML_CUDA_CCCL_VERSION=v3.4.3` may be required for CTK < 13.5 (CUDA 12.8). If configure fails with CCCL errors, set it **\[verify in spike\]**.
- **Compiler compatibility:** GCC 11 (22.04) and GCC 13 (24.04) are both accepted by these toolkits.

## 8. Decision 5: CMake configuration

| Flag | Value | Why |
| --- | --- | --- |
| `GGML_CUDA` | ON | Required. |
| `CMAKE_CUDA_ARCHITECTURES` | `75-real` | SASS only. Plain `75` also embeds PTX, which only helps on GPUs you aren't targeting. Upstream's own CI uses the `-real` form. |
| `GGML_NATIVE` | OFF | Portable CPU code, since the build machine ≠ the run machine. |
| `GGML_AVX2`, `GGML_FMA`, `GGML_F16C` (optional) | ON | Both runtimes' CPUs very likely support them, which would speed CPU-side layers. Confirm the CPU flags on both runtimes first **\[verify\]**. |
| `GGML_CUDA_FA_ALL_QUANTS` | **OFF initially** (decided 18 Nov 2026); **ON in the validatable-binaries phase** | Compiles FlashAttention kernels for all KV-cache quant combinations. TurboQuant needs it for turbo4 K / turbo3 V (not in the default kernel set — confirmed in `docs/KV-cache-quantization.md`). Plain llama.cpp gets all standard KV-quant FA kernels. Compile time grows a lot, so ccache matters most here. Initial builds use the default kernel set to keep iteration fast. |
| `GGML_CUDA_GRAPHS` | leave default |  |
| `GGML_CUDA_FORCE_MMQ` / `FORCE_CUBLAS` | leave default | Tuning knobs, not packaging decisions. |
| `GGML_CUDA_COMPRESSION_MODE` | `size` (try it) | Shrinks the fatbin. Archive size matters for ephemeral environments, so test the effect on size and on load time. |
| `CMAKE_CUDA_COMPILER_LAUNCHER` | `ccache` | Caches nvcc output, which the notebook missed. **Verified 18 Nov 2026:** `GGML_CCACHE=ON` (default) auto-detects ccache for C/CXX only (`ggml/src/CMakeLists.txt`) and never sets the CUDA launcher — set it explicitly. |
| `BUILD_SHARED_LIBS` | OFF | Single-file binaries, as in the notebook. |

| `CMAKE_EXE_LINKER_FLAGS` | `-static-libgcc -static-libstdc++ -s` | As in the notebook, plus `-s` to strip symbols (smaller archives for ephemeral environments; decided 18 Nov 2026). No RPATH is set, because both runtimes register the CUDA libraries in the loader cache. |
| HTTPS model download (`-hf`) | `LLAMA_OPENSSL=ON` plus `libssl-dev` | Option names have changed repeatedly (`LLAMA_CURL`, `LLAMA_OPENSSL`, BoringSSL variants). Run `cmake -LH` and grep the fork's `CMakeLists.txt` rather than trusting a list. |
| `LLAMA_BUILD_TESTS` / `EXAMPLES` | OFF | Faster build. |

**Targets:** `llama-server llama-cli llama-bench llama-quantize llama-perplexity`. TurboQuant adds weight formats, so `llama-quantize` is useful to ship.

**Don't** use a fully static (`-static`) link. The CUDA driver (`libcuda.so.1`) is loaded at runtime and a static glibc binary can't load it.

## 9. Decision 6: linking and packaging

| Strategy | Archive | Needs at runtime |
| --- | --- | --- |
| **Dynamic cudart/cuBLAS/cuBLASLt (chosen 18 Nov 2026)** | Smallest | NVIDIA driver plus CUDA libraries with the same **major** soname (`libcudart.so.12`, `libcublas.so.12`, `libcublasLt.so.12` on Kaggle; `.13` on Colab). Any minor at or above the build minor. |
| Bundle cuBLAS/cuBLASLt next to the binaries | Hundreds of MB larger | Only the driver |
| Static cuBLAS (`GGML_STATIC=ON` selects static cudart/cuBLAS/cuBLASLt in upstream CMake) | Larger binaries | Only the driver. **Check that it doesn't also force `-static` glibc \[verify\].** |

**Why not static cudart + dynamic cuBLAS:** `libcublas.so.12` has `NEEDED libcudart.so.12`, so dynamic cuBLAS pulls in dynamic cudart transitively — the combination is not viable. ggml also links `CUDA::cudart` (shared) by default; `CMAKE_CUDA_RUNTIME_LIBRARY=Static` does not change that. Both runtimes register `libcudart`, `libcublas` and `libcublasLt` in the loader cache, so dynamic linking works on both.

You rely on the runtime's toolkit, so the contract is the CUDA **major** version. The build uses the oldest minor you support (section 7) and no NVIDIA libraries are redistributed. Each archive carries the project `LICENSE`, a `BUILD_INFO.json` and a short `check-runtime.sh`. The script fails if the needed major soname is missing from `ldconfig -p`, and only warns if the toolkit minor is below the build minor. Your runtime checks confirmed both toolkits register `libcudart`, `libcublas` and `libcublasLt` in the loader cache, so no RPATH fallback is needed.

## 10. Decision 7: naming and release structure

**Asset name:** `<project>-<ref>-bin-ubuntu<22.04|24.04>-x64-cuda<12.8|13.0>-sm75.tar.gz`

- `llama-cpp-b12387-bin-ubuntu22.04-x64-cuda12.8-sm75.tar.gz`
- `llama-cpp-turboquant-20261117-3f2a9c1-bin-ubuntu24.04-x64-cuda13.0-sm75.tar.gz`

**Release tag (one per source ref):** `llama-cpp-b12387`, `turboquant-20261117-3f2a9c1`. PR builds are `...-pr123-<sha7>` and marked pre-release.

Each release contains the 2 archives (Ubuntu 24.04 + CUDA 13.0 for Colab, Ubuntu 22.04 + CUDA 12.8 for Kaggle), `SHA256SUMS`, and a `manifest.json` (source URL, full SHA, ref or PR, toolkit versions, flags, build date, runner image version). Add build-provenance attestation later (Phase 4). The tag doubles as the idempotency key for the poller.

**Rolling latest releases.** Two moving releases, `llama-cpp-latest` and `turboquant-latest`, carry the same two archives under ref-less, stable names (for example `llama-cpp-bin-ubuntu22.04-x64-cuda12.8-sm75.tar.gz`), so notebooks can use one fixed URL. The release job replaces their assets with `gh release upload --clobber` only after the source's immutable release succeeds, and rewrites the notes with the source SHA and build date. Mark them pre-release so they never take the repo-wide "Latest" flag. Prune immutable releases to the last **8** per source (settled 18 Nov 2026).

## 11. Pipeline architecture

**Two workflows, one per source** (settled 18 Nov 2026): `cuda-t4-release-llama-cpp.yml` and `cuda-t4-release-turboquant.yml`, sharing `.github/scripts/`, so each source iterates independently. Each workflow has the same three jobs:

1. **plan** (read-only): resolve the source to a concrete SHA and ref (`git ls-remote`, API for the default branch / newest `bNNNN`). Drop the source whose release tag already exists unless `force`. Emit the build matrix as JSON. Using one SHA for all jobs prevents a mid-run commit from producing mismatched archives.
2. **build** (matrix, read-only, no secrets): checkout the pinned SHA, install deps and CUDA, restore ccache, configure, build, verify, package, upload artifact.
3. **release** (write permission, no source execution): download artifacts; `stage-release.sh` checks all of the source's assets exist (all-or-nothing), writes `SHA256SUMS` + `manifest.json` + notes, and stages stable-named assets for the rolling `-latest` release; then `softprops/action-gh-release` (v3.0.4, SHA-pinned) publishes the immutable release and refreshes `<source>-latest`; `prune-releases.sh` keeps the last 8 immutable releases per source.

4. **warm** (read-only, not yet implemented): for any source with nothing new, restore its ccache entries without building, so they stay inside the 7-day window.
5. **No HF mirror** (settled 18 Nov 2026): releasing as a GitHub asset is sufficient.

**Verification gates in `build` (no GPU needed):**

- `ldd` on every binary reports no `not found` **except `libcuda.so.1`** (the driver library — absent on GPU-less runners, provided by the NVIDIA driver on the target), and the set of needed CUDA libraries equals the expected sonames for that target (`libcudart.so.12`, `libcublas.so.12`, `libcublasLt.so.12` for CUDA 12.8; `.13` for CUDA 13.0).
- `cuobjdump --list-elf` on the binary or backend library shows **only `sm_75`**.
- `llama-server --version` and `llama-cli --version` — warn-only on GPU-less runners (the binaries hard-depend on `libcuda.so.1`); the real smoke test happens on the T4.
- Archive size is within an expected range (catches a flag that silently doubled it).

The real functional test, loading a model on a T4, stays **manual** (a Colab notebook that downloads the release) until you decide to add a self-hosted GPU runner.

**Live-run validation (decided 18 Nov 2026).** The `gh` CLI is authenticated as `LVKinyanjui` with `repo` + `workflow` scopes, so run results are read directly — no MCP server or copy-paste needed: `gh run list`, `gh run view <id> --log`, `gh run watch <id>` (poll rather than block; each shell invocation is fresh). Loose TDD: verification gates are written first, and the pipeline is validated layer by layer (scripts → workflow → live run) before it is relied on.

**Caching.** GitHub deletes cache entries not accessed in over 7 days and caps a repo at 10 GB with least-recently-used eviction ([GitHub's policy as quoted here](https://github.com/toshimaru/delete-action-cache)). That drives the cron choice in section 5.

- Each cell restores its cache every run, and the `warm` job covers sources with nothing new.
- **Budget:** four cells share 10 GB, and ccache-action is expected to save a new entry each run **\[verify\]**. Set a per-cell `max-size`, delete superseded entries, and measure real sizes in Phase 1. `FA_ALL_QUANTS=ON` (Phase 3) makes the cells larger.
- **Hit rate:** use a fixed workspace path, `CCACHE_COMPILERCHECK=content` and `CMAKE_CUDA_COMPILER_LAUNCHER=ccache`, and check `ccache -s`.
- Expect a cold build after a cache loss, or after a header change that invalidates many kernels.

## 12. Workflow skeleton

This is a shape to adapt, not tested code. Pin every third-party action by full commit SHA.

```yaml
name: cuda-t4-release
on:
  schedule: [{ cron: "17 4 * * 1,4" }]
  workflow_dispatch:
    inputs:
      source: { type: choice, options: [all, llama-cpp, turboquant], default: all }
      ref:    { description: "branch/tag/SHA/refs/pull/N/head (blank = latest)", required: false }
      force:  { type: boolean, default: false }
permissions: { contents: read }

jobs:
  plan:
    runs-on: ubuntu-24.04
    outputs: { matrix: "${{ steps.p.outputs.matrix }}" }
    steps:
      - uses: actions/checkout@<sha>
      - id: p
        env: { GH_TOKEN: "${{ github.token }}", SOURCE: "${{ inputs.source }}", REF: "${{ inputs.ref }}", FORCE: "${{ inputs.force }}" }
        run: .github/scripts/plan.sh   # writes matrix=[{name,repo,sha,tag,ubuntu,cuda,cuda_mm,asset,container}]

  build:
    needs: plan
    if: needs.plan.outputs.matrix != '[]'
    runs-on: ubuntu-24.04
    container: ${{ matrix.container || null }}   # "ubuntu:22.04" or empty
    timeout-minutes: 120
    strategy:
      fail-fast: false
      matrix: { include: "${{ fromJSON(needs.plan.outputs.matrix) }}" }
    env: { CUDA_HOME: "/usr/local/cuda-${{ matrix.cuda_mm }}" }
    steps:
      - run: |
          S=$(command -v sudo || true)
          $S apt-get update
          $S apt-get install -y --no-install-recommends git curl ca-certificates gnupg \
            build-essential cmake ninja-build ccache libssl-dev jq libgomp1
      - uses: actions/checkout@<sha>
        with: { repository: "${{ matrix.repo }}", ref: "${{ matrix.sha }}", path: src, fetch-depth: 1 }
      - run: scripts/install-cuda.sh "${{ matrix.ubuntu }}" "${{ matrix.cuda }}"
      - uses: ggml-org/ccache-action@<sha>
        with: { key: "${{ matrix.name }}-u${{ matrix.ubuntu }}-cuda${{ matrix.cuda_mm }}", evict-old-files: 7d, max-size: 1G }
      - name: Configure and build
        run: |
          export PATH="$CUDA_HOME/bin:$PATH"
          cmake -S src -B build -G Ninja -DCMAKE_BUILD_TYPE=Release \
            -DGGML_CUDA=ON -DCMAKE_CUDA_COMPILER="$CUDA_HOME/bin/nvcc" \
            -DCMAKE_CUDA_ARCHITECTURES=75-real -DGGML_NATIVE=OFF \
            -DGGML_CUDA_FA_ALL_QUANTS=OFF -DBUILD_SHARED_LIBS=OFF \
            -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache \
            -DCMAKE_EXE_LINKER_FLAGS="-static-libgcc -static-libstdc++ -s" \
            -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
            -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF
          cmake --build build -j"$(nproc)" \
            --target llama-server llama-cli llama-bench llama-quantize llama-perplexity
      - run: scripts/package.sh   # ldd/cuobjdump gates, BUILD_INFO.json, check-runtime.sh, tar -> dist/
      - uses: actions/upload-artifact@<sha>
        with: { name: "${{ matrix.asset }}", path: dist/*, if-no-files-found: error }

  release:
    needs: [plan, build]
    if: ${{ !cancelled() && needs.plan.result == 'success' }}
    runs-on: ubuntu-24.04
    permissions: { contents: write }
    steps:
      - uses: actions/checkout@<sha>
      - uses: actions/download-artifact@<sha>
        with: { path: dist, merge-multiple: true }
      - id: stage
        env: { MATRIX: "${{ needs.plan.outputs.matrix }}" }
        run: bash .github/scripts/stage-release.sh   # all-or-nothing check, SHA256SUMS, manifest.json, notes, stable-name copies
      - if: steps.stage.outputs.publish == 'true'
        uses: softprops/action-gh-release@<sha>   # v3.0.4
        with: { tag_name: "${{ steps.stage.outputs.tag }}", files: "${{ steps.stage.outputs.assets_dir }}/*", prerelease: "${{ steps.stage.outputs.prerelease }}", body_path: "${{ steps.stage.outputs.notes }}", fail_on_unmatched_files: true }
      - if: steps.stage.outputs.publish == 'true'
        uses: softprops/action-gh-release@<sha>   # v3.0.4
        with: { tag_name: "${{ steps.stage.outputs.latest_tag }}", files: "${{ steps.stage.outputs.latest_dir }}/*", prerelease: true, body_path: "${{ steps.stage.outputs.latest_notes }}", fail_on_unmatched_files: true }
      - if: steps.stage.outputs.publish == 'true'
        env: { GH_TOKEN: "${{ github.token }}", NAME: "${{ steps.stage.outputs.name }}" }
        run: bash .github/scripts/prune-releases.sh   # keep last 8 immutable releases per source
```

`scripts/install-cuda.sh` is roughly: download `cuda-keyring_1.1-1_all.deb` from `https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${2204|2404}/x86_64/`, `dpkg -i` it, `apt-get update`, then install the three packages for the matrix's `MM`.

Not shown: the restore-only `warm` job for sources with nothing new, and `CCACHE_COMPILERCHECK=content` in the build step's environment. The `max-size: 1G` value is a placeholder to tune after measuring real cache sizes in Phase 1. The skeleton is per source — the repo ships two workflow files (`cuda-t4-release-llama-cpp.yml`, `cuda-t4-release-turboquant.yml`), one per source, sharing `.github/scripts/`. The Web UI is disabled for the initial build (`LLAMA_BUILD_UI=OFF`) and MUST be re-enabled from source with npm after initial verification.

## 13. Risks and open questions

| Risk | Mitigation |
| --- | --- |
| Cold CUDA compile is slow, especially with `FA_ALL_QUANTS` on both sources (**\[verify\]** timing in spike) | ccache per matrix cell, one arch, and only the needed targets. |
| Caches evicted after 7 days unused, or by the 10 GB cap | Twice-weekly cron, a warm job for skipped sources, per-cell `max-size` and deletion of superseded entries. |
| TurboQuant is a single-maintainer fork whose branch layout can change | Resolve the default branch via API, build pinned SHAs only, and keep the source list in one config file. |
| A compromised source commit runs on your runner | Build jobs get a read-only token and no secrets. The release job never runs source. |
| Scheduled workflow silently disabled | Keep-alive plus an alert if no release is created in three weeks. |
| Colab or Kaggle upgrades its toolkit or OS | A later minor of the same major keeps working. A new major or a new Ubuntu needs a new matrix row. `check-runtime.sh` and the release notes name the requirement. |
| Mixed turbo4 K / turbo3 V has no kernel or is slow on T4 | Requires `GGML_CUDA_FA_ALL_QUANTS=ON` (not in the default kernel set). Test with `llama-bench -fa 1 -ctk turbo4 -ctv turbo3` before announcing a release. |
| `bNNNN` tags are prereleases; `releases/latest` returns `v1.0.0` | `plan.sh` must query the releases API for the newest `bNNNN` tag, not `releases/latest`. |
| New toolkit drops Turing someday | Re-read the architecture deprecations section on each CUDA bump. |
| Upstream renames CMake options | A `cmake -LH` dump in logs, plus a configure-smoke job on a fixed schedule. |

## 14. Phased plan

**Phase 0: confirm the unknowns (a few hours).** The runtime check is done: both runtimes register `libcudart`, `libcublas` and `libcublasLt` in the loader cache. Phase 0 research completed 18 Nov 2026 (see section 3): TurboQuant default branch and `qwen35` support confirmed; `GGML_CCACHE` covers C/CXX only; `ggml-org/ccache-action` verified; `bNNNN` prerelease scheme confirmed. Still to check: the exact apt package names for 13.0 and 12.8 on both distros; `GGML_CUDA_CCCL_VERSION` for CUDA 12.8; how ccache-action names and saves entries; the TurboQuant build flags; and the runtimes' CPU flags.

**Phase 1: Kaggle deliverable (first milestone).** Ubuntu 22.04 (container) + CUDA 12.8, **both sources** (llama-cpp and TurboQuant), `FA_ALL_QUANTS=OFF`, the five targets, verification gates, packaging, and the full pipeline: twice-weekly poller (Mon/Thu 04:17 UTC) + manual dispatch, idempotency by tag, all-or-nothing release, checksums/manifest, rolling `-latest` releases, and pruning to 8 immutable releases per source. **Web UI disabled for the initial build** (`LLAMA_BUILD_UI=OFF`); it MUST be re-enabled from source with npm after initial verification. Loose TDD: gates first, then build, then release; validate layer by layer via live runs (`gh run view --log`). Record cold and warm times, ccache size and hit rate, archive size, `ldd` output and `cuobjdump` output. Download the archive on a Kaggle T4, run `check-runtime.sh`, and run `Qwen3.8-27B-GSQ-RCO-IQ2_S-mtp.gguf` (turbo5 K / turbo3 V or f16 KV — turbo4 K / turbo3 V needs Phase 3). This confirms dynamic cuBLAS resolves with nothing bundled.

**Phase 2: Colab target.** Add Ubuntu 24.04 + CUDA 13.0 (no container), then verify on a Colab T4. Tune cache keys.

**Phase 3: validatable binaries.** Flip `GGML_CUDA_FA_ALL_QUANTS=ON` (required for turbo4 K / turbo3 V). T4 test with `Qwen3.8-27B-GSQ-RCO-IQ2_S-mtp.gguf`: `llama-bench -fa 1 -ctk turbo4 -ctv turbo3`, then a serve test with those cache types and flash attention on. Confirm the mixed pair has a kernel and is not pathologically slow.

**Phase 4: hardening.** SHA-pin all actions and add Dependabot for them, build-provenance attestation, keep-alive, failure notifications. No HF mirror (settled 18 Nov 2026).


## 15. Settled decisions and what is left

**Settled:** public `Llama-Cpp-CUDA-Builder` repo (default branch `main`); both llama.cpp and TurboQuant; **Kaggle (Ubuntu 22.04, CUDA 12.8) is the first deliverable**, Colab (Ubuntu 24.04, CUDA 13.0) second; `FA_ALL_QUANTS=OFF` initially, `ON` in the validatable-binaries phase (required for turbo4 K / turbo3 V); dynamic cudart/cuBLAS/cuBLASLt with a major-only soname and oldest-minor builds (static cudart + dynamic cuBLAS is not viable — `libcublas.so.12` NEEDs `libcudart.so.12`); twice-weekly cadence plus manual dispatch; rolling latest releases; keep the last 8 immutable releases per source; no HF mirror — GitHub assets are sufficient; `ggml-org/ccache-action` (pinned by SHA); track latest `bNNNN` prerelease; live-run validation via authenticated `gh` CLI; loose TDD (gates first); **two workflows, one per source** (`cuda-t4-release-llama-cpp.yml`, `cuda-t4-release-turboquant.yml`); **releases published with `softprops/action-gh-release`** (v3.0.4, SHA-pinned); **Web UI dropped for the initial build only — it MUST be present in subsequent builds after initial verification** (built from source with npm, not the HF bucket).

**Still open:**

1. ~~How many immutable releases per source to keep~~ — settled: 8.
2. Nothing else blocks Phase 0. Every item marked **\[verify\]** resolves in Phases 0 and 1.
3. ~~Web UI~~ — settled: dropped for the initial build only; MUST be present in subsequent builds after initial verification (build from source with npm).
4. ~~Canonical release approach~~ — settled: `softprops/action-gh-release` (v3.0.4, `8a0cd651e5b2365bd640854a3fa5dfc70e4875f3`).
5. ~~Separate build processes per source~~ — settled: two workflow files sharing `.github/scripts/`.
