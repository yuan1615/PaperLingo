"""Loopback-only OmniVoice bridge. No cloud inference, no third-party HTTP server."""
import argparse
import base64
import hashlib
import io
import json
import os
import re
import time
import uuid
import wave
from pathlib import Path
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODEL = None
LOCK = threading.Lock()
LOAD_ERROR = None
ARGS = None
RERANKER = None
REQUESTS = {}
REQUEST_LOCK = threading.Lock()
REFERENCE_VOICES = {}
VOICE_CATALOG_SIGNATURE = None


def load_voice_catalog(directory):
    """Validate the local catalog before exposing any user-provided reference."""
    root = Path(directory).resolve()
    raw = (root / "manifest.json").read_bytes()
    document = json.loads(raw)
    entries = document.get("voices")
    if document.get("version") != 1 or not isinstance(entries, list) or not 1 <= len(entries) <= 100:
        raise ValueError("Invalid reference voice catalog")
    voices = {}
    for item in entries:
        identifier = item.get("id", "")
        text = item.get("text", "")
        label = item.get("label", "")
        if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", identifier) or identifier in voices:
            raise ValueError("Invalid or duplicate reference voice identifier")
        if item.get("file") != identifier + ".wav" or not isinstance(text, str) or not 1 <= len(text.strip()) <= 1000 or not isinstance(label, str) or not 1 <= len(label) <= 40:
            raise ValueError("Invalid reference voice file, text or label")
        path = (root / item["file"]).resolve()
        if not path.is_relative_to(root) or not path.is_file() or path.stat().st_size > 5_000_000:
            raise ValueError("Reference voice is missing or outside its catalog")
        audio = path.read_bytes()
        if hashlib.sha256(audio).hexdigest() != item.get("sha256"):
            raise ValueError("Reference voice checksum mismatch: " + identifier)
        with wave.open(io.BytesIO(audio)) as clip:
            duration = clip.getnframes() / clip.getframerate()
            if clip.getnchannels() != 1 or clip.getsampwidth() != 2 or clip.getframerate() != 24000 or not 1 <= duration <= 20:
                raise ValueError("Reference voice must be 1–20s mono 24kHz PCM16")
        voices[identifier] = {"id": identifier, "label": label, "text": text.strip(), "audio": audio, "prompt": None}
    return voices, hashlib.sha256(raw).hexdigest()


def reference_for(payload):
    identifier = payload.get("reference_voice")
    if identifier is None:
        return None
    if not isinstance(identifier, str) or identifier not in REFERENCE_VOICES:
        raise ValueError("Unknown reference voice; restart the speech engine")
    if payload.get("voice_catalog") != VOICE_CATALOG_SIGNATURE:
        raise ValueError("Reference voice catalog changed; restart the speech engine")
    return REFERENCE_VOICES[identifier]


class Cancelled(Exception):
    pass


