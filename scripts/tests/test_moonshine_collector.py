"""The SDK swallows final decode errors; failed runs must never become scores."""

import sys
from types import SimpleNamespace

import pytest

from scripts.evaluate_moonshine import transcribe


class NativeError:
    def __init__(self, error):
        self.error = error


class FailedStream:
    def __init__(self, emit_error):
        self.emit_error = emit_error
        self.closed = False

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.closed = True

    def add_listener(self, listener):
        self.listener = listener

    def start(self):
        pass

    def stop(self):
        if self.emit_error:
            self.listener(NativeError(RuntimeError("native final decode failed")))
            return SimpleNamespace(lines=[])
        return None


@pytest.mark.parametrize("emit_error", [False, True])
def test_failed_final_decode_is_rejected_and_stream_is_released(monkeypatch, emit_error):
    monkeypatch.setitem(sys.modules, "moonshine_voice", SimpleNamespace(Error=NativeError))
    stream = FailedStream(emit_error)
    model = SimpleNamespace(create_stream=lambda: stream)

    with pytest.raises(RuntimeError, match="Moonshine stream failed"):
        transcribe(model, [], "streaming")

    assert stream.closed
