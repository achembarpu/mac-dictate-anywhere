# Performance tracing

`PerfTrace` emits privacy-safe `OSSignposter` intervals and durable unified-log
notice records. Trace names, elapsed time, and fixed event markers are the only
recorded fields: no audio, transcript, prompt, path, model name, or app metadata
is logged. Tracing is on in Debug and Release builds. Set
`DICTATE_ANYWHERE_PERF_TRACE=0` before launch to disable it.

## Capture a dictation

Use Instruments with the `os_signpost` instrument and filter to the app's
`Performance` category. For a historical text view, run:

```sh
log show --style compact --predicate 'category == "Performance" AND composedMessage CONTAINS "trace "' --last 15m
```

An interval produces `trace <name> duration_ms=<milliseconds> outcome=<ended|completed|failed|cancelled|aborted>`.
Durations use a monotonic clock. Manually scoped spans default to `ended`,
which does not imply success; measured throwing operations report `completed`,
`failed`, or `cancelled`. A point marker
produces `trace <name> event=observed` and is therefore visible both in
Instruments and in historical logs.

## Pipeline map

| User-visible boundary | Trace names |
| --- | --- |
| Accepted hotkey request to confirmed microphone capture | `dictation.requestToRecording`, `dictation.capture`, `dictation.contextCapture`, `dictation.start`, `audio.controllerWait`, `audio.controllerCreate`, `audio.microphoneBoost`, `audio.systemMute` |
| Live recognition availability | `stt.firstPartial`; Apple Speech reports `stt.appleSpeechSessionStart`, and AssemblyAI also reports `stt.livePreviewStart` and `stt.assemblyAIWarmConnection` |
| Automatic end-of-utterance | `eou.detected`, `eou.stop`, followed by the regular stop path |
| Stop recording to final transcript | `dictation.stopToInsertion`, `stt.stopToFinal`, `audio.teardown`, `stt.finalize`, `stt.transcribe` |
| AssemblyAI final request | `stt.assemblyAIRequestBuild`, `stt.assemblyAIRequest`, `stt.assemblyAIResponseDecode`, `stt.warmConnectionWait` |
| Local cleanup | `cleanup.validate`, `cleanup.request`, `cleanup.modelLoad`, `cleanup.tokenize`, `cleanup.promptEval`, `cleanup.decode`, `cleanup.generate` |
| Apple Intelligence cleanup | `cleanup.appleIntelligenceSchema`, `cleanup.appleIntelligenceTools` |
| Remote cleanup | `cleanup.ollamaReasoningLookup`, `cleanup.ollamaRequest`, `cleanup.openRouterRequest`, `cleanup.openAICompatibleRequest`; Ollama also persists its server-reported load/prompt/eval timings |
| Delivery and restoration | `transcript.normalize`, `transcript.history`, `insertion.targetActivation`, `insertion.deliver`, `insertion.prepare`, `insertion.listEdit`, `insertion.clipboard`, `insertion.pasteScript`, `insertion.pasteEvent`, `insertion.listEditVerify`, `dictation.teardown`, `audio.microphoneRestore`, `audio.systemRestore` |
| Cancel and recovery paths | `dictation.cancel`, `recovery.captureStart`, `recovery.preserve`, `recovery.discard`, `recovery.reload`, `recovery.transcribe`, `recovery.continue` |

Compare one trace at a time: start with `dictation.stopToInsertion`, then use its
nested ASR, cleanup, activation, and insertion spans to identify the largest
child cost. For recording-start regressions, start from
`dictation.requestToRecording` and distinguish context capture, audio routing,
audio-controller creation, and engine session startup before changing behavior.
`audio.controllerWait` includes queueing and the caller's timeout; `audio.controllerCreate`
tracks actual construction and may finish later if CoreAudio is blocked. The
request-to-recording span ends before an immediate hold-to-record stop begins.
