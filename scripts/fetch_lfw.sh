#!/bin/bash
# Fetches the LFW benchmark used to validate the face pipeline.
#
#   build/lfw_pairs/    the official 2200-pair verification protocol
#   build/lfw_library/  the same images arranged one folder per identity,
#                       used as ground truth for clustering quality
#
# Then:
#   ./.build/release/Facet --selftest --pairs build/lfw_pairs
#   ./.build/release/Facet --selftest --index build/lfw_library --library /tmp/bench
set -euo pipefail
cd "$(dirname "$0")/.."
source .venv-convert/bin/activate 2>/dev/null || {
  echo "run scripts/bootstrap.sh first (needs the Python env)"; exit 1; }
pip install -q pandas pyarrow

mkdir -p build
if [ ! -f build/lfw_pairs_test.parquet ]; then
  echo "==> downloading LFW pairs"
  curl -# -L -o build/lfw_pairs_test.parquet \
    "https://huggingface.co/datasets/logasja/lfw/resolve/main/pairs/test-00000-of-00001.parquet"
fi

python - <<'PY'
import pandas as pd, json, os, re, collections, shutil
df = pd.read_parquet("build/lfw_pairs_test.parquet")

out = "build/lfw_pairs"; os.makedirs(out, exist_ok=True)
labels = []
for i, r in df.iterrows():
    a, b = f"{out}/{i:05d}_a.jpg", f"{out}/{i:05d}_b.jpg"
    open(a, "wb").write(r["img_0"]["bytes"])
    open(b, "wb").write(r["img_1"]["bytes"])
    labels.append({"a": os.path.basename(a), "b": os.path.basename(b), "same": int(r["pair"])})
json.dump(labels, open(f"{out}/labels.json", "w"))
print(f"pairs: {len(labels)}")

lib = "build/lfw_library"; shutil.rmtree(lib, ignore_errors=True)
seen = {}
for _, r in df.iterrows():
    for k in ("img_0", "img_1"):
        p, b = r[k]["path"], r[k]["bytes"]
        seen.setdefault((re.sub(r"_\d{4}\.jpg$", "", p), p), b)
counts = collections.Counter(i for i, _ in seen)
keep = {i for i, c in counts.items() if c >= 4}
n = 0
for (ident, p), b in seen.items():
    if ident not in keep: continue
    d = os.path.join(lib, ident); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, p), "wb").write(b); n += 1
print(f"identities: {len(keep)}, images: {n}")
PY
