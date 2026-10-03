#!/usr/bin/env python3
"""Collect local Qwen3-ASR 0.6B outputs for the shared Swift scorer.

Requires the reviewed mlx-audio 0.5.7 / MLX 0.32.3 research environment.
No model download/server/microphone is started. Select exact short goldens and
an explicit local checkpoint plus the pinned public Hugging Face file metadata.
"""

import argparse
import dataclasses
import hashlib
import importlib.metadata
import json
import os
import platform
import resource
from pathlib import Path
from time import perf_counter


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", type=Path, required=True)
    parser.add_argument("--model-metadata", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", action="append", required=True, help="Exact IDs; repeat for a bounded screen")
    parser.add_argument("--iterations", type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 10:
        parser.error("iterations must be between 1 and 10")
    if not args.model_path.is_dir() or not args.model_metadata.is_file():
        parser.error("Select existing local model assets and pinned file metadata")
    for name, version in (("mlx-audio", "0.5.7"), ("mlx", "0.32.3")):
        if importlib.metadata.version(name) != version:
            parser.error(f"This collector requires the reviewed {name} {version} API")

    metadata = json.loads(args.model_metadata.read_bytes())
    checkpoints = {"mlx-community/Qwen3-ASR-0.6B-4bit": "313d850181767edf09f00a9c289becca70e58cd0",
                   "mlx-community/Qwen3-ASR-0.6B-8bit": "89e96d92ba34aca20b3e29fb10cc284097d1219f"}
    if metadata["id"] not in checkpoints or metadata["sha"] != checkpoints[metadata["id"]]:
        parser.error("Select the screened Qwen3-ASR checkpoint revision")
    bits = 4 if metadata["id"].endswith("-4bit") else 8
    assets = []
    for entry in metadata["siblings"]:
        name = entry["rfilename"]
        if name == ".gitattributes":
            continue
        if Path(name).name != name:
            parser.error("Unexpected model dependency path")
        path = args.model_path / name
        checksum = sha256(path)
        if path.stat().st_size != entry["size"]:
            raise ValueError(f"Model size differs: {name}")
        if "lfs" in entry:
            matches = checksum == entry["lfs"]["sha256"]
        else:
            data = path.read_bytes()
            # Public git blob IDs authenticate small config/tokenizer assets;
            # SHA256 authenticates the streamed LFS weight file separately.
            matches = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest() == entry["blobId"]
        if not matches:
            raise ValueError(f"Model checksum differs: {name}")
        assets.append({"name": name, "bytes": path.stat().st_size, "sha256": checksum})
    config = json.loads((args.model_path / "config.json").read_bytes())
    tokenizer_config = json.loads((args.model_path / "tokenizer_config.json").read_bytes())
    if config.get("model_type") != "qwen3_asr" or config.get("quantization") != {"group_size": 64, "bits": bits, "mode": "affine"}:
        parser.error("Unexpected architecture or quantization")
    # The SDK requests trust_remote_code, but this pinned checkpoint uses the
    # builtin tokenizer, no auto_map and no Python assets. Stay offline too.
    if config.get("auto_map") or tokenizer_config.get("auto_map") or list(args.model_path.glob("*.py")):
        parser.error("Custom model/tokenizer code is outside this screen")

    root = Path(__file__).resolve().parents[1]
    golden = root / "Dictate AnywhereTests/Fixtures/Golden"
    manifest = golden / "golden-speech-manifest.json"
    fixtures = json.loads(manifest.read_bytes())
    if set(args.fixture) - {fixture["id"] for fixture in fixtures}:
        parser.error("Unknown golden fixture ID")
    fixtures = [fixture for fixture in fixtures if fixture["id"] in args.fixture]
    if any(fixture["sampleCount"] > 480_000 for fixture in fixtures):
        parser.error("This short-utterance gate accepts at most 30 seconds; no unverified segmentation")
    for fixture in fixtures:
        for key, hash_key in (("audio", "audioSHA256"), ("reference", "referenceSHA256")):
            if sha256(golden / fixture[key]) != fixture[hash_key]:
                raise ValueError(f"Fixture checksum differs: {fixture['id']}")

    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    import mlx.core as mx
    import soundfile as sf
    from mlx_audio.stt.utils import load

    if not mx.metal.is_available():
        parser.error("Run this Apple Silicon research screen with a Metal device")
    maximum_tokens = 256  # Author's short-input recommendation; SDK defaults to 8192.
    options = {"max_tokens": maximum_tokens, "batch_size": 1, "temperature": 0.0,
               "language": None, "verbose": False}
    started = perf_counter()
    model = load(args.model_path.resolve(), strict=True)
    mx.synchronize()
    loading_ms = (perf_counter() - started) * 1000
    rows = []
    for fixture in fixtures:
        path = golden / fixture["audio"]
        audio, rate = sf.read(path, dtype="float32")
        if rate != 16_000 or audio.ndim != 1 or len(audio) != fixture["sampleCount"]:
            raise ValueError(f"Unexpected audio format: {fixture['id']}")
        first = perf_counter()
        model.generate(audio=audio, **options)
        mx.synchronize()
        first_file_ms = (perf_counter() - first) * 1000
        for iteration in range(args.iterations):
            mx.synchronize()
            mx.reset_peak_memory()
            before = resource.getrusage(resource.RUSAGE_SELF)
            started = perf_counter()
            samples, _ = sf.read(path, dtype="float32")
            output = model.generate(audio=samples, **options)
            mx.synchronize()
            latency_ms = (perf_counter() - started) * 1000
            after = resource.getrusage(resource.RUSAGE_SELF)
            native = dataclasses.asdict(output)
            if len(output.segments or []) != 1:
                raise RuntimeError("Short input did not produce exactly one covered segment")
            exhausted = output.generation_tokens >= maximum_tokens
            rows.append({"model": f"qwen3-asr-0.6b-{bits}bit-auto", "fixture": fixture["id"],
                "iteration": iteration, "output": output.text, "latency_ms": latency_ms,
                "first_file_ms": first_file_ms, "audio_seconds": len(audio) / rate,
                "cpu_ms": ((after.ru_utime + after.ru_stime) - (before.ru_utime + before.ru_stime)) * 1000,
                "process_peak_rss_bytes": after.ru_maxrss if platform.system() == "Darwin" else after.ru_maxrss * 1024,
                "peak_mlx_bytes": mx.get_peak_memory(), "active_mlx_bytes": mx.get_active_memory(),
                "cached_mlx_bytes": mx.get_cache_memory(), "output_budget_exhausted": exhausted,
                "termination": "output_budget" if exhausted else "EOS inferred from reviewed single-chunk loop; not exposed by SDK",
                "path": "mlx_audio_generate_complete_file", "native": native})
            print(f"qwen3-asr {fixture['id']} {iteration} {latency_ms:.1f} ms; tokens={output.generation_tokens}/{maximum_tokens}", flush=True)

    import mlx_audio

    package = Path(mlx_audio.__file__).parent
    sources = [package / name for name in ("stt/models/qwen3_asr/qwen3_asr.py", "stt/models/qwen3_asr/config.py",
                                          "stt/utils.py", "lm/generate.py", "utils.py")]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"manifest_sha256": sha256(manifest),
        "script_sha256": sha256(Path(__file__)), "model_metadata": metadata,
        "model_assets": assets, "runtime_source_sha256": {str(path.relative_to(package)): sha256(path) for path in sources},
        "runtime_versions": {name: importlib.metadata.version(name) for name in
                             ("mlx", "mlx-metal", "mlx-audio", "numpy", "soundfile", "transformers", "huggingface-hub")},
        "host": {"system": platform.platform(), "architecture": platform.machine(), "metal": mx.device_info()},
        "loading_ms": loading_ms,
        "configuration": {"options": options, "quantization": config["quantization"],
            "prefill_step_size": "SDK default 2048", "chunk_duration_seconds": "SDK default 1200; all selected clips <=30 seconds",
            "hotwords": [], "system_prompt": None, "offline": True, "strict_load": True,
            "timing": "warm complete-file call including reading/PCM conversion/public SDK preprocessing and final GPU synchronization; first shape outside timer",
            "termination": "Audited generator exits only on EOS or token budget for a single chunk; EOS IDs are consumed before public output. Preserve exhausted results as failed candidates.",
            "memory": "MLX counters describe its array allocator; whole-process lifetime RSS includes other native/Python/Metal allocations, not model-only RAM; no energy measurement"},
        "rows": rows}, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
