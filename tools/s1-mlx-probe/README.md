# Native S1-mini MLX probe

This standalone Swift executable evaluates a possible Apple Silicon cleanup
backend. It does not change the app's dependencies, model picker or decoder.
Use the [benchmark guide](../../docs/performance-benchmarking.md) to score
saved outputs against the app's independent references.

## Reproduce

Use Apple Silicon, Xcode's command line tools and the Metal compiler component.
Transitive MLX Swift 0.31.6 requires
Swift 6.3 or later for C generation. Install the optional compiler with
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
  S1MLXProbe /ABSOLUTE/PATH/4bit "$PWD" 3 /ABSOLUTE/PATH/results.json 16
```

The positional arguments are model directory, app repository, repeats, output
JSON and cache precision (`16` uses the normal unquantized cache; `8` enables
8-bit KV quantization). Run model inference serially. Score the saved outputs
using the existing signed app benchmark, after local signing is configured:

```sh
PIPELINE_BENCHMARK_CLEANUP_RESULTS_PATH=/ABSOLUTE/PATH/results.json \
  scripts/dev.sh benchmark --release --only cleanup-prompts
```

## Contract and integration work

The probe reads the production system prompt and shared golden manifest. It
uses the trained styling/context prefix, empty thinking block, greedy sampling,
512-token prefill and input-derived output limit, including one EOS probe.
Only English goldens without vocabulary are eligible. Inputs above 1,000 tokens
fail explicitly; this executable is a single-pass experiment. Each request
starts with a new cache and records actual EOS completion. One synthetic request
then a second warm request precede the measured cases. Saved prompt-token hashes
allow comparison with the author's Hugging Face tokenizer/template.

The timer includes tokenizer, generation and output decoding. It excludes model
loading and the app's postprocessing/fallback gates. Per-fixture first shape
use remains visible in the three trials. This is neither live dictation nor a
complete production lifecycle implementation.

This probe does not implement app chunking/fallback, lifecycle cancellation or
installation. Use the production service for those contracts. Save raw outputs
and evaluations outside the checkout, under workspace `docs/<topic>/` when using
the development workspace. Model weights stay in the normal model cache.
