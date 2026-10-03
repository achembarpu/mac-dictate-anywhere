#!/usr/bin/env python3
"""Collect Mend outputs for the shared cleanup-prompts benchmark scorer.

Run in an isolated environment with torch, transformers and sentencepiece.
Weights use the normal Hugging Face cache. No app preferences are changed.
"""

import argparse
import hashlib
import json
from pathlib import Path
from time import perf_counter

import torch
from transformers import AutoModelForSeq2SeqLM, AutoTokenizer

MODEL = "daltonoscar0/mend-flan-t5-small"
REVISION = "230a456089ac0c03d331546a56a5ac2ed9f26271"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", choices=["cpu", "mps"], default="mps")
    parser.add_argument("--iterations", type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 10:
        parser.error("iterations must be between 1 and 10")
    if args.device == "mps" and not torch.backends.mps.is_available():
        parser.error("MPS is unavailable; select cpu explicitly")
    manifest = Path(__file__).resolve().parents[1] / "Dictate AnywhereTests/Fixtures/Golden/cleanup-golden-manifest.json"
    source = manifest.read_bytes()
    fixtures = json.loads(source)
    started = perf_counter()
    tokenizer = AutoTokenizer.from_pretrained(MODEL, revision=REVISION, trust_remote_code=False)
    model = AutoModelForSeq2SeqLM.from_pretrained(MODEL, revision=REVISION, trust_remote_code=False).eval().to(args.device)
    if args.device == "mps":
        torch.mps.synchronize()
    preparation_ms = (perf_counter() - started) * 1000
    rows = []
    skipped = []
    for fixture in fixtures:
        if fixture["language"] != "en":
            continue
        # Exact model-card register and task prefix. Do not substitute the
        # application's general instruction prompt for the trained T5 prefix.
        text = "clean up: " + fixture["input"].lower().strip(" .,!?:;\n\t")
        encoded = tokenizer(text, return_tensors="pt", truncation=False).to(args.device)
        input_tokens = encoded["input_ids"].shape[1]
        if input_tokens > 512:
            skipped.append({"fixture": fixture["id"], "input_tokens": input_tokens, "reason": "outside-short-input-evaluation"})
            continue
        for iteration in range(args.iterations):
            started = perf_counter()
            with torch.inference_mode():
                generated = model.generate(**encoded, max_new_tokens=512, do_sample=False)
            if args.device == "mps":
                torch.mps.synchronize()
            latency_ms = (perf_counter() - started) * 1000
            tokens = generated[0].tolist()
            rows.append({"fixture": fixture["id"], "model": MODEL, "iteration": iteration,
                         "latency_ms": latency_ms, "input_tokens": input_tokens,
                         "output": tokenizer.decode(tokens, skip_special_tokens=True),
                         "completed": model.config.eos_token_id in tokens})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"model": MODEL, "revision": REVISION, "device": args.device,
                                     "torch": torch.__version__, "manifest_sha256": hashlib.sha256(source).hexdigest(),
                                     "preparation_ms": preparation_ms, "skipped": skipped, "rows": rows}, indent=2) + "\n")
    print(f"Collected {len(rows)} outputs; {len(skipped)} unsupported inputs. Score with cleanup-prompts.")


if __name__ == "__main__":
    main()
