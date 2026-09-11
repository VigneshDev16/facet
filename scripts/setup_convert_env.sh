#!/bin/bash
set -euo pipefail
ROOT="/Users/vicky/Desktop/Vignesh/codebase/VibeCodedProjects/facet"
cd "$ROOT"
echo "==> Installing python@3.12 via brew"
brew install python@3.12 2>&1 | tail -5
PY=$(brew --prefix python@3.12)/bin/python3.12
echo "Using $PY"; $PY -V
rm -rf .venv-convert
$PY -m venv .venv-convert
source .venv-convert/bin/activate
python -m pip install -q --upgrade pip
echo "==> Installing torch + coremltools + onnx2torch"
pip install -q torch torchvision coremltools onnx onnx2torch numpy pillow
python - <<'PY'
import coremltools as ct, torch, onnx2torch
print("coremltools", ct.__version__)
print("torch", torch.__version__)
from coremltools.libmilstoragepython import _BlobWriter  # fatal if missing
print("BlobWriter OK -> native extensions loaded")
PY
