#!/usr/bin/env python3
"""Collect pinned, local Whistle outputs for the existing Swift golden scorer.

Requires cactus-needle 3.1.0, numpy and soundfile in a research environment.
No model/runtime download or server is started. Whistle's published C API is
process-global and not thread-safe; inference is deliberately serial.
"""

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import resource
from time import perf_counter


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", type=Path, required=True)
    parser.add_argument("--library-path", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--fixture", action="append", help="Select exact IDs; repeat for a small screen")
    parser.add_argument("--languages", default="en,nl,de")
    parser.add_argument("--detect-language", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.iterations <= 10:
        parser.error("iterations must be between 1 and 10")
    for path in (args.model_path, args.library_path):
        if not path.is_file():
            parser.error(f"Select an existing local asset: {path}")
    if importlib.metadata.version("cactus-needle") != "3.1.0":
        parser.error("This collector requires the reviewed cactus-needle 3.1.0 API")
    # The explicit native path also prevents automatic runtime downloads.
    os.environ["NEEDLE_TELEMETRY"] = "0"
    os.environ["NEEDLE3_LIB_PATH"] = str(args.library_path.resolve())
    import needle
    import numpy as np
    import soundfile as sf

    root = Path(__file__).resolve().parents[1]
    golden = root / "Dictate AnywhereTests/Fixtures/Golden"
    manifest = golden / "golden-speech-manifest.json"
    fixtures = json.loads(manifest.read_bytes())
    languages = set(args.languages.split(","))
    if not languages <= {"en", "de", "fr", "es", "it", "nl", "pl"}:
        parser.error("Selected language is outside Whistle's model card")
    if args.fixture and set(args.fixture) - {f["id"] for f in fixtures}:
        parser.error("Unknown golden fixture ID")
    fixtures = [f for f in fixtures if f["language"] in languages
                and (not args.fixture or f["id"] in args.fixture)]
    if not fixtures:
        parser.error("No compatible golden fixtures selected")

    started = perf_counter()
    model = needle.Whistle(weights=args.model_path.resolve())
    loading_ms = (perf_counter() - started) * 1000
    rows, skipped = [], []
    for fixture in fixtures:
        audio_path = golden / fixture["audio"]
        if sha256(audio_path) != fixture["audioSHA256"] or sha256(golden / fixture["reference"]) != fixture["referenceSHA256"]:
            raise ValueError(f"Fixture checksum differs: {fixture['id']}")
        if fixture["sampleCount"] > 480_000:
            skipped.append({"fixture": fixture["id"], "reason": "native API accepts at most 30 seconds; no unverified segmentation"})
            continue
        audio, rate = sf.read(audio_path, dtype="float32")
        if rate != 16_000 or audio.ndim != 1 or len(audio) != fixture["sampleCount"]:
            raise ValueError(f"Unexpected audio format: {fixture['id']}")
        language = None if args.detect_language else fixture["language"]
        started = perf_counter()
        model.transcribe(audio, language=language)
        first_file_ms = (perf_counter() - started) * 1000
        for iteration in range(args.iterations):
            before = resource.getrusage(resource.RUSAGE_SELF)
            started = perf_counter()
            # Match the app's complete-file benchmark boundary, including
            # file reading and PCM decoding in each warm request.
            samples, _ = sf.read(audio_path, dtype="float32")
            result = model.transcribe(samples, language=language)
            latency_ms = (perf_counter() - started) * 1000
            after = resource.getrusage(resource.RUSAGE_SELF)
            row = {"model": "whistle-auto" if args.detect_language else "whistle-language",
                   "fixture": fixture["id"], "iteration": iteration, "output": result["text"],
                   "latency_ms": latency_ms, "first_file_ms": first_file_ms,
                   "cpu_ms": ((after.ru_utime + after.ru_stime) - (before.ru_utime + before.ru_stime)) * 1000,
                   "process_peak_rss_bytes": after.ru_maxrss if platform.system() == "Darwin" else after.ru_maxrss * 1024,
                   "audio_seconds": len(audio) / rate, "native": result,
                   "path": "needle_recording_file"}
            rows.append(row)
            print(f"whistle {fixture['id']} {iteration} {latency_ms:.1f} ms", flush=True)
    # Deterministic nonspeech controls are distinct from human WER fixtures.
    controls = {"silence": model.transcribe(np.zeros(16_000, dtype=np.float32)),
                "steady_noise": model.transcribe(np.random.default_rng(2468).normal(0, .01, 16_000).astype(np.float32))}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"manifest_sha256": sha256(manifest),
        "script_sha256": sha256(Path(__file__)), "model_sha256": sha256(args.model_path),
        "library_sha256": sha256(args.library_path), "loading_ms": loading_ms,
        "runtime_versions": {name: importlib.metadata.version(name) for name in ("cactus-needle", "numpy", "soundfile")},
        "host": {"system": platform.platform(), "architecture": platform.machine()},
        "configuration": {"language": "auto" if args.detect_language else "fixture", "keywords": [],
                          "word_timestamps": False, "decoder_depth": "full", "beam_count": "native default (author reports 5)",
                          "threads": "native default", "timing": "warm complete-file call; reading/PCM conversion included; first_file_ms is untimed native shape warmup"},
        "rows": rows, "skipped": skipped, "controls": controls}, ensure_ascii=False, indent=2) + "\n")
    if not rows:
        raise ValueError("No fixture fits the native API limit")


if __name__ == "__main__":
    main()
