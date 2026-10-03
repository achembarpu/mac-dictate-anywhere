#!/usr/bin/env python3
"""Collect Phonon-2 whole-file results for the shared speech golden scorer.

Requires the pinned fermion-research research environment and an existing local
model directory. No download/server/app-preference changes are performed.
"""

import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
from time import perf_counter


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=3)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 10:
        parser.error("iterations must be between 1 and 10")
    if not (args.model_path / "model.fermion").is_file():
        parser.error("Select an existing Phonon-2 model directory")
    import mlx.core as mx
    from fermion._speech.engine_phonon2 import load

    root = Path(__file__).resolve().parents[1]
    golden = root / "Dictate AnywhereTests/Fixtures/Golden"
    manifest = golden / "golden-speech-manifest.json"
    source = manifest.read_bytes()
    started = perf_counter()
    model = load(args.model_path, profile="five-value", backend="phonon2-five-value", quiet=True)
    loading_ms = (perf_counter() - started) * 1000
    rows = []
    for fixture in json.loads(source):
        if fixture["language"] != "en":
            continue
        audio = golden / fixture["audio"]
        if hashlib.sha256(audio.read_bytes()).hexdigest() != fixture["audioSHA256"]:
            raise ValueError("Audio checksum differs from golden manifest")
        started = perf_counter()
        model.transcribe(audio)
        first_file_ms = (perf_counter() - started) * 1000
        for iteration in range(args.iterations):
            started = perf_counter()
            output, compute_seconds, audio_seconds = model.transcribe(audio)
            mx.synchronize()
            latency_ms = (perf_counter() - started) * 1000
            rows.append({"model": "phonon-2", "fixture": fixture["id"], "iteration": iteration,
                         "latency_ms": latency_ms, "decode_ms": compute_seconds * 1000,
                         "audio_seconds": audio_seconds, "first_file_ms": first_file_ms,
                         "output": output, "path": "fermion_recording_file"})
            print(f"phonon-2 {fixture['id']} {iteration} {latency_ms:.1f} ms", flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"manifest_sha256": hashlib.sha256(source).hexdigest(),
        "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "runtime_versions": {name: importlib.metadata.version(name) for name in ("fermion-research", "mlx", "mlx-audio")},
        "loading_ms": loading_ms, "configuration": model.describe(),
        "peak_mlx_bytes": mx.get_peak_memory(), "rows": rows}, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
