"""Transcribes a Meeting Recorder WAV on this PC with WhisperX. Nothing is uploaded.

Usage: python Transcribe.py <recording.wav> <status.ini> <segments.tsv> [hint] [model]

hint is the meeting title and attendee names. It is the speech model's initial prompt, so
those names and words come out spelled right.

The left channel is what the user heard (Others), the right channel their microphone (Me),
so no speaker detection is needed. Progress goes to status.ini ([Transcribe] State, Percent,
Detail; UTF-16, replaced atomically), details to status.ini.log (every line timed, earlier
tries kept, #16). The result is one
start<TAB>end<TAB>speaker<TAB>text line per segment (UTF-8); MeetingRecorder.ahk turns it into
the .txt and .srt next to the recording.

The audio is read here rather than by WhisperX, so no ffmpeg.exe is needed.
"""
import os
import sys
import threading
import time

# huggingface_hub symlinks its cache by default, which needs admin rights or Developer Mode.
os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS", "1")
os.environ.setdefault("HF_HUB_DISABLE_SYMLINKS_WARNING", "1")

SAMPLE_RATE = 16000

state_lock = threading.RLock()
last_state = None   # the arguments of the last set_state, which the background ticker repeats
background = None   # a Download running beside the transcription (#16)


def set_state(path, state, percent, detail, step=0, resumed=False, download=None):
    """Step (#12): 1 load the speech model, 2 find where people speak, 3 write down what others
    said, 4 write down what you said. Resumed=1 when what others said was saved by an earlier try.
    Download (#16) is a model download to show, or by default the one in the background."""
    global last_state
    with state_lock:
        last_state = (path, state, percent, detail, step, resumed)
        if download is None:
            download = background.text() if background is not None else ""
        text = "[Transcribe]\r\nState=%s\r\nPercent=%d\r\nDetail=%s\r\nStep=%d\r\nResumed=%d\r\nDownload=%s\r\n" % (
            state, percent, " ".join(str(detail).split()), step, 1 if resumed else 0, " ".join(download.split()))
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-16", newline="") as f:
            f.write(text)
        # The app reads the file every 200 ms, and Windows refuses to replace it during a read (#7).
        # Wait for the read to end. A progress update that still cannot be written is skipped,
        # so it never stops the transcription; Done and Error must get through.
        for attempt in range(100):
            try:
                os.replace(tmp, path)
                return
            except PermissionError:
                if attempt == 99:
                    if state == "Working":
                        return
                    raise
                time.sleep(0.05)


class TimedLog:
    """Puts the time before every line, so a slow or stuck step shows in the log (#16)."""

    def __init__(self, f):
        self.f, self.at_start = f, True

    def write(self, text):
        import time
        for piece in str(text).splitlines(True):
            if self.at_start:
                self.f.write(time.strftime("%H:%M:%S "))
            self.f.write(piece)
            self.at_start = piece.endswith(("\n", "\r"))
        return len(text)

    def flush(self):
        self.f.flush()

    def fileno(self):
        return self.f.fileno()

    def isatty(self):
        return False

    @property
    def encoding(self):
        return self.f.encoding


