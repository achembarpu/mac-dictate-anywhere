#!/usr/bin/env python3
"""Collect local Moonshine Voice outputs for the shared Swift golden scorer.

Requires moonshine-voice 0.1.5, numpy, soundfile and google-crc32c. No model
download, server or microphone is started. Supply the native dependency catalog
saved at download time; all model and fixture bytes are verified before loading.
"""

import argparse
import base64
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


def transcribe(model, samples, mode: str) -> dict:
    from moonshine_voice import Error

    first_visible_audio_seconds = None
    fed_samples = 0
    errors = []
    if mode == "streaming":
        def listener(event):
            nonlocal first_visible_audio_seconds
            if isinstance(event, Error):
                errors.append(str(event.error))
            elif event.line and event.line.text.strip() and first_visible_audio_seconds is None:
                first_visible_audio_seconds = fed_samples / 16_000

        # Fresh streams prevent both transcript and adaptive cadence leakage.
        with model.create_stream() as stream:
            stream.add_listener(listener)
            stream.start()
            for offset in range(0, len(samples), 1600):
                chunk = samples[offset:offset + 1600].tolist()
                fed_samples += len(chunk)
                stream.add_audio(chunk, sample_rate=16_000)
            stopping = perf_counter()
            transcript = stream.stop()
            stop_ms = (perf_counter() - stopping) * 1000
            # The Python SDK catches final-update errors. Never mistake None
            # or an emitted error for a successful final transcript.
            if transcript is None or errors:
                raise RuntimeError(f"Moonshine stream failed: {errors}")
    else:
        transcript = model.transcribe_without_streaming(samples.tolist(), sample_rate=16_000)
        stop_ms = None

    lines = [{"text": line.text, "start_seconds": line.start_time,
              "duration_seconds": line.duration, "is_complete": line.is_complete}
             for line in transcript.lines]
    return {"output": " ".join(line["text"].strip() for line in lines if line["text"].strip()),
            "lines": lines, "stop_ms": stop_ms,
            "first_visible_audio_seconds": first_visible_audio_seconds,
            # Line completion describes segmentation, not decoder EOS or an
            # absence of max_tokens_per_second truncation.
            "decoder_termination": "not exposed by SDK"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-path", type=Path, required=True)
    parser.add_argument("--model-catalog", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", action="append", required=True, help="Exact IDs; repeat for a bounded screen")
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--mode", choices=("streaming", "whole-utterance"), default="streaming")
    parser.add_argument("--disable-vad", action="store_true", help="Author's presegmented-utterance accuracy configuration")
    args = parser.parse_args()
    if not 1 <= args.iterations <= 10:
        parser.error("iterations must be between 1 and 10")
    if importlib.metadata.version("moonshine-voice") != "0.1.5":
        parser.error("This collector requires the reviewed moonshine-voice 0.1.5 API")
    if not args.model_path.is_dir() or not args.model_catalog.is_file():
        parser.error("Select existing local model assets and catalog")

    import google_crc32c
    import moonshine_voice
    import soundfile as sf
    from moonshine_voice import ModelArch, Transcriber

    catalog = json.loads(args.model_catalog.read_bytes())
    info = catalog["model_info"]
    if info["language"] != "en" or info["model_arch"] not in (4, 5):
        parser.error("This bounded screen supports English Small/Medium Streaming only")
    groups = catalog["download_manifest"]["groups"]
    if len(groups) != 1 or not groups[0]["files"]:
        parser.error("Expected one explicit primary STT dependency group")
    assets = []
    for entry in groups[0]["files"]:
        name = entry["name"]
        if Path(name).name != name or entry["checksum_type"] != "crc32c":
            parser.error("Unexpected model dependency name or checksum type")
        path = args.model_path / name
        data = path.read_bytes()
        checksum = base64.b64encode(google_crc32c.Checksum(data).digest()).decode("ascii")
        if len(data) != entry["size"] or checksum != entry["checksum"]:
            raise ValueError(f"Model checksum differs: {name}")
        assets.append({"name": name, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    del data  # Do not retain the last model file through the inference screen.

    root = Path(__file__).resolve().parents[1]
    golden = root / "Dictate AnywhereTests/Fixtures/Golden"
    manifest = golden / "golden-speech-manifest.json"
    fixtures = json.loads(manifest.read_bytes())
    if set(args.fixture) - {fixture["id"] for fixture in fixtures}:
        parser.error("Unknown golden fixture ID")
    fixtures = [fixture for fixture in fixtures if fixture["id"] in args.fixture]
    if any(fixture["language"] != "en" for fixture in fixtures):
        parser.error("Select English fixtures for this English checkpoint")
    for fixture in fixtures:
        for key, hash_key in (("audio", "audioSHA256"), ("reference", "referenceSHA256")):
            if sha256(golden / fixture[key]) != fixture[hash_key]:
                raise ValueError(f"Fixture checksum differs: {fixture['id']}")

    options = {"ort_providers": "CPU", "return_audio_data": "false"}
    if args.disable_vad:
        options.update(vad_threshold="0", vad_max_segment_duration="1000000")
    arch = ModelArch(info["model_arch"])
    model_name = f"moonshine-{arch.name.lower().replace('_', '-')}-{args.mode}"
    if args.disable_vad:
        model_name += "-vad-off"
    started = perf_counter()
    rows = []
    with Transcriber(args.model_path.resolve(), model_arch=arch, options=options) as model:
        loading_ms = (perf_counter() - started) * 1000
        for fixture in fixtures:
            path = golden / fixture["audio"]
            audio, rate = sf.read(path, dtype="float32")
            if rate != 16_000 or audio.ndim != 1 or len(audio) != fixture["sampleCount"]:
                raise ValueError(f"Unexpected audio format: {fixture['id']}")
            first = perf_counter()
            transcribe(model, audio, args.mode)
            first_file_ms = (perf_counter() - first) * 1000
            for iteration in range(args.iterations):
                before = resource.getrusage(resource.RUSAGE_SELF)
                started = perf_counter()
                samples, _ = sf.read(path, dtype="float32")
                result = transcribe(model, samples, args.mode)
                latency_ms = (perf_counter() - started) * 1000
                after = resource.getrusage(resource.RUSAGE_SELF)
                rows.append({"model": model_name, "fixture": fixture["id"],
                    "iteration": iteration, "latency_ms": latency_ms,
                    "first_file_ms": first_file_ms, "audio_seconds": len(audio) / rate,
                    "cpu_ms": ((after.ru_utime + after.ru_stime) - (before.ru_utime + before.ru_stime)) * 1000,
                    "process_peak_rss_bytes": after.ru_maxrss if platform.system() == "Darwin" else after.ru_maxrss * 1024,
                    **result})
                print(f"{model_name} {fixture['id']} {iteration} {latency_ms:.1f} ms", flush=True)

    package = Path(moonshine_voice.__file__).parent
    runtime_assets = [{"name": path.name, "sha256": sha256(path), "bytes": path.stat().st_size}
                      for path in sorted(package.glob("*.dylib"))]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"manifest_sha256": sha256(manifest),
        "script_sha256": sha256(Path(__file__)), "catalog": catalog,
        "model_assets": assets, "runtime_assets": runtime_assets,
        "runtime_versions": {name: importlib.metadata.version(name)
                             for name in ("moonshine-voice", "numpy", "soundfile", "google-crc32c")},
        "host": {"system": platform.platform(), "architecture": platform.machine()},
        "loading_ms": loading_ms,
        "configuration": {"mode": args.mode, "options": options,
            "update_interval_seconds": 0.5, "chunk_samples": 1600,
            "threads": "shipped ORT default", "MOONSHINE_ORT_SINGLE_THREAD": os.getenv("MOONSHINE_ORT_SINGLE_THREAD"),
            "speculative_decoding": "shipped true default", "max_tokens_per_second": "shipped 6.5 English default",
            "context": None, "keyterms": [],
            "timing": "warm complete-file compute including reading, Python PCM conversion, stream creation and final flush; chunks fed without sleeps",
            "first_visible": "audio position at first text event, not wall-clock latency; no live microphone scheduling",
            "memory": "whole-process lifetime high-water RSS, not model-only resident RAM"},
        "rows": rows}, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
