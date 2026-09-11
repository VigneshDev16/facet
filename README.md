# Facet

A native macOS photo gallery that indexes folders you import, finds every face,
and groups them into people — plus natural-language search over your photos.
Everything runs locally on the Neural Engine; nothing leaves the machine.

![built with SwiftUI](https://img.shields.io/badge/SwiftUI-macOS%2015%2B-blue)
![licence](https://img.shields.io/badge/licence-AGPL--3.0-green)
![LFW](https://img.shields.io/badge/LFW%20verification-99.32%25-brightgreen)

> **Cloning this?** Run `bash scripts/bootstrap.sh` first. Model weights are ~270 MB
> and aren't committed, so `swift build` fails until that's done. The script fetches
> and converts everything in one go.

## What it does

- **Import folders** — point it at any folders; it scans recursively and watches for changes on rescan.
- **Automatic people grouping** — every face is detected, aligned, embedded, and clustered. Name a
  person once and new photos of them join that group.
- **Search by example face** — click any face in a photo to pull up every other photo containing them.
- **Combine people filters** — "photos with A *and* B", or "A *without* B".
- **Text search** — type `beach sunset`, `birthday cake`, `dog in snow`.

## How it works

| Stage | Implementation |
|---|---|
| Decode / thumbnails | ImageIO, embedded-thumbnail fast path, EXIF orientation baked in |
| Face detection | Apple **Vision** (`DetectFaceLandmarksRequest` + capture quality) |
| Alignment | 5-point closed-form 2D Procrustes onto the InsightFace 112×112 template |
| Face embedding | **ArcFace** `w600k_r50` (InsightFace buffalo_l), ONNX → CoreML fp16, 512-d |
| Scene embedding | Apple **MobileCLIP-S2** image tower, 512-d |
| Text queries | MobileCLIP-S2 text tower + a from-scratch Swift port of CLIP's byte-level BPE tokenizer |
| Index | SQLite (WAL) for metadata; flat `Float32` vector files searched with Accelerate BLAS |
| Clustering | Incremental centroid assignment (blocked `sgemm`) + centroid merge pass |

One decode per photo feeds the thumbnail, face, and scene stages — decoding dominates the cost.

## Measured results

Validated against the standard **LFW** benchmark with this exact detect→align→embed chain:

- **99.32%** LFW verification accuracy (matches published ArcFace numbers — confirms alignment is correct)
- **~250 images/s** face pipeline throughput on Apple Silicon
- End-to-end clustering over 127 identities: **0.993 pairwise precision**, 0.92 F1
- CLIP tokenizer matches the OpenAI reference **exactly** across accents, emoji, and contractions

Run the suite yourself:

```bash
swift build -c release && ./.build/release/Facet --selftest --fixtures build/tokenizer_fixtures.json
```

The grouping threshold (default **0.46**) was picked from a sweep where F1 peaks across
0.44–0.52 and collapses by 0.62. It's adjustable in Settings → Face Matching.

## Viewing from your phone

Facet can serve a read-only mobile web app over your own private network.
Settings → **Sharing**: add an account per person, flip **Share my library**, and open
the address it shows on the phone (Share → *Add to Home Screen* makes it app-like).

The sharing surface is read-only **by construction** — there are no write endpoints at
all, so viewers can browse, search and download but cannot delete, rename or re-group
anything. Library management stays in the Mac app.

Transport is [Tailscale](https://tailscale.com) (free): your devices get private
addresses that work over cellular, with no port forwarding and nothing exposed publicly.
For family who won't install it, `tailscale funnel --bg 8765` publishes an HTTPS link —
Facet's own login still gates access.

Security properties, all covered by the test suite in `scripts/test_sharing.sh`:

- Passwords stored as PBKDF2-HMAC-SHA256, 210k iterations, 16-byte random salt
- Session tokens are 256-bit random, stored only as SHA-256 digests
- Login is constant-time and runs the KDF even for unknown users, so timing doesn't leak validity
- Failed logins back off exponentially (30s → 15min) per username+IP
- Every API and asset route 401s without a valid session; only `/` serves the login page
- `HttpOnly`, `SameSite=Lax` cookies; `Secure` added automatically behind HTTPS
- Strict CSP, `nosniff`, `X-Frame-Options: DENY`

**The Mac must be awake to serve.** Facet holds a power assertion while sharing is on
(the "Keep this Mac awake" switch); without it an idle Mac sleeps and phones can't connect.

## Build

```bash
bash scripts/bootstrap.sh   # once: fetch + convert models
bash scripts/build_app.sh
```

Produces `dist/Facet.app` (ad-hoc signed). First launch: right-click → Open, since it
isn't notarised. The library lives in `~/Library/Application Support/Facet`; set
`FACET_LIBRARY` to point at a different one for testing.

## First-time setup

Model weights aren't in the repo — they're ~270 MB and exceed GitHub's file limit, but
they're fully reproducible. One command fetches and converts them:

```bash
bash scripts/bootstrap.sh
```

That builds a Python 3.12 toolchain, downloads ArcFace, converts it ONNX → CoreML
(validating the result numerically against ONNX Runtime), fetches Apple's MobileCLIP
and the CLIP vocabulary, and compiles everything into the app's resources.
Then `bash scripts/build_app.sh`.

## Reproducing the benchmarks

```bash
bash scripts/fetch_lfw.sh                    # LFW pairs + identity folders
python scripts/make_tokenizer_fixtures.py    # CLIP reference tokenisations
./.build/release/Facet --selftest --fixtures build/tokenizer_fixtures.json \
                       --pairs build/lfw_pairs
./.build/release/Facet --selftest --index build/lfw_library --library /tmp/bench
bash scripts/test_sharing.sh                 # 25 security checks on the web server
```

## Licensing

Facet itself is **AGPL-3.0** (see `LICENSE`): you're free to use, modify and self-host it,
but if you deploy a modified version as a network service you must publish your source.

Model weights are *not* covered by that and carry their own terms:

- **ArcFace / buffalo_l** weights come from InsightFace, released for **non-commercial
  research use**. Fine for personal use; check the terms before shipping this commercially.
- **MobileCLIP** weights are Apple's, under their accompanying license.
- The LFW data used for benchmarking is for research evaluation only and isn't bundled.

## Layout

```
Sources/Facet/
  Store/      SQLite wrapper, schema, vector store
  Pipeline/   decode, detect, align, embed, cluster, index
  UI/         SwiftUI views
  Support/    self-test + benchmark harnesses
scripts/      model conversion and app packaging
```
