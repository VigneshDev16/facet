#!/bin/bash
# One-time setup: fetch and convert the ML models Facet needs, then compile them
# into the app's resources. Model weights aren't committed — they're large and
# reproducible from this script.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

echo "==> 1/4  Python 3.12 toolchain (torch + coremltools)"
if [ ! -d .venv-convert ]; then
  bash scripts/setup_convert_env.sh
else
  echo "    already present, skipping"
fi
source .venv-convert/bin/activate

echo "==> 2/4  ArcFace face-recognition model (ONNX -> CoreML)"
mkdir -p models/src
if [ ! -f models/src/arcface_w600k_r50.onnx ]; then
  curl -# -L -o models/src/arcface_w600k_r50.onnx \
    "https://huggingface.co/immich-app/buffalo_l/resolve/main/recognition/model.onnx"
fi
if [ ! -d models/ArcFace.mlpackage ]; then
  python scripts/convert_arcface.py
else
  echo "    already converted, skipping"
fi

echo "==> 3/4  Apple MobileCLIP + CLIP tokenizer vocabulary"
if [ ! -d models/mobileclip_s2_image.mlpackage ]; then
  bash scripts/fetch_mobileclip.sh
else
  echo "    already fetched, skipping"
fi

echo "==> 4/4  Compiling models into app resources"
mkdir -p Sources/Facet/Resources/Models
for m in ArcFace mobileclip_s2_image mobileclip_s2_text; do
  if [ ! -d "Sources/Facet/Resources/Models/$m.mlmodelc" ]; then
    xcrun coremlcompiler compile "models/$m.mlpackage" Sources/Facet/Resources/Models/
    echo "    compiled $m"
  fi
done
cp -f models/src/bpe_simple_vocab_16e6.txt Sources/Facet/Resources/bpe_simple_vocab_16e6.txt

echo
echo "Done. Build the app with:  bash scripts/build_app.sh"
