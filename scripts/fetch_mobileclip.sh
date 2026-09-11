#!/bin/bash
set -euo pipefail
cd /Users/vicky/Desktop/Vignesh/codebase/VibeCodedProjects/facet
BASE="https://huggingface.co/apple/coreml-mobileclip/resolve/main"
for part in image text; do
  PKG="mobileclip_s2_${part}.mlpackage"
  mkdir -p "models/$PKG/Data/com.apple.CoreML/weights"
  curl -sSL -o "models/$PKG/Manifest.json" "$BASE/$PKG/Manifest.json"
  curl -sSL -o "models/$PKG/Data/com.apple.CoreML/model.mlmodel" "$BASE/$PKG/Data/com.apple.CoreML/model.mlmodel"
  curl -sSL -o "models/$PKG/Data/com.apple.CoreML/weights/weight.bin" "$BASE/$PKG/Data/com.apple.CoreML/weights/weight.bin"
  echo "fetched $PKG"
done
echo "==> CLIP BPE vocab"
curl -sSL -o models/src/bpe_simple_vocab_16e6.txt.gz \
  "https://raw.githubusercontent.com/openai/CLIP/main/clip/bpe_simple_vocab_16e6.txt.gz"
gunzip -kf models/src/bpe_simple_vocab_16e6.txt.gz
cp models/src/bpe_simple_vocab_16e6.txt Sources/Facet/Resources/bpe_simple_vocab_16e6.txt
du -sh models/*.mlpackage models/src/bpe_simple_vocab_16e6.txt
