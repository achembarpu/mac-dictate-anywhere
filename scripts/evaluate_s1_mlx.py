#!/usr/bin/env python3
"""Collect MLX S1 outputs for the existing cleanup-prompts golden scorer.

Use locally converted author weights and an isolated mlx-lm environment. This
is a research harness, not an app backend or an automatic model download.
"""

import argparse
import hashlib
import importlib.metadata
import json
import math
from pathlib import Path
import re
from time import perf_counter

import mlx.core as mx
from mlx_lm import load
from mlx_lm.generate import generate_step
from mlx_lm.sample_utils import make_sampler

AUTHOR_REVISION = "88f6b15896c73bbb13a3b596e0afe8ea0d5150b4"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--kv-bits", type=int, choices=[8, 16], default=16)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 10:
        parser.error("iterations must be between 1 and 10")
    if not args.model_path.is_dir():
        parser.error("model-path must be a local converted model directory")
    root = Path(__file__).resolve().parents[1]
    manifest = root / "Dictate AnywhereTests/Fixtures/Golden/cleanup-golden-manifest.json"
    swift = root / "Dictate Anywhere/S1MiniPostProcessingService.swift"
    match = re.search(r'static let systemPrompt = ("[^\n]+")', swift.read_text())
    if match is None:
        raise ValueError("Cannot find the production S1 system prompt")
    system = json.loads(match.group(1))
    control = "[Styling: semi-formal] [Structure: prose] [Context: general]"
    started = perf_counter()
    model, tokenizer = load(str(args.model_path), tokenizer_config={"trust_remote_code": False})
    mx.synchronize()
    loading_ms = (perf_counter() - started) * 1000

    def run(text: str) -> dict:
        started = perf_counter()
        input_tokens = len(tokenizer.encode(text, add_special_tokens=False))
        if input_tokens > 1000:
            raise ValueError("This probe requires single-pass inputs within the author's 1000-token limit")
        manual = (f"<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n"
                  f"{control}\n{text}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
        author = tokenizer.apply_chat_template(
            [{"role": "system", "content": system}, {"role": "user", "content": control + "\n" + text}],
            tokenize=False, add_generation_prompt=True, enable_thinking=False,
        )
        if manual != author:
            raise ValueError("Author template differs from the exact production non-thinking prompt")
        prompt = tokenizer.encode(author, add_special_tokens=False)
        maximum = math.ceil(input_tokens * 1.3) + 32
        output_tokens = []
        completed = False
        # New KV cache per request, greedy, one additional EOS probe matching
        # the app. A partial response is retained as evidence, never success.
        stream = generate_step(mx.array(prompt), model, max_tokens=maximum + 1,
                               sampler=make_sampler(temp=0), prefill_step_size=512,
                               kv_bits=8 if args.kv_bits == 8 else None,
                               quantized_kv_start=0)
        for token, _ in stream:
            if token in tokenizer.eos_token_ids:
                completed = True
                break
            if len(output_tokens) == maximum:
                break
            output_tokens.append(token)
        stream.close()
        mx.synchronize()
        output = tokenizer.decode(output_tokens).strip()
        return {"latency_ms": (perf_counter() - started) * 1000, "output": output,
                "completed": completed, "input_tokens": input_tokens,
                "prompt_tokens": len(prompt), "output_tokens": len(output_tokens)}

    first = run("Hello.")
    warmed = run("Hello.")
    rows = []
    skipped = []
    for fixture in json.loads(manifest.read_bytes()):
        if fixture["language"] != "en" or fixture.get("vocabulary"):
            continue
        if len(tokenizer.encode(fixture["input"], add_special_tokens=False)) > 1000:
            skipped.append({"fixture": fixture["id"], "reason": "outside-single-pass-token-limit"})
            continue
        for iteration in range(args.iterations):
            row = run(fixture["input"])
            row.update(fixture=fixture["id"], model=f"s1-mlx-{args.model_path.name}-kv{args.kv_bits}", iteration=iteration)
            rows.append(row)
            print(f"{row['model']} {row['fixture']} {iteration} {row['latency_ms']:.1f} ms completed={row['completed']}", flush=True)
    report = {"author_revision": AUTHOR_REVISION, "manifest_sha256": sha256(manifest),
              "script_sha256": sha256(Path(__file__)), "prompt_source_sha256": sha256(swift),
              "runtime_versions": {name: importlib.metadata.version(name) for name in ("mlx", "mlx-lm", "transformers")},
              "weight_sha256": {file.name: sha256(file) for file in args.model_path.glob("*.safetensors")},
              "model_config": json.loads((args.model_path / "config.json").read_text()),
              "kv_bits": args.kv_bits, "loading_ms": loading_ms, "first_decode": first, "prewarm_decode": warmed,
              "peak_mlx_bytes": mx.get_peak_memory(), "skipped": skipped, "rows": rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
