"""Transcribes a Meeting Recorder WAV on this PC with WhisperX. Nothing is uploaded.

Usage: python Transcribe.py <recording.wav> <status.ini> <segments.tsv> [hint] [model]

hint is the meeting title and attendee names. It is the speech model's initial prompt, so
those names and words come out spelled right.

The left channel is what the user heard (Others), the right channel their microphone (Me),
so no speaker detection is needed. Progress goes to status.ini ([Transcribe] State, Percent,
Detail; UTF-16, replaced atomically), details to status.ini.log. The result is one
start<TAB>end<TAB>speaker<TAB>text line per segment (UTF-8); MeetingRecorder.ahk turns it into
the .txt and .srt next to the recording.

The audio is read here rather than by WhisperX, so no ffmpeg.exe is needed.
"""
import os
import sys

# huggingface_hub symlinks its cache by default, which needs admin rights or Developer Mode.
os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS", "1")
os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS_WARNING", "1")

SAMPLE_RATE = 16000


def set_state(path, state, percent, detail):
    text = "[Transcribe]\r\nState=%s\r\nPercent=%d\r\nDetail=%s\r\n" % (state, percent, " ".join(str(detail).split()))
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-16", newline="") as f:
        f.write(text)
    os.replace(tmp, path)


def read_channels(path):
    """Returns (left, right) as float32 mono at 16 kHz. Reads in blocks to keep memory low."""
    import wave
    import numpy as np
    import torch
    import torchaudio.functional as F

    left, right = [], []
    with wave.open(path, "rb") as w:
        channels, width, rate = w.getnchannels(), w.getsampwidth(), w.getframerate()
        if width != 2 or channels not in (1, 2):
            raise ValueError("This is not a Meeting Recorder WAV file (16-bit, stereo).")
        block = rate * 60
        while True:
            raw = w.readframes(block)
            if not raw:
                break
            data = np.frombuffer(raw, dtype="<i2").reshape(-1, channels).astype(np.float32) / 32768.0
            pair = torch.from_numpy(np.ascontiguousarray(data.T))
            if rate != SAMPLE_RATE:
                pair = F.resample(pair, rate, SAMPLE_RATE)
            left.append(pair[0].numpy())
            right.append(pair[-1].numpy())
    if not left:
        return np.zeros(0, np.float32), np.zeros(0, np.float32)
    return np.concatenate(left), np.concatenate(right)


def language_sample(left, right):
    """The 30 seconds with the most sound, so silence at the start does not decide the language."""
    import numpy as np

    mix = (left + right) / 2
    seconds = len(mix) // SAMPLE_RATE
    if seconds <= 30:
        return mix
    energy = np.square(mix[: seconds * SAMPLE_RATE].reshape(seconds, SAMPLE_RATE)).mean(axis=1)
    start = int(np.convolve(energy, np.ones(30), "valid").argmax()) * SAMPLE_RATE
    return mix[start : start + 30 * SAMPLE_RATE]


def main(wav, status, out, hint="", model_name="large-v3"):
    log = open(status + ".log", "w", encoding="utf-8", buffering=1)
    sys.stdout = sys.stderr = log
    try:
        # Below normal priority: a new recording may start while this runs.
        import ctypes
        ctypes.windll.kernel32.SetPriorityClass(ctypes.windll.kernel32.GetCurrentProcess(), 0x4000)
    except Exception:
        pass
    set_state(status, "Working", 0, "Loading the speech model")
    import torch
    import whisperx

    # Half the logical cores is as fast as all but one (measured on a 12-thread i7-1255U)
    # and leaves the PC free for the call.
    threads = max(1, (os.cpu_count() or 2) // 2)
    torch.set_num_threads(threads)
    print("Threads: %d" % threads)
    left, right = read_channels(wav)
    print("Hint:", hint)
    model = whisperx.load_model(
        model_name, "cpu", compute_type="int8", threads=threads, asr_options={"initial_prompt": hint.strip() or None}
    )
    language = model.detect_language(language_sample(left, right))
    print("Language:", language)
    set_state(status, "Working", 10, "Loading the speech model")
    try:
        align_model, align_meta = whisperx.load_align_model(language_code=language, device="cpu")
    except Exception as e:  # no alignment model for this language, or offline: keep WhisperX's own times
        print("Alignment skipped:", e)
        align_model = align_meta = None

    rows = []
    for index, (speaker, audio, label) in enumerate(
        [("Others", left, "Writing down what others said"), ("Me", right, "Writing down what you said")]
    ):
        base = 10 + index * 45

        def progress(pct, base=base, label=label, share=36):
            set_state(status, "Working", base + pct * share / 100, label)

        progress(0)
        result = model.transcribe(audio, batch_size=8, language=language, progress_callback=progress)
        segments = result["segments"]
        if segments and align_model is not None:
            try:
                segments = whisperx.align(
                    segments, align_model, align_meta, audio, "cpu",
                    progress_callback=lambda pct, base=base, label=label: set_state(status, "Working", base + 36 + pct * 9 / 100, label),
                )["segments"]
            except Exception as e:
                print("Alignment failed for", speaker, ":", e)
        for s in segments:
            text = " ".join(str(s.get("text", "")).split())
            if text and s.get("start") is not None and s.get("end") is not None:
                rows.append("%.3f\t%.3f\t%s\t%s" % (s["start"], s["end"], speaker, text))

    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(rows) + ("\n" if rows else ""))
    os.replace(tmp, out)
    set_state(status, "Done", 100, "Transcript ready")


if __name__ == "__main__":
    status_path = sys.argv[2] if len(sys.argv) > 2 else ""
    try:
        if len(sys.argv) < 4:
            raise SystemExit(__doc__)
        main(*sys.argv[1:6])
    except BaseException as e:
        import traceback
        traceback.print_exc()
        if status_path:
            set_state(status_path, "Error", 0, str(e) or e.__class__.__name__)
        sys.exit(1)
