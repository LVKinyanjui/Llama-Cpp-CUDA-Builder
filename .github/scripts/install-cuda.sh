#!/usr/bin/env bash
# Installs the minimal CUDA toolkit from NVIDIA's apt network repo.
# Usage: install-cuda.sh <ubuntu-version> <cuda-version>   e.g. 22.04 12.8
set -euo pipefail

UBUNTU="${1:?usage: install-cuda.sh <ubuntu> <cuda>}"
CUDA="${2:?usage: install-cuda.sh <ubuntu> <cuda>}"

case "$UBUNTU" in
  22.04) DISTRO=ubuntu2204 ;;
  24.04) DISTRO=ubuntu2404 ;;
  *) echo "unsupported ubuntu: $UBUNTU (expected 22.04 or 24.04)" >&2; exit 1 ;;
esac

MM="${CUDA/./-}" # 12.8 -> 12-8, 13.0 -> 13-0
S=$(command -v sudo || true)

KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/${DISTRO}/x86_64/cuda-keyring_1.1-1_all.deb"
echo "installing cuda-keyring from $KEYRING_URL"
curl -fsSL "$KEYRING_URL" -o /tmp/cuda-keyring.deb
$S dpkg -i /tmp/cuda-keyring.deb
$S apt-get update
$S apt-get install -y --no-install-recommends \
  "cuda-compiler-${MM}" "cuda-libraries-dev-${MM}" "cuda-cuobjdump-${MM}" "cuda-nvml-dev-${MM}"

echo "--- nvcc ---"
"/usr/local/cuda-${CUDA}/bin/nvcc" --version
echo "--- cuobjdump ---"
"/usr/local/cuda-${CUDA}/bin/cuobjdump" --version
