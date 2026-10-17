"""LiveSub 워커 — stdin으로 받은 시스템 오디오를 일본어로 인식하고 한국어로 번역해 stdout(JSON 줄)으로 보냄.

입력 프레임: [sample_rate:uint32][n:uint32][float32 * n]  (모노)
출력: {"t":"status","msg":...} / {"t":"ja","id":n,"text":...} / {"t":"ko","id":n,"text":...}
"""
import collections
import json
import os
import platform
import queue
import re
import struct
import sys
import threading
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = {}
try:
    with open(os.path.join(HERE, "config.json"), encoding="utf-8") as f:
        CFG = json.load(f)
except Exception:
    pass

SRC_LANG = CFG.get("source_lang", "ja")
TGT_LANG = CFG.get("target_lang", "ko")
API_KEY = CFG.get("api_key") or os.environ.get("ANTHROPIC_API_KEY", "")
CLAUDE_MODEL = CFG.get("claude_model", "claude-haiku-4-5")
GLOSSARY = CFG.get("glossary", "")
APPLE_SILICON = platform.system() == "Darwin" and platform.machine() == "arm64"
MLX_REPO = CFG.get("mlx_model", "mlx-community/whisper-large-v3-turbo")
FW_MODEL = CFG.get("fw_model", "small")

SR = 16000
FRAME = 480                  # 30ms
MAX_SEG = 7.0                # 한 구간 최대 길이(초) — 길수록 정확, 짧을수록 빠름
END_SILENCE = 0.45           # 이만큼 조용하면 문장 끝으로 봄
MIN_SEG = 0.6

_out_lock = threading.Lock()


