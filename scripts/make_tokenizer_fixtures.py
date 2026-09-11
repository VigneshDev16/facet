"""Generate CLIP tokenizer fixtures from OpenAI's reference implementation.

The Swift port in Sources/Facet/Pipeline/CLIPTokenizer.swift is validated against
these by `Facet --selftest --fixtures build/tokenizer_fixtures.json`.
The reference file is fetched rather than vendored, so its MIT licence stays with
the upstream project.
"""
import json, os, shutil, subprocess, sys, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REF = os.path.join(HERE, "_ref_simple_tokenizer.py")
VOCAB_GZ = os.path.join(HERE, "bpe_simple_vocab_16e6.txt.gz")

if not os.path.exists(REF):
    urllib.request.urlretrieve(
        "https://raw.githubusercontent.com/openai/CLIP/main/clip/simple_tokenizer.py", REF)
if not os.path.exists(VOCAB_GZ):
    src = os.path.join(ROOT, "models/src/bpe_simple_vocab_16e6.txt.gz")
    if os.path.exists(src):
        shutil.copy(src, VOCAB_GZ)
    else:
        urllib.request.urlretrieve(
            "https://raw.githubusercontent.com/openai/CLIP/main/clip/bpe_simple_vocab_16e6.txt.gz",
            VOCAB_GZ)

sys.path.insert(0, HERE)
import _ref_simple_tokenizer as ref

tok = ref.SimpleTokenizer(bpe_path=VOCAB_GZ)
SOT, EOT = tok.encoder["<|startoftext|>"], tok.encoder["<|endoftext|>"]

CASES = [
    "a photo of a dog", "beach sunset", "birthday cake with candles",
    "Two people HIKING in the mountains!", "  multiple   spaces\tand\nnewlines ",
    "café naïve résumé", "2019 wedding photos", "dog's toy", "don't stop",
    "emoji 🎂 party", "snow-covered trees", "a red car parked outside a house",
    "", "x", "ABCdef123!@#",
]

out = []
for c in CASES:
    ids = tok.encode(c)
    full = [SOT] + ids[:75] + [EOT]
    full += [0] * (77 - len(full))
    out.append({"text": c, "ids": ids, "full77": full})

os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
dest = os.path.join(ROOT, "build/tokenizer_fixtures.json")
json.dump(out, open(dest, "w"), ensure_ascii=False, indent=1)
print(f"wrote {len(out)} fixtures -> {dest}")
