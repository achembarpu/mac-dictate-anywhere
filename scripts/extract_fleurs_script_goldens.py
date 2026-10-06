#!/usr/bin/env python3
"""Extract fixed human FLEURS script checks from local, pinned test archives.

Download the named archives and TSVs explicitly from the source revision below.
No ASR, reference correction, resampling or archive extraction is performed.
"""

import argparse
import hashlib
import json
import tarfile
import struct
from pathlib import Path

REVISION = "70bb2e84b976b7e960aa89f1c648e09c59f894dd"
SOURCE = f"https://huggingface.co/datasets/google/fleurs/tree/{REVISION}"
SELECTIONS = {
    "ru": ("ru_ru", ["13632175593719991398.wav", "9567027620605262154.wav"]),
    "el": ("el_gr", ["11461912508659872190.wav", "11442026067900733565.wav"]),
}


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, required=True,
                        help="Contains ru-test.tar.gz/el-test.tar.gz and fleurs-test-ru.tsv/fleurs-test-el.tsv")
    args = parser.parse_args()
    golden = Path(__file__).resolve().parents[1] / "Dictate AnywhereTests/Fixtures/Golden"
    manifest_path = golden / "golden-speech-manifest.json"
    inventory = json.loads(manifest_path.read_bytes())
    selected_ids = {f"golden-{lang}-fleurs-{i}" for lang in SELECTIONS for i in (1, 2)}
    if selected_ids & {row["id"] for row in inventory}:
        parser.error("Selected IDs already exist; inspect changes before replacing them")
    provenance = {"source": SOURCE, "revision": REVISION, "license": "CC BY 4.0", "sources": []}
    for lang, (config, names) in SELECTIONS.items():
        tsv = args.source_dir / f"fleurs-test-{lang}.tsv"
        rows = {row[1]: row for line in tsv.read_text().splitlines() if (row := line.split("\t"))}
        archive = args.source_dir / f"{lang}-test.tar.gz"
        clips = {}
        with tarfile.open(archive, "r:gz") as source:
            for member in source:
                name = Path(member.name).name
                if name in names and member.isfile():
                    clips[name] = source.extractfile(member).read()
        if set(clips) != set(names):
            raise ValueError(f"Archive lacks selected clips: {lang}")
        for i, name in enumerate(names, 1):
            row = rows[name]
            audio = clips[name]
            if audio[:4] != b"RIFF" or audio[8:12] != b"WAVE":
                raise ValueError(f"Expected WAV source: {name}")
            offset, fmt, sample_bytes = 12, None, None
            while offset + 8 <= len(audio):
                kind, size = struct.unpack_from("<4sI", audio, offset)
                payload = audio[offset + 8:offset + 8 + size]
                if kind == b"fmt ":
                    fmt = struct.unpack_from("<HHIIHH", payload)
                if kind == b"data":
                    sample_bytes = len(payload)
                offset += 8 + size + size % 2
            # FLEURS ships unchanged mono Float32 WAV, not quantized PCM16.
            if fmt is None or fmt[:3] != (3, 1, 16000) or fmt[4:] != (4, 32) or sample_bytes != int(row[5]) * 4:
                raise ValueError(f"Unexpected source Float32 metadata: {name}")
            reference = (row[2] + "\n").encode("utf-8")
            identifier = f"golden-{lang}-fleurs-{i}"
            (golden / f"{identifier}.wav").write_bytes(audio)
            (golden / f"{identifier}.txt").write_bytes(reference)
            inventory.append({"id": identifier, "language": lang, "metric": "wer",
                              "audio": f"{identifier}.wav", "reference": f"{identifier}.txt",
                              "sampleCount": int(row[5]), "source": SOURCE, "sourceId": f"{config}/test/{row[0]}/{name}",
                              "tags": ["human", "read-speech", "script-filter", "native-script" if i == 1 else "latin-name"],
                              "audioSHA256": digest(audio), "referenceSHA256": digest(reference)})
        provenance["sources"].append({"config": config, "archiveSHA256": digest(archive.read_bytes()),
                                       "tsvSHA256": digest(tsv.read_bytes()), "selected_files": names})
    manifest_path.write_text(json.dumps(inventory, indent=2, ensure_ascii=False) + "\n")
    (golden / "fleurs-script-source-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print("Extracted four unchanged human-recorded FLEURS clips and references")


if __name__ == "__main__":
    main()