def emit(**kw):
    with _out_lock:
        sys.stdout.write(json.dumps(kw, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def log(*a):
    print(time.strftime("[%H:%M:%S]"), *a, file=sys.stderr, flush=True)


# ------------------------------------------------------------------ 음성 인식
class ASR:
    def __init__(self):
        if APPLE_SILICON:
            import mlx_whisper
            self.mlx = mlx_whisper
        else:
            from faster_whisper import WhisperModel
            self.fw = WhisperModel(FW_MODEL, device="cpu", compute_type="int8")

    def __call__(self, audio):
        if APPLE_SILICON:
            res = self.mlx.transcribe(
                audio, path_or_hf_repo=MLX_REPO, language=SRC_LANG, task="transcribe",
                temperature=(0.0, 0.4), condition_on_previous_text=False,
                no_speech_threshold=0.6, compression_ratio_threshold=2.2, logprob_threshold=-1.0,
                verbose=None,
            )
            segs = res.get("segments", [])
            keep = [s["text"] for s in segs
                    if not (s.get("no_speech_prob", 0) > 0.6 and s.get("avg_logprob", 0) < -0.8)
                    and s.get("avg_logprob", 0) > -1.2]
            return "".join(keep).strip()
        segs, _ = self.fw.transcribe(audio, language=SRC_LANG, beam_size=1,
                                     condition_on_previous_text=False, vad_filter=False)
        return "".join(s.text for s in segs if s.no_speech_prob < 0.6 and s.avg_logprob > -1.2).strip()


# Whisper가 무음/음악에서 자주 지어내는 문장들
HALLUCINATIONS = re.compile(
    r"(ご視聴ありがとうございました|ご覧いただきありがとうございます|チャンネル登録|高評価|"
    r"字幕(は|を|作成|提供)|Thank you for watching|最後までご視聴)", re.I)


def clean(text):
    text = re.sub(r"(.{1,10}?)\1{3,}", r"\1\1", text)        # 같은 말 반복 축약
    text = re.sub(r"\s+", " ", text).strip()
    if not text or HALLUCINATIONS.search(text):
        return ""
    if re.fullmatch(r"[\W_ーぁ-ん]{0,2}", text):             # "あ", "ん" 같은 잡음
        return ""
    return text


# ------------------------------------------------------------------ 번역
class Translator:
    def __init__(self):
        self.client = None
        self.history = collections.deque(maxlen=4)
        if API_KEY:
            import anthropic
            self.client = anthropic.Anthropic(api_key=API_KEY)

    def __call__(self, text):
        if not self.client:
            return None
        ctx = "\n".join(f"JA: {j}\nKO: {k}" for j, k in self.history)
        system = (
            "You are a live subtitle translator for Japanese videos (anime, dramas, YouTube, talks). "
            "Translate the given Japanese line into natural, concise Korean subtitles that read well on screen. "
            "Use the earlier lines only as context to resolve omitted subjects, tone and names. "
            "The input comes from speech recognition and may contain small errors; infer the intended meaning. "
            "Output ONLY the Korean translation of the new line — no quotes, notes, or romanization."
            + (f"\nPreferred terms:\n{GLOSSARY}" if GLOSSARY.strip() else "")
        )
        user = (f"Earlier lines:\n{ctx}\n\n" if ctx else "") + f"New line:\n{text}"
        msg = self.client.messages.create(
            model=CLAUDE_MODEL, max_tokens=400, system=system,
            messages=[{"role": "user", "content": user}],
        )
        ko = "".join(c.text for c in msg.content if getattr(c, "type", "") == "text").strip()
        ko = ko.strip('"“”「」')
        self.history.append((text, ko))
        return ko


# ------------------------------------------------------------------ 입력 → 발화 구간 분할
def read_exact(stream, n):
    buf = b""
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def reader(seg_q):
    stdin = sys.stdin.buffer
    pending = np.zeros(0, dtype=np.float32)
    preroll = collections.deque(maxlen=8)          # 말 시작 직전 0.24초 포함
    seg, in_speech, silent = [], False, 0
    noise = 0.004

    while True:
        hdr = read_exact(stdin, 8)
        if hdr is None:
            break
        rate, n = struct.unpack("<II", hdr)
        raw = read_exact(stdin, n * 4)
        if raw is None:
            break
        x = np.frombuffer(raw, dtype=np.float32)
        if rate != SR and n > 0:
            m = int(round(n * SR / rate))
            x = np.interp(np.linspace(0, n - 1, m), np.arange(n), x).astype(np.float32)
        pending = np.concatenate([pending, x])

        while len(pending) >= FRAME:
            f, pending = pending[:FRAME], pending[FRAME:]
            rms = float(np.sqrt(np.mean(f * f)) + 1e-9)
            # 배경 소음 수준을 천천히 추적
            noise = 0.9 * noise + 0.1 * rms if rms < noise else 0.998 * noise + 0.002 * rms
            speech = rms > max(0.006, noise * 2.2)

            if not in_speech:
                preroll.append(f)
                if speech:
                    in_speech, silent = True, 0
                    seg = list(preroll)
                    preroll.clear()
                continue

            seg.append(f)
            silent = 0 if speech else silent + 1
            dur = len(seg) * FRAME / SR
            if silent * FRAME / SR >= END_SILENCE:
                if dur >= MIN_SEG + END_SILENCE:
                    seg_q.put(np.concatenate(seg))
                seg, in_speech = [], False
            elif dur >= MAX_SEG:
                seg_q.put(np.concatenate(seg))
                seg = []                          # 계속 말하는 중 — 이어서 다음 구간
    seg_q.put(None)


# ------------------------------------------------------------------ 메인
def main():
    emit(t="status", msg="음성 인식 모델 준비 중…", show=True)
    try:
        asr = ASR()
        asr(np.zeros(SR, dtype=np.float32))     # 모델 로드/워밍업
    except Exception as e:
        log("ASR init failed:", repr(e))
        emit(t="status", msg=f"인식 모델 오류: {e}", show=True)
        return
    tr = Translator()
    emit(t="status", msg="켜짐 — 영상을 재생하세요" if tr.client else "켜짐 (API 키 없음 · 일본어 원문만 표시)",
         show=True)

    seg_q, tr_q = queue.Queue(), queue.Queue()
    threading.Thread(target=reader, args=(seg_q,), daemon=True).start()

    def translate_loop():
        while True:
            item = tr_q.get()
            if item is None:
                return
            sid, text = item
            # 밀려 있으면 오래된 줄은 건너뛰고 최신 위주로
            while tr_q.qsize() > 2:
                nxt = tr_q.get()
                if nxt is None:
                    return
                sid, text = nxt
            try:
                ko = tr(text)
            except Exception as e:
                log("translate error:", repr(e))
                emit(t="status", msg=f"번역 오류: {type(e).__name__}", show=False)
                ko = None
            emit(t="ko", id=sid, text=ko if ko else text)

    threading.Thread(target=translate_loop, daemon=True).start()

    sid = 0
    while True:
        seg = seg_q.get()
        if seg is None:
            break
        dropped = 0
        while seg_q.qsize() > 1:                  # 인식이 밀리면 실시간성 유지를 위해 건너뜀
            nxt = seg_q.get()
            if nxt is None:
                seg = None
                break
            seg, dropped = nxt, dropped + 1
        if seg is None:
            break
        if dropped:
            log(f"skipped {dropped} segments (falling behind)")
        t0 = time.time()
        try:
            text = clean(asr(seg))
        except Exception as e:
            log("asr error:", repr(e))
            continue
        log(f"asr {len(seg)/SR:.1f}s audio in {time.time()-t0:.2f}s: {text}")
        if not text:
            continue
        sid += 1
        emit(t="ja", id=sid, text=text)
        tr_q.put((sid, text))
    tr_q.put(None)


if __name__ == "__main__":
    main()