def speech_segments(text, first_limit=120, limit=160):
    """Keep sentence boundaries, then clauses/words; send a shorter first segment.

    Unlike OmniVoice's internal long-audio chunking, each part is decoded and
    delivered immediately rather than waiting for the whole waveform.
    """
    remaining = re.sub(r"\s+", " ", text).strip()
    chunks = []
    abbreviations = {"dr", "mr", "mrs", "ms", "prof", "fig", "eq", "no", "vs", "etc", "al", "e.g", "i.e"}
    while remaining:
        cap = first_limit if not chunks else limit
        end = None
        for match in re.finditer(r'[.!?]+[\"”’\)\]]*(?=\s|$)', remaining):
            if match.end() > cap:
                break
            prefix = remaining[:match.start()]
            word = re.search(r"([A-Za-z.]+)$", prefix)
            if match.group().startswith(".") and word:
                token = word.group(1).lower()
                if token in abbreviations or (len(token) == 1 and token.isalpha()) or re.fullmatch(r"(?:[a-z]\.)+[a-z]", token):
                    continue
            end = match.end()
            break
        if end is None:
            if len(remaining) <= cap:
                end = len(remaining)
            else:
                # Prefer a breath at punctuation; never drop a clause or suffix.
                clauses = list(re.finditer(r"[,;:—](?=\s)", remaining[:cap + 1]))
                useful = [m.end() for m in clauses if m.end() >= cap // 3]
                end = useful[-1] if useful else remaining.rfind(" ", 0, cap + 1)
                if end <= 0:
                    end = cap
        chunks.append(remaining[:end].strip())
        remaining = remaining[end:].lstrip()
    return chunks


def request_event(identifier):
    with REQUEST_LOCK:
        now = time.monotonic()
        expired = [key for key, (_, created) in REQUESTS.items() if now - created > 600]
        for key in expired:
            REQUESTS.pop(key, None)
        if identifier not in REQUESTS:
            REQUESTS[identifier] = (threading.Event(), now)
        return REQUESTS[identifier][0]


def check_cancelled(event):
    if event is not None and event.is_set():
        raise Cancelled()



def synthesize(text, speed, voice, cancelled=None, reference=None):
    global MODEL, LOAD_ERROR
    signature = json.dumps(["omnivoice-0.2.1-reference-v3", ARGS.model, text, speed, voice, 16], ensure_ascii=False)
    if reference is not None:
        signature += "-reference-" + hashlib.sha256(reference["audio"] + reference["text"].encode("utf-8")).hexdigest()
    path = Path(ARGS.cache) / (hashlib.sha256(signature.encode()).hexdigest() + ".wav")
    while not LOCK.acquire(timeout=0.05):
        check_cancelled(cancelled)
    try:
        check_cancelled(cancelled)
        if path.exists():
            return path.read_bytes()
        import torch
        import soundfile as sf
        from omnivoice import OmniVoice
        if MODEL is None:
            try:
                device = "mps" if torch.backends.mps.is_available() else "cpu"
                MODEL = OmniVoice.from_pretrained(
                    ARGS.model, device_map=device,
                    dtype=torch.float16 if device == "mps" else torch.float32,
                )
                LOAD_ERROR = None
            except Exception as exc:
                LOAD_ERROR = str(exc)
                raise
        with torch.inference_mode():
            if reference is None:
                samples = MODEL.generate(text=text, language="en", instruct=f"female, {voice} accent", speed=speed, num_step=16)
            else:
                # User references are encoded once per engine lifetime and reused
                # for every word, sentence, speed and segment in this app session.
                if reference.get("prompt") is None:
                    waveform, rate = sf.read(io.BytesIO(reference["audio"]), dtype="float32")
                    reference["prompt"] = MODEL.create_voice_clone_prompt(
                        ref_audio=(torch.from_numpy(waveform), rate),
                        ref_text=reference["text"], preprocess_prompt=False,
                    )
                check_cancelled(cancelled)
                samples = MODEL.generate(text=text, language="en", voice_clone_prompt=reference["prompt"], speed=speed, num_step=16)
        buffer = io.BytesIO()
        sf.write(buffer, samples[0], 24000, format="WAV")
        data = buffer.getvalue()
        temporary = path.with_suffix(".tmp")
        temporary.write_bytes(data)
        temporary.replace(path)
        return data
    finally:
        LOCK.release()


class Handler(BaseHTTPRequestHandler):
    def json_response(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path != "/health":
            self.json_response(404, {"error": "Not found"})
            return
        import importlib.util
        available = importlib.util.find_spec("omnivoice") is not None
        self.json_response(200, {"service": "paperlingo-omnivoice", "protocol": 3, "installed": available,
                                 "loaded": MODEL is not None, "busy": LOCK.locked(), "error": LOAD_ERROR,
                                 "reranker_installed": bool(getattr(ARGS,"reranker","") and (Path(ARGS.reranker)/"model.safetensors").is_file()),
                                 "reranker_loaded": RERANKER is not None,
                                 "voice_catalog": VOICE_CATALOG_SIGNATURE,
                                 "reference_voices": [{"id": v["id"], "label": v["label"]} for v in REFERENCE_VOICES.values()]})

    def event(self, payload):
        self.wfile.write(json.dumps(payload, ensure_ascii=False).encode() + b"\n")
        self.wfile.flush()

    def do_POST(self):
        if self.path not in ("/speak", "/speak/stream", "/cancel", "/rerank"):
            self.json_response(404, {"error": "Not found"})
            return
        if self.headers.get("Origin") or self.headers.get("Content-Type", "").split(";")[0] != "application/json":
            self.json_response(403, {"error": "Native JSON clients only"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 1 <= length <= (524288 if self.path == "/rerank" else 65536):
                raise ValueError("Request must be 1–65536 bytes")
            payload = json.loads(self.rfile.read(length))
            if not isinstance(payload, dict):
                raise ValueError("Expected a JSON object")
            if self.path == "/rerank":
                query=payload.get("query");documents=payload.get("documents")
                if not isinstance(query,str) or not 1 <= len(query.strip()) <= 1000 or not isinstance(documents,list) or not 1 <= len(documents) <= 32 or not all(isinstance(d,str) and 1 <= len(d) <= 4000 for d in documents):
                    raise ValueError("Invalid reranking query or documents")
                self.rerank(query,documents)
                return
            if self.path in ("/cancel", "/speak/stream"):
                identifier = str(uuid.UUID(payload.get("request_id", "")))
                cancelled = request_event(identifier)
            if self.path == "/cancel":
                cancelled.set()
                self.json_response(200, {"cancelled": True})
                return
            text = payload.get("text", "").strip()
            speed = float(payload.get("speed", 1.0))
            voice = payload.get("voice", "american")
            reference = reference_for(payload)
            maximum = 12000 if self.path == "/speak/stream" else 2000
            if not text or len(text) > maximum or not 0.5 <= speed <= 1.5 or voice not in ("american", "british"):
                raise ValueError("Invalid text, speed or voice")
        except (ValueError, TypeError, AttributeError, OverflowError) as exc:
            self.json_response(400, {"error": str(exc)})
            return
        if self.path == "/speak/stream":
            self.stream(text, speed, voice, identifier, cancelled, reference=reference)
            return
        try:
            data = synthesize(text, speed, voice, reference=reference)
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as exc:
            self.json_response(503, {"error": str(exc)})

    def stream(self, text, speed, voice, identifier, cancelled, reference=None):
        parts = speech_segments(text)
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.event({"type": "start", "total": len(parts)})
            started = time.monotonic()
            for index, part in enumerate(parts, 1):
                check_cancelled(cancelled)
                data = synthesize(part, speed, voice, cancelled, reference=reference)
                check_cancelled(cancelled)
                self.event({"type": "audio", "index": index, "text": part,
                            "audio": base64.b64encode(data).decode("ascii")})
                if reference is None and len(part.split()) >= 8 and len(data) > 96044:
                    reference = {"audio": data, "text": part}
                print(f"Speech {identifier[:8]} segment {index}/{len(parts)} delivered at {time.monotonic()-started:.2f}s", flush=True)
            self.event({"type": "done", "total": len(parts)})
        except Cancelled:
            try:
                self.event({"type": "cancelled"})
            except (BrokenPipeError, ConnectionResetError):
                pass
        except (BrokenPipeError, ConnectionResetError):
            cancelled.set()
        except Exception as exc:
            import traceback
            traceback.print_exc()
            try:
                self.event({"type": "error", "error": str(exc)})
            except (BrokenPipeError, ConnectionResetError):
                pass
        finally:
            with REQUEST_LOCK:
                REQUESTS.pop(identifier, None)

    def rerank(self, query, documents):
        global RERANKER
        try:
            path=getattr(ARGS,"reranker","")
            if not path or not (Path(path)/"model.safetensors").is_file():
                raise RuntimeError("Local reranker is not installed")
            with LOCK:
                if RERANKER is None:
                    from rerank import LocalReranker
                    RERANKER=LocalReranker(path)
                scores=RERANKER.score(query,documents)
            self.json_response(200,{"scores":scores,"model":"Qwen3-Reranker-0.6B","revision":"e61197ed45024b0ed8a2d74b80b4d909f1255473"})
        except (BrokenPipeError,ConnectionResetError):
            pass
        except Exception as exc:
            import traceback
            traceback.print_exc()
            self.json_response(503,{"error":str(exc)})


def main():
    global ARGS, REFERENCE_VOICES, VOICE_CATALOG_SIGNATURE
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--model", default="k2-fsa/OmniVoice")
    parser.add_argument("--cache", required=True)
    parser.add_argument("--reranker", default="")
    parser.add_argument("--voices", default="")
    ARGS = parser.parse_args()
    if ARGS.voices:
        REFERENCE_VOICES, VOICE_CATALOG_SIGNATURE = load_voice_catalog(ARGS.voices)
    Path(ARGS.cache).mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    print(f"OmniVoice bridge ready on 127.0.0.1:{ARGS.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
