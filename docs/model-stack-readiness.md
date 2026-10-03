# Model stack readiness — 2026-10-03

The implemented model-aware stack and native S1 MLX backend pass their available
hardware gates. Research does not justify another production STT model, quiet
gain default or MLX dependency upgrade. Retain the faster measured settings and
all rejected evidence. No new code-review blocker was found. Publication needs
branch restacking and a separate user instruction; broader hardware performance
claims need additional Macs.

## Final requirement audit

| Requested work | Evidence and disposition |
| --- | --- |
| Larger S1 gains after context reuse | MLX child integrates official native Swift libraries and author 4-bit/group64 weights. 420 paired app outputs: short 31–43%, long 34% faster than reused GGUF/Q8, checked fact/meaning assertions pass. Preparation moves graph startup out of first use. |
| Apple Silicon and Intel | Architecture-based format/compute selection; Intel retains llama.cpp CPU/Q8 KV/physical-core cap. Existing GGUF remains usable. Universal signed build and ten selected Rosetta real-model tests retained; no actual Intel throughput claim. |
| Useful new speech models | Whistle136 candidate/native rows; native Phonon135+6 gain rows; Moonshine36; Qwen17+9 native comparisons. Reject app integration on observed quality/runtime tradeoffs. Preserve models in persistent app/SDK caches, collectors, failed outputs and hashes. |
| Better reference coverage | 23 licensed human speech/reference pairs with integrity/provenance; independent FLEURS voices, three spontaneous AMI headset clips, derived quiet/noise/boundary/switch controls. Original human words unchanged; correlated cases identified. Eleven parent cleanup references plus 14 child stress cases. |
| Best quants/versions/placement | Native S1 quant/arithmetic/KV/prefill/allocator screen; 192 newer MLX outputs reject slower upgrades. 220 optimized Core ML placement decodes retain ANE for v3/Ultra. SenseVoice/Nemotron int8 / ANE and documented architecture fallbacks. Qwen precision contrast repairs language switching but not quiet negation. |
| CPU/GPU/RAM efficiency | Timed/resource outputs retain CPU, lifetime RSS, MLX allocator and cache bytes where applicable. Single-thread Moonshine loses latency; expensive sparse GPU/weak quants pruned before wider matrices. Distinguish memory scopes; no energy/total RAM inference. |
| Runtime flags and dependencies | FluidAudio 0.17.5 / llama.swift 2.10549 audited. b10549 already enables Flash Attention AUTO and supported K/Q/V/operation offload; Metal is separate from MLX. MLX child keeps 0.31.4 / LM 3.31.3 after regressions. No package-validation bypass. |
| Prompt/token/latency improvements | Trained S1 greedy prompt/tokenizer chunks, EOS/completeness checks and fixed publicprefix only. Provider capability/sampling/context/output policies and preparation. Apple Speech framework preparation/final boundary; Apple Intelligence independent context-safe sessions/numeric preservation. Weaker cleanup prompts/models rejected. |
| Bounded, reusable benchmarks | Existing scripts/dev.sh Release groups plus cached local collectors/sharedSwiftWER/CER/fact scorer. Exact fixture/mode/acoustic selection. Prune unsupported/slower variants before expansion, keep all failed outputs; no new matrix after decisive gates. |
| Research and PR documentation | Workspace ledger/state and consolidated parent/child PR drafts. Committed reports include reproduction, exact versions, source/model/input hashes, raw outputs and limits. |

These are finite benchmark/regression decisions on available hardware, not a
claim that every setting is globally optimal or every model preserves meaning.
The quiet AMI negative clause remains a documented challenge across models.
Modest gain improves raw WER without recovering that meaning, so live/VAD and
natural-noise checks remain prerequisites for any future gain feature.

## Verification and review

| Fresh normal Team-signed Debug | Total | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: | ---: |
| Parent at af5183f | 639 | 564 | 75 | 0 |
| MLX child at ca30de5 | 656 | 574 | 82 | 0 |

Both normal builds pass from fresh detached checkouts, which were subsequently
removed. Signing stays ignored. Later changes only normalize research-script
imports/executable modes and documentation; generation AST after import removal
is unchanged. Full-repository Ruff and two pytest SDK-error/release cases pass
on both branches. Both script registries/signing/selection/forwarding checks pass.

Latest focused Release gate scores 17 Qwen and nine native outputs: two tests pass,
one unconfigured local-endpoint test skips. Expected Moonshine nonempty-speech
assertion failures remain explicit candidate rejection; ordinary suites pass.
Historical real-model, paired policy/provider, installation, universal/Rosetta
and S1cache/cancellation evidence remains tied to source hashes and reports.

Final review checks current code against that evidence: eight MLX production
files match the reviewed integration artifact, the MLX engine matches the final
dependency screen, selected fixture references and six native weights reverify.
Qwen strict/offline load authenticates all checkpoint assets; a tampered config
fails before inference/output. No failed/budget-exhausted row is omitted.

All task source/doc whitespace checks pass. The retained candidate `.patch`
passes `git apply --check`; its context-only blank line necessarily contains
one space and is excluded from the whole-stack whitespace check as patch data.
No production code exception is needed. [Final source/check/log hashes](benchmarks/model-stack-readiness-2026-10-03.json)
retain the signed test commits and subsequent formatting provenance.

## Publication and hardware limits

The child began at model-aware commit d398ea7 and shares follow-ups by cherry-pick.
Restack onto the latest intended parent before opening three-dot PRs; otherwise
GitHub will repeat shared benchmark changes. No push/PR/merge/history rewrite
was performed. The parent PR draft is in the workspace docs; the child draft
is docs/s1-runtime-pr.md on that branch.

Actual Intel/base-M/8 GiB/minimum-macOS runtime performance, live microphone/Stop,
whole-system RAM and energy remain hardware acceptance limits. Universal/Rosetta
checks establish build/selection and selected inference behavior, not native
Intel speed. Do not describe these fixture results as population WER or claim
that lightweight factual guards detect arbitrary semantic loss.
