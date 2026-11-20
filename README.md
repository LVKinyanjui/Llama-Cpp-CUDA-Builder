# Llama-Cpp-CUDA-Builder

Builds sm_75 (T4) CUDA binaries of [llama.cpp](https://github.com/ggml-org/llama.cpp) and [llama-cpp-turboquant](https://github.com/TheTom/llama-cpp-turboquant), and publishes them as GitHub releases.

| Target | Runtime | CUDA | Status |
| --- | --- | --- | --- |
| Ubuntu 22.04 (container) | Kaggle | 12.8 | Phase 1 (first deliverable) |
| Ubuntu 24.04 | Colab | 13.0 | Phase 2 |

- **Workflows:** one per source — `cuda-t4-release-llama-cpp.yml` and `cuda-t4-release-turboquant.yml` — each twice-weekly (Mon/Thu 04:17 UTC) + manual dispatch (`ref`, `force`), so each source can be iterated on independently.
- **Releases:** one immutable release per (source, ref) + rolling `llama-cpp-latest` / `turboquant-latest` with stable asset names, published with `softprops/action-gh-release`. Keeps the last 8 immutable releases per source.
- **Web UI:** llama-cpp uses the HF prebuilt UI (`LLAMA_BUILD_UI=OFF`, `LLAMA_USE_PREBUILT_UI=ON`, no npm); turboquant builds the UI from source with npm (node 22 via `actions/setup-node`, `cache: npm`). Embedded in `llama-server`.
- **Binaries:** `llama-server`, `llama-cli`, `llama-bench`, `llama-quantize`, `llama-perplexity`. Dynamic cudart/cuBLAS/cuBLASLt by major soname; nothing from NVIDIA is bundled.
- **Progress:** see `Task.md`. **Design:** see `CUDA sm_75 release pipeline for llama.cpp and TurboQuant.md`. **Monitoring & Troubleshooting:** see [Monitoring.md](Monitoring.md).

## Repository conventions

- **Do not commit large binaries or vendored dependencies.** When adding any tool or dependency, decide deliberately whether it belongs in version control. If it is large, a binary, or easily re-downloadable, gitignore it and document how to obtain it instead.
- `tools/` is gitignored for this reason (see below). CI does not use it; GitHub-hosted runners ship their own `jq` and `shellcheck`.
- Shell scripts and workflow YAML are stored with LF line endings (enforced by `.gitattributes`).

## Local validation tools (not committed)

Standalone Windows (x86_64) binaries for local validation only. Download them into `tools/` (gitignored) from the sources below and verify against the SHA-256 hashes.

| Tool | Version | License | Source |
| --- | --- | --- | --- |
| `shellcheck.exe` | 0.11.0 | GPL-3.0 | https://github.com/koalaman/shellcheck/releases/tag/v0.11.0 (`shellcheck-v0.11.0.zip`) |
| `jq.exe` | 1.8.2 | MIT | https://github.com/jqlang/jq/releases/tag/jq-1.8.2 (`jq-windows-amd64.exe`) |
| `actionlint.exe` | 1.7.12 | MIT | https://github.com/rhysd/actionlint/releases/tag/v1.7.12 (`actionlint_1.7.12_windows_amd64.zip`) |

SHA-256 of the binaries:

```
c9e82ada36ef4b8d4caf1f97fa89289048c8f4a33c2c76ffffc88bfe09ff00c5  shellcheck.exe
a6fc67fedaf9128a3309a1e2ebb8b986aeccf70122ee46d2cb4849e423f0c627  jq.exe
54ca21be3de4c7cfa26914aa8b61bd76bf573ef3caac5f80d110558cdf241718  actionlint.exe
```

`jq.exe` and `actionlint.exe` were verified against the checksums published with their releases; `shellcheck.exe` was verified by zip integrity (upstream publishes no checksum file).

Usage:

```sh
tools/shellcheck.exe .github/scripts/*.sh check-runtime.sh
tools/actionlint.exe .github/workflows/cuda-t4-release.yml
tools/jq.exe ...
```
