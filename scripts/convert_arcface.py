"""ONNX ArcFace (buffalo_l w600k_r50) -> CoreML .mlpackage, with numeric validation."""
import numpy as np, torch, coremltools as ct, onnxruntime as ort
from onnx2torch import convert
from PIL import Image

SRC = "models/src/arcface_w600k_r50.onnx"
DST = "models/ArcFace.mlpackage"

print("==> onnx2torch")
tm = convert(SRC).eval()

ex = torch.rand(1, 3, 112, 112) * 2 - 1
with torch.no_grad():
    ts = torch.jit.trace(tm, ex)
    ts = torch.jit.freeze(ts)

print("==> coremltools convert (fp16)")
# ArcFace preprocessing is (rgb - 127.5)/127.5, folded into the image input.
mlmodel = ct.convert(
    ts,
    inputs=[ct.ImageType(name="image", shape=(1, 3, 112, 112),
                         scale=1.0 / 127.5, bias=[-1.0, -1.0, -1.0],
                         color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.macOS15,
    compute_precision=ct.precision.FLOAT16,
    compute_units=ct.ComputeUnit.ALL,
)
mlmodel.short_description = "InsightFace buffalo_l ArcFace (w600k_r50) 512-d face embedding"
mlmodel.save(DST)
print("saved", DST)

print("==> validating vs onnxruntime")
sess = ort.InferenceSession(SRC, providers=["CPUExecutionProvider"])
iname = sess.get_inputs()[0].name

def cos(a, b):
    a = a.ravel(); b = b.ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))

rng = np.random.default_rng(0)
sims = []
for t in range(5):
    u8 = rng.integers(0, 256, (112, 112, 3), dtype=np.uint8)
    nchw = ((u8.astype(np.float32) - 127.5) / 127.5).transpose(2, 0, 1)[None]
    ref = sess.run(None, {iname: nchw})[0]
    got = mlmodel.predict({"image": Image.fromarray(u8)})["embedding"]
    sims.append(cos(ref, np.asarray(got)))
print("cosine(onnx, coreml) per trial:", [round(s, 5) for s in sims])
worst = min(sims)
print("WORST", round(worst, 5))
assert worst > 0.995, f"conversion drift too high: {worst}"
print("VALIDATION PASSED")
