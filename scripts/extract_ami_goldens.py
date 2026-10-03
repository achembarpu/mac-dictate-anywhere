#!/usr/bin/env python3
"""Extract fixed AMI meeting goldens from explicitly downloaded source files.

No download or ASR is performed. Human word annotations supply references.
Source URLs, checksums, segment IDs, crops and licence are retained for reuse.
"""

import argparse
import hashlib
import json
import re
import wave
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

SELECTIONS = [
    ("golden-en-ami-1", "B", 1, "ES2002a.sync.74", 55.415, 77.390,
     ["female", "numbers", "fillers", "repetition"]),
    ("golden-en-ami-2", "A", 0, "ES2002a.sync.6", 132.380, 142.056,
     ["male", "question", "negation", "fillers", "crosstalk"]),
    ("golden-en-ami-3", "B", 1, "ES2002a.sync.78", 89.280, 102.283,
     ["female", "proper-names", "self-correction", "fillers"]),
]
NITE = "{http://nite.sourceforge.net/}"
SOURCE = "https://groups.inf.ed.ac.uk/ami/"
SIGNALS = SOURCE + "AMICorpusMirror/amicorpus/ES2002a/audio/"
ANNOTATIONS = SOURCE + "AMICorpusAnnotations/ami_public_manual_1.6.2.zip"
SOURCE_HASHES = {
    "ami_public_manual_1.6.2.zip": "b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d",
    "ES2002a.Headset-0.wav": "3bf0627106d6b6f02e5cc8b69f283b70303275c6b354aef3bdc7a50762d3f25e",
    "ES2002a.Headset-1.wav": "285ed5b5eaa4f871cc146900d0cf87487ca757aa57a7062def2eb49feaabc23d",
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, required=True)
    args = parser.parse_args()
    for name, expected in SOURCE_HASHES.items():
        require(digest(args.source_dir / name) == expected, f"Source checksum differs: {name}")
    golden = Path(__file__).resolve().parents[1] / "Dictate AnywhereTests/Fixtures/Golden"
    archive = args.source_dir / "ami_public_manual_1.6.2.zip"
    provenance = {"source": SOURCE, "licence": "CC BY 4.0", "licence_source": SOURCE + "download/",
                  "annotations_url": ANNOTATIONS, "annotations_sha256": digest(archive), "clips": []}
    manifest_path = golden / "golden-speech-manifest.json"
    inventory = json.loads(manifest_path.read_bytes())
    existing_ids = {f["id"] for f in inventory}
    if existing_ids & {s[0] for s in SELECTIONS}:
        parser.error("Selected goldens already exist; inspect changes before replacing them")
    with zipfile.ZipFile(archive) as zipped:
        require("CC BY" in zipped.read("LICENCE.txt").decode(), "Expected CC BY source licence")
        meetings = ET.fromstring(zipped.read("corpusResources/meetings.xml"))
        meeting = next(m for m in meetings if m.attrib.get("observation") == "ES2002a")
        for identifier, speaker, channel, segment_id, start, end, tags in SELECTIONS:
            mapping = next(s for s in meeting if s.attrib.get("nxt_agent") == speaker)
            require(int(mapping.attrib["channel"]) == channel, "Speaker/channel mapping differs")
            words_path = f"words/ES2002a.{speaker}.words.xml"
            segments = ET.fromstring(zipped.read(f"segments/ES2002a.{speaker}.segments.xml"))
            segment = next(s for s in segments if s.attrib[NITE + "id"] == segment_id)
            href = segment.find(NITE + "child").attrib["href"]
            first, last = re.findall(r"id\(([^)]+)\)", href)
            words = list(ET.fromstring(zipped.read(words_path)))
            ids = [w.attrib[NITE + "id"] for w in words]
            selected = words[ids.index(first):ids.index(last) + 1]
            lexical = [w for w in selected if w.tag == "w"]
            require(all(start <= float(w.attrib["starttime"]) <= float(w.attrib["endtime"]) <= end for w in lexical),
                    f"Crop omits an annotated word: {identifier}")
            reference = " ".join(w.text for w in lexical)
            # Only attach annotation punctuation; preserve every lexical token.
            reference = re.sub(r"\s+([,.!?;:])", r"\1", reference) + "\n"
            audio_source = args.source_dir / f"ES2002a.Headset-{channel}.wav"
            with wave.open(str(audio_source)) as source:
                require((source.getframerate(), source.getnchannels(), source.getsampwidth()) == (16_000, 1, 2),
                        "Expected unchanged 16 kHz mono PCM16 source")
                first_sample, last_sample = round(start * 16_000), round(end * 16_000)
                source.setpos(first_sample)
                frames = source.readframes(last_sample - first_sample)
                require(len(frames) == (last_sample - first_sample) * 2, "Source ends inside selected crop")
                audio_output = golden / (identifier + ".wav")
                with wave.open(str(audio_output), "wb") as dest:
                    dest.setnchannels(1)
                    dest.setsampwidth(2)
                    dest.setframerate(16_000)
                    dest.writeframes(frames)
            reference_output = golden / (identifier + ".txt")
            reference_output.write_text(reference, encoding="utf-8")
            inventory.append({"id": identifier, "language": "en", "metric": "wer",
                              "audio": audio_output.name, "reference": reference_output.name,
                              "sampleCount": last_sample - first_sample, "source": SOURCE,
                              "sourceId": f"ES2002a/{speaker}/{segment_id}",
                              "tags": ["human", "spontaneous-speech", "scenario-meeting", "headset", "short"] + tags,
                              "audioSHA256": digest(audio_output), "referenceSHA256": digest(reference_output)})
            provenance["clips"].append({"id": identifier, "meeting": "ES2002a", "speaker": speaker,
                                         "channel": channel, "segment_id": segment_id, "word_range": [first, last],
                                         "start_sample": first_sample, "end_sample": last_sample,
                                         "signal_url": SIGNALS + audio_source.name,
                                         "signal_sha256": digest(audio_source),
                                         "words_xml_sha256": hashlib.sha256(zipped.read(words_path)).hexdigest(),
                                         "audio_sha256": digest(audio_output), "reference_sha256": digest(reference_output)})
    manifest_path.write_text(json.dumps(inventory, indent=2, ensure_ascii=False) + "\n")
    (golden / "ami-source-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print("Extracted three human-referenced AMI clips; source samples and words preserved")


if __name__ == "__main__":
    main()
