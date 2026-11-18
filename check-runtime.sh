#!/usr/bin/env bash
# Verifies that the CUDA major sonames this build needs are registered in the
# loader cache. Run on the target machine (e.g. Kaggle/Colab) after extracting
# the archive. Exits non-zero if a needed soname is missing.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

MAJOR=""
if [[ -f BUILD_INFO.json ]]; then
  MAJOR=$(grep -oE '"cuda_major": *[0-9]+' BUILD_INFO.json | grep -oE '[0-9]+' | head -n1 || true)
fi
if [[ -z "$MAJOR" ]]; then
  if ldconfig -p | grep -q 'libcublas.so.13'; then MAJOR=13
  elif ldconfig -p | grep -q 'libcublas.so.12'; then MAJOR=12
  else
    echo "FAIL: neither libcublas.so.12 nor libcublas.so.13 found in 'ldconfig -p'" >&2
    exit 1
  fi
  echo "note: BUILD_INFO.json missing/unparseable; auto-detected CUDA major $MAJOR"
fi

missing=0
for lib in "libcudart.so.${MAJOR}" "libcublas.so.${MAJOR}" "libcublasLt.so.${MAJOR}"; do
  if ldconfig -p | grep -q "$lib"; then
    echo "ok: $lib"
  else
    echo "MISSING: $lib" >&2
    missing=1
  fi
done

if command -v nvcc >/dev/null 2>&1; then
  nvcc --version | tail -n1
else
  echo "note: nvcc not found; cannot check toolkit minor (binaries need >= the build minor, same major)"
fi

exit $missing
