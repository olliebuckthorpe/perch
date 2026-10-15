# One-time conversion of BAAI/bge-small-en-v1.5 (model.safetensors sha256 3c9f3166...21ad) to Core ML.
# Run with torch 2.7.0, transformers 4.x, coremltools 9 in a throwaway env: python convert.py <model dir> <out dir>
import sys, numpy as np, torch, coremltools as ct
from transformers import AutoModel, AutoTokenizer
src, out = sys.argv[1], sys.argv[2]
tok = AutoTokenizer.from_pretrained(src); model = AutoModel.from_pretrained(src, dtype=torch.float32).eval()
class Wrap(torch.nn.Module):
    def __init__(s, m): super().__init__(); s.m = m
    def forward(s, ids, mask):
        h = s.m(input_ids=ids, attention_mask=mask).last_hidden_state[:, 0]
        return torch.nn.functional.normalize(h, dim=-1)
w = Wrap(model).eval()
ex = tok(["hello world"], padding="max_length", max_length=128, return_tensors="pt")
traced = torch.jit.trace(w, (ex["input_ids"].int(), ex["attention_mask"].int()))
shape = ct.EnumeratedShapes(shapes=[[1, 64], [1, 128], [1, 256]], default=[1, 128])
ml = ct.convert(traced, inputs=[ct.TensorType(name="ids", shape=shape, dtype=np.int32), ct.TensorType(name="mask", shape=shape, dtype=np.int32)],
                outputs=[ct.TensorType(name="embedding")], minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16)
ml.save(f"{out}/bge-fp16.mlpackage")
from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
q = linear_quantize_weights(ml, OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")))
q.save(f"{out}/bge-int8.mlpackage")
# Compare against the original on sample sentences.
texts = ["Fix the Slack history loading slowly in Perch", "Build the pricing page for Upshow with three plans", "Normalize company names in the contact CSV", "Set up Cloudflare deploy for the Pipeline Engine site", "Write a LinkedIn post about churn", "website hosting", "clean up lead list", "plans and prices", "slack messages slow", "social media copy"]
def ref(t):
    e = tok([t], padding="max_length", max_length=128, truncation=True, return_tensors="pt")
    with torch.no_grad(): return w(e["input_ids"].int(), e["attention_mask"].int())[0].numpy()
def run(m, t):
    e = tok([t], padding="max_length", max_length=128, truncation=True, return_tensors="np")
    return m.predict({"ids": e["input_ids"].astype(np.int32), "mask": e["attention_mask"].astype(np.int32)})["embedding"][0]
for name, m in [("fp16", ml), ("int8", q)]:
    sims = [float(np.dot(ref(t), run(m, t)) / np.linalg.norm(run(m, t))) for t in texts]
    print(name, "min agreement with original", round(min(sims), 4))
R = np.array([ref(t) for t in texts[:5]])
for qy in texts[5:]:
    s = R @ ref(qy); print(qy, "->", texts[int(np.argmax(s))], np.round(np.sort(s)[::-1][:2], 3))
