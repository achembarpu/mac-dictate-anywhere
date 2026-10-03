# Native S1-mini MLX probe

This standalone Swift executable tunes the native Apple Silicon cleanup backend.
The app uses the same pinned libraries; this collector records raw model outputs.
Use `scripts/dev.sh benchmark --release --only s1-runtime,s1-prepare` to measure
the complete production service and its safety gates.
The [native runtime guide](../../docs/s1-native-runtime.md) describes installation
and request isolation. Save raw outputs outside the checkout, under workspace
`docs/<topic>/` when using the development workspace.

## Reproduce

Use Apple Silicon, Xcode's command line tools and the Metal compiler component.
Production uses MLX Swift 0.31.4, Swift LM 3.31.3 and Swift Transformers 1.3.0.
Normal Xcode package-plugin validation remains enabled. Install the optional compiler with
`xcodebuild -downloadComponent MetalToolchain` if `xcrun metal --version` cannot
find it. The committed `Package.resolved` pins the complete dependency graph;
the package declares macOS 14.

Download the author's `superwhisper/s1-mini` snapshot at revision
`88f6b15896c73bbb13a3b596e0afe8ea0d5150b4` into the usual Hugging Face cache.
For conversion, use an isolated Python environment with `mlx-lm` and
`huggingface-hub`, then verify the resulting assets before use:

```python
from huggingface_hub import snapshot_download
from mlx_lm.convert import convert

source = snapshot_download(
    "superwhisper/s1-mini",
    revision="88f6b15896c73bbb13a3b596e0afe8ea0d5150b4",
)
convert(source, "PATH/4bit", quantize=True, q_bits=4, q_group_size=64,
        trust_remote_code=False)
convert(source, "PATH/8bit", quantize=True, q_bits=8, q_group_size=64,
        trust_remote_code=False)
```

Keep the author's LICENSE and NOTICE with converted weights. The downloaded
snapshot itself supplies the BF16 comparison. No weights are committed.
Run from the app repository root, using absolute model/output paths:

```sh
swift build --package-path tools/s1-mlx-probe --configuration release
swift run --package-path tools/s1-mlx-probe --configuration release --skip-build \
  S1MLXProbe /ABSOLUTE/PATH/4bit "$PWD" 3 /ABSOLUTE/PATH/results.json 16 256 prefix 64
```

The positional arguments are model directory, app repository, repeats, output
JSON and cache precision (`16` uses the normal unquantized cache; `8` enables
8-bit KV quantization). Run model inference serially. Score the saved outputs
using the existing signed app benchmark, after local signing is configured:

```sh
PIPELINE_BENCHMARK_CLEANUP_RESULTS_PATH=/ABSOLUTE/PATH/results.json \
  scripts/dev.sh benchmark --release --only cleanup-prompts
```

## Collector contract

The probe reads the production system prompt and shared golden manifest. It
uses the trained styling/context prefix, empty thinking block, greedy sampling,
configurable prefill and input-derived output limit, including one EOS probe.
Only English goldens without vocabulary are eligible. Inputs above 1,000 tokens
fail explicitly; this executable is a single-pass experiment. Each request
starts with a new cache and records actual EOS completion. One synthetic request
then a second warm request precede the measured cases. Saved prompt-token hashes
allow comparison with the author's Hugging Face tokenizer/template.

The timer includes tokenizer, generation and output decoding. It excludes model
loading and the app's postprocessing/fallback gates. Per-fixture first shape
use remains visible in the three trials. This is neither live dictation nor a
complete production lifecycle implementation.

The app integration includes the shared chunk/fallback rules, bounded cancellation
and unload, verified installation, selected-model preparation and Intel's llama.cpp
path. The collector deliberately measures raw single-pass output; use the registered
app benchmark for production behavior. Collector timings exclude live capture, UI and app fallback work.

## Runtime matrix

Optional positional arguments after KV_BITS are prefill size, `prefix`/`none`,
allocator cache limit in MiB, and `qwen-card` for the pinned Qwen3.5-0.8B candidate.
The last argument can instead be `fp16` to cast floating model tensors to FP16
while keeping packed integer weights unchanged. This is a benchmark option;
production keeps the original BF16 tensors.
S1 always uses its trained prompt, greedy sampling and author token budget.
Prefix mode copies only the public system-prompt cache and checks its offsets.

```sh
tools/s1-mlx-probe/.build/release/S1MLXProbe /path/to/4bit /path/to/app/repo 3 /absolute/workspace/docs/s1-probe/results.json 16 256 prefix 64
```

Qwen uses its own chat template, thinking disabled, temperature 1, top-p 1,
top-k 20 and presence penalty 2 over the full bounded sequence, following the
author's text-task recipe. Three reproducible seeds (100–102) exercise variability.
Its prompt explicitly asks for faithful cleanup, preserved facts/questions and
literal instructions; it is a candidate evaluation, not the production S1 prompt.
All unfinished responses are marked `completed=false`. Do not compare the latency
of a shortened/incomplete response with a complete S1 response as a speed win.

The collector includes the shared references plus `s1-cleanup-stress-manifest.json`.
For group32/128 comparisons, convert the same pinned author snapshot with
`q_bits=4`, `q_group_size=32` or `128`, affine mode and remote code disabled.
Keep inference serial and avoid concurrent builds during latency measurements.
New collector outputs also record both fixture hashes, system-prompt/dependency
hashes, allocator limit, floating tensor policy and candidate seeds for reuse.