def open_log(path, keep=1000000):
    """Adds to the log instead of replacing it, so the try before stays readable (#16).
    A log over keep bytes is cut to its newest half."""
    try:
        if os.path.getsize(path) > keep:
            with open(path, "rb") as f:
                f.seek(-(keep // 2), 2)
                tail = f.read()
            with open(path, "wb") as f:
                f.write(tail[tail.find(b"\n") + 1:])
    except OSError:
        pass
    return TimedLog(open(path, "a", encoding="utf-8", errors="replace", buffering=1))


class stage:
    """Logs when a stage starts, and how long it took."""

    def __init__(self, name):
        self.name = name

    def __enter__(self):
        import time
        self.start = time.time()
        print(self.name + ": starting")

    def __exit__(self, kind, error, trace):
        import time
        print("%s %s in %.1f s" % (self.name, "ready" if kind is None else "failed", time.time() - self.start))


def folder_bytes(folder):
    total = 0
    for top, dirs, files in os.walk(folder):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(top, name))
            except OSError:
                pass
    return total


def size_text(done, total):
    if total >= 1e9:
        return "%.1f of %.1f GB" % (done / 1e9, total / 1e9)
    return "%d of %d MB" % (round(done / 1e6), round(total / 1e6))


def time_left_text(seconds):
    if seconds is None:
        return "working out the time left"
    if seconds < 60:
        return "less than a minute left"
    hours, minutes = divmod(round(seconds / 60), 60)
    if not hours:
        return "about %d min left" % minutes
    return "about %d h %d min left" % (hours, minutes) if minutes else "about %d h left" % hours


class Download:
    """Runs download() in a thread and measures how much of total bytes has reached folder (#16).
    huggingface_hub writes in 10 MB chunks, so at 0.1 MB/s the file grows only every 100 s;
    stall is how long no growth counts as stuck."""

    def __init__(self, label, folder, total, download, stall=300):
        self.label, self.folder, self.total, self.stall, self.error = label, folder, total, stall, None
        self.begin = self.moved = self.logged = time.time()
        self.first = self.done = folder_bytes(folder)
        print("Downloading %s to %s: %s" % (label, folder, size_text(self.done, total)))

        def run():
            try:
                download()
            except BaseException as e:
                self.error = e

        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def running(self):
        return self.thread.is_alive()

    def stalled(self):
        return time.time() - self.moved >= self.stall

    def poll(self):
        now, done = time.time(), folder_bytes(self.folder)
        if done != self.done:
            self.done, self.moved = done, now
        if now - self.logged >= 30:
            print("Downloading %s: %s, %.2f MB/s, %s" % (self.label, size_text(done, self.total),
                  (done - self.first) / 1e6 / max(now - self.begin, 1), time_left_text(self.left())))
            self.logged = now

    def left(self):
        rate = (self.done - self.first) / max(time.time() - self.begin, 0.001)
        return max(self.total - self.done, 0) / rate if rate > 0 else None

    def progress(self):
        """"0.4 of 1.6 GB, about 12 min left" """
        self.poll()
        return "%s, %s" % (size_text(min(self.done, self.total), self.total), time_left_text(self.left()))

    def text(self):
        """The line beside the steps while this downloads in the background; "" when it is not."""
        if not self.running() or self.stalled():
            return ""
        return "Also downloading %s, only this first time: %s. Until it is done, times are less exact." % (self.label, self.progress())

    def report(self):
        """Logs how it ended; raises the download's error."""
        if self.running():
            print("Download of %s made no progress for %d s, at %s" % (self.label, self.stall, size_text(self.done, self.total)))
        elif self.error is not None:
            print("Download of %s failed: %r" % (self.label, self.error))
            raise self.error
        else:
            print("Downloaded %s in %.0f s" % (self.label, time.time() - self.begin))


def fetch(status, label, folder, total, download, stall=300, step=1, resumed=False):
    """Downloads what is needed before transcribing can start, showing how far it is (#16).
    True when done; False when nothing arrived for stall seconds. Raises the download's error."""
    d = Download(label, folder, total, download, stall)
    while d.running() and not d.stalled():
        set_state(status, "Working", 0, "Downloading " + label, step, resumed,
                  download="Downloading %s, only this first time: %s." % (label, d.progress()))
        d.thread.join(0.5)
    d.poll()
    d.report()
    return not d.running()


def start_background(d):
    """Shows d beside the steps, refreshed every second, while the transcript is written (#16)."""
    global background
    background = d

    def tick():
        while d.running():
            time.sleep(1)
            with state_lock:
                if last_state is not None and background is d:
                    set_state(*last_state)

    threading.Thread(target=tick, daemon=True).start()


def finish_background():
    """Waits for the background download, so the next transcript has the model; gives up when it
    is stuck, and a later try resumes it."""
    global background
    d = background
    if d is None:
        return
    while d.running() and not d.stalled():
        d.thread.join(1)
        d.poll()
    try:
        d.report()
    except BaseException:
        pass
    background = None


def hub_folder(repo):
    from huggingface_hub import constants
    return os.path.join(constants.HF_HUB_CACHE, "models--" + repo.replace("/", "--"))


def hub_files(repo):
    """{file name: bytes} of a model on the Hugging Face Hub."""
    from huggingface_hub import HfApi
    info = HfApi().model_info(repo, files_metadata=True, timeout=30)
    return {s.rfilename: s.size or 0 for s in info.siblings}


def is_cached(repo, names):
    from huggingface_hub import try_to_load_from_cache
    return any(isinstance(try_to_load_from_cache(repo, name), str) for name in names)


def get_speech_model(status, model_name, resumed):
    """Downloads the speech model the first time, showing how far it is."""
    import fnmatch
    from faster_whisper.utils import _MODELS, download_model
    repo = _MODELS.get(model_name, model_name)
    if is_cached(repo, ["model.bin"]):
        print("Speech model %s is on this PC" % repo)
        return
    patterns = ["config.json", "preprocessor_config.json", "model.bin", "tokenizer.json", "vocabulary.*"]
    try:
        files = hub_files(repo)
        total = sum(size for name, size in files.items() if any(fnmatch.fnmatch(name, p) for p in patterns))
        done = fetch(status, "the speech model", hub_folder(repo), total, lambda: download_model(model_name), resumed=resumed)
    except Exception as e:
        raise RuntimeError("Could not download the speech model. Check the internet connection and try again. (%s)" % e)
    if not done:
        raise RuntimeError("The speech model download stopped. Check the internet connection and try again.")


def get_align_model(language):
    """True when the word-timing model for the language is on this PC. Otherwise it starts
    downloading in the background, and this transcript goes on without word timing (#16)."""
    from whisperx.alignment import DEFAULT_ALIGN_MODELS_HF
    repo = DEFAULT_ALIGN_MODELS_HF.get(language)
    weights = ["model.safetensors", "pytorch_model.bin"]
    if repo is None or is_cached(repo, weights):
        print("Word-timing model %s is on this PC or comes with WhisperX" % (repo or language))
        return True
    from huggingface_hub import snapshot_download
    files = hub_files(repo)
    keep = [name for name in files if name.endswith(".json")] + [next(w for w in weights if w in files)]
    start_background(Download("the word-timing model", hub_folder(repo), sum(files[n] for n in keep),
                              lambda: snapshot_download(repo, allow_patterns=keep)))
    return False


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


def part_paths(wav, out, model_name):
    """Where each finished part is kept until the transcript is done (#12). The name depends on
    the recording, its size and time, and the model, so a part never belongs to another file."""
    import hashlib

    st = os.stat(wav)
    key = "%s|%d|%d|%s" % (os.path.abspath(wav).lower(), st.st_size, int(st.st_mtime), model_name)
    name = hashlib.sha1(key.encode("utf-8")).hexdigest()[:16]
    folder = os.path.join(os.path.dirname(os.path.abspath(out)), "parts")
    return {speaker: os.path.join(folder, "%s.%s.tsv" % (name, speaker)) for speaker in ("Others", "Me")}


def read_part(path):
    """(language, rows) of a saved part, or None when there is none."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except OSError:
        return None
    if not lines or not lines[0].startswith("# language="):
        return None
    return lines[0][len("# language="):], [line for line in lines[1:] if line]


def write_part(path, language, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write("# language=%s\n" % language + "".join(row + "\n" for row in rows))
    os.replace(tmp, path)


def main(wav, status, out, hint="", model_name="large-v3-turbo"):
    import time
    sys.stdout = sys.stderr = open_log(status + ".log")
    print("=== Transcribing %s with %s, %s ===" % (os.path.basename(wav), model_name, time.strftime("%Y-%m-%d")))
    print("Python %s, %d logical cores, process %d" % (sys.version.split()[0], os.cpu_count() or 0, os.getpid()))
    try:
        # Below normal priority: a new recording may start while this runs.
        import ctypes
        ctypes.windll.kernel32.SetPriorityClass(ctypes.windll.kernel32.GetCurrentProcess(), 0x4000)
    except Exception:
        pass
    # Each finished part is saved, so a new try picks up where the last one stopped (#12).
    parts = part_paths(wav, out, model_name)
    saved = {speaker: read_part(path) for speaker, path in parts.items()}
    resumed = saved["Others"] is not None
    if resumed:
        print("Picking up where it stopped: what others said was saved by an earlier try")
    set_state(status, "Working", 0, "Loading the speech model", 1, resumed)
    with stage("Libraries"):
        import torch
        import whisperx
        from importlib.metadata import version
        print("torch %s, whisperx %s, faster-whisper %s, huggingface_hub %s" % (
            torch.__version__, version("whisperx"), version("faster-whisper"), version("huggingface_hub")))

    # Half the logical cores is as fast as all but one (measured on a 12-thread i7-1255U)
    # and leaves the PC free for the call.
    threads = max(1, (os.cpu_count() or 2) // 2)
    torch.set_num_threads(threads)
    print("Threads: %d" % threads)
    print("Hint:", hint)
    language = next((part[0] for part in saved.values() if part), None)
    model = align_model = align_meta = left = right = None
    if None in saved.values():
        with stage("Audio"):
            left, right = read_channels(wav)
            print("%.0f s of audio" % (len(left) / SAMPLE_RATE))
        get_speech_model(status, model_name, resumed)
        set_state(status, "Working", 0, "Loading the speech model", 1, resumed)
        with stage("Speech model"):
            model = whisperx.load_model(
                model_name, "cpu", compute_type="int8", threads=threads, asr_options={"initial_prompt": hint.strip() or None}
            )
        if language is None:
            with stage("Language"):
                language = model.detect_language(language_sample(left, right))
        # No word-timing model for this language yet, or offline: keep WhisperX's own times (#16).
        try:
            if get_align_model(language):
                with stage("Word-timing model"):
                    align_model, align_meta = whisperx.load_align_model(language_code=language, device="cpu")
            else:
                print("Word timing skipped for this transcript: its model downloads in the background.")
        except Exception as e:
            print("Word timing skipped:", repr(e))
            align_model = align_meta = None
    print("Language:", language)

    rows = []
    for index, (speaker, label) in enumerate([("Others", "Writing down what others said"), ("Me", "Writing down what you said")]):
        if saved[speaker] is not None:
            rows += saved[speaker][1]
            continue
        audio = left if index == 0 else right
        base, step = 10 + index * 45, 3 + index
        # Finding where people speak comes before the first progress; for Me it is part of step 4.
        if index == 0:
            set_state(status, "Working", base, "Finding where people speak", 2, resumed)
        else:
            set_state(status, "Working", base, label, step, resumed)

        tenths = [0]

        def progress(pct, base=base, label=label, step=step):
            set_state(status, "Working", base + pct * 36 / 100, label, step, resumed)
            if int(pct) // 10 > tenths[0]:
                tenths[0] = int(pct) // 10
                print("%s transcript: %d%%" % (speaker, pct))

        with stage(speaker + " transcript"):
            result = model.transcribe(audio, batch_size=8, language=language, progress_callback=progress)
        segments = result["segments"]
        if segments and align_model is not None:
            try:
                with stage(speaker + " word timing"):
                    segments = whisperx.align(
                        segments, align_model, align_meta, audio, "cpu",
                        progress_callback=lambda pct, base=base, label=label, step=step: set_state(
                            status, "Working", base + 36 + pct * 9 / 100, label, step, resumed),
                    )["segments"]
            except Exception as e:
                print("Word timing failed for", speaker, ":", repr(e))
        part = []
        for s in segments:
            text = " ".join(str(s.get("text", "")).split())
            if text and s.get("start") is not None and s.get("end") is not None:
                part.append("%.3f\t%.3f\t%s\t%s" % (s["start"], s["end"], speaker, text))
        write_part(parts[speaker], language, part)
        rows += part

    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(rows) + ("\n" if rows else ""))
    os.replace(tmp, out)
    for path in parts.values():
        try:
            os.remove(path)
        except OSError:
            pass
    set_state(status, "Done", 100, "Transcript ready", 4, resumed)
    print("Transcript ready: %d lines" % len(rows))
    finish_background()


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
