#!/usr/bin/env bash
# Verification gates + packaging for one matrix cell.
# Env in: NAME REPO SHA REF TAG PRERELEASE UBUNTU CUDA CUDA_MM ASSET
# Produces: dist/<ASSET>
set -euo pipefail

: "${NAME:?}" "${REPO:?}" "${SHA:?}" "${REF:?}" "${TAG:?}" "${PRERELEASE:?}"
: "${UBUNTU:?}" "${CUDA:?}" "${CUDA_MM:?}" "${ASSET:?}"

BIN_DIR=build/bin
BINARIES=(llama-server llama-cli llama-bench llama-quantize llama-perplexity)
CUDA_MAJOR="${CUDA%%.*}"
EXPECTED_SONAMES=("libcudart.so.${CUDA_MAJOR}" "libcublas.so.${CUDA_MAJOR}" "libcublasLt.so.${CUDA_MAJOR}")
fail=0

if [[ -n "${CUDA_HOME:-}" && -x "$CUDA_HOME/bin/cuobjdump" ]]; then CUOBJDUMP="$CUDA_HOME/bin/cuobjdump"; else CUOBJDUMP=cuobjdump; fi

echo "=== Gate 1: ldd (no 'not found' except driver-provided libcuda.so.1, expected CUDA sonames only) ==="
for b in "${BINARIES[@]}"; do
  [[ -x "$BIN_DIR/$b" ]] || { echo "FAIL: missing binary $BIN_DIR/$b"; fail=1; continue; }
  out=$(ldd "$BIN_DIR/$b")
  echo "--- $b ---"; echo "$out"
  if echo "$out" | grep 'not found' | grep -v 'libcuda.so.1' | grep -q .; then
    echo "FAIL: $b has unresolved dependencies"; fail=1
  fi
  needed=$(echo "$out" | grep -oE 'libcudart\.so\.[0-9]+|libcublas(Lt)?\.so\.[0-9]+' | sort -u || true)
  for s in $needed; do
    found=0
    for e in "${EXPECTED_SONAMES[@]}"; do [[ "$s" == "$e" ]] && found=1; done
    if [[ "$found" != "1" ]]; then
      echo "FAIL: $b needs unexpected CUDA soname $s (expected ${EXPECTED_SONAMES[*]})"; fail=1
    fi
  done
done

echo "=== Gate 2: cuobjdump --list-elf (only sm_75) ==="
for b in "${BINARIES[@]}"; do
  elf_out=$("$CUOBJDUMP" --list-elf "$BIN_DIR/$b" 2>/tmp/cuobjdump.err) || {
    echo "note: cuobjdump failed on $b ($(cat /tmp/cuobjdump.err)); trying libggml-cuda.a"
    cuda_lib=$(find build -name 'libggml-cuda.a' | head -n1)
    [[ -n "$cuda_lib" ]] || { echo "FAIL: no libggml-cuda.a found for $b"; fail=1; continue; }
    elf_out=$("$CUOBJDUMP" --list-elf "$cuda_lib") || { echo "FAIL: cuobjdump failed on $cuda_lib"; fail=1; continue; }
  }
  archs=$(echo "$elf_out" | grep -oE 'sm_[0-9]+[a-z]?' | sort -u || true)
  echo "--- $b: ${archs:-<none found>} ---"
  if [[ -z "$archs" ]]; then
    echo "FAIL: $b: no sm_* ELF images found"; fail=1; continue
  fi
  for a in $archs; do
    [[ "$a" == "sm_75" ]] || { echo "FAIL: $b contains $a (expected only sm_75)"; fail=1; }
  done
done

echo "=== Gate 3: --version (warn-only: libcuda.so.1 is driver-provided, absent on GPU-less runners) ==="
"$BIN_DIR/llama-server" --version || echo "note: llama-server --version failed (expected without a driver); verify on the target"
"$BIN_DIR/llama-cli" --version || echo "note: llama-cli --version failed (expected without a driver); verify on the target"

[[ "$fail" == "0" ]] || { echo "verification gates FAILED"; exit 1; }

echo "=== Packaging ==="
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp "${BINARIES[@]/#/$BIN_DIR/}" "$STAGE/"
cp src/LICENSE "$STAGE/LICENSE"
cp check-runtime.sh "$STAGE/check-runtime.sh"
chmod +x "$STAGE/check-runtime.sh"

OS_PRETTY=$(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"' || echo unknown)
CUDA_PKG=$(dpkg-query -W -f='${Version}' "cuda-compiler-${CUDA_MM}" 2>/dev/null || echo unknown)
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "$STAGE/BUILD_INFO.json" <<EOF
{
  "source": {
    "name": "${NAME}",
    "repo": "${REPO}",
    "ref": "${REF}",
    "sha": "${SHA}",
    "url": "https://github.com/${REPO}/tree/${SHA}"
  },
  "tag": "${TAG}",
  "prerelease": ${PRERELEASE},
  "build": {
    "date_utc": "${BUILD_DATE}",
    "runner": "ubuntu-24.04",
    "container": "ubuntu:${UBUNTU}",
    "os": "${OS_PRETTY}",
    "cuda": "${CUDA}",
    "cuda_major": ${CUDA_MAJOR},
    "cuda_package": "${CUDA_PKG}",
    "cmake_flags": "-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=75-real -DGGML_NATIVE=OFF -DGGML_CUDA_FA_ALL_QUANTS=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_CUDA_COMPILER_LAUNCHER=ccache -DCMAKE_EXE_LINKER_FLAGS=-static-libgcc -static-libstdc++ -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF",
    "targets": ["llama-server", "llama-cli", "llama-bench", "llama-quantize", "llama-perplexity"],
    "ggml_cuda_fa_all_quants": false,
    "cuda_arch": "75-real",
    "build_shared_libs": false,
    "cuda_runtime_library": "Shared"
  }
}
EOF

mkdir -p dist
tar -czf "dist/${ASSET}" -C "$STAGE" .
SIZE=$(stat -c%s "dist/${ASSET}")
echo "archive: dist/${ASSET} (${SIZE} bytes)"
if (( SIZE < 1000000 || SIZE > 250000000 )); then
  echo "FAIL: archive size ${SIZE} bytes outside expected range [1MB, 250MB]" >&2
  exit 1
fi
sha256sum "dist/${ASSET}"
