"""Loopback-only model fixture; never loads a model or touches user records."""
import json
from pathlib import Path
import select
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
STATE = {"delay": 0.05, "unloadDelay": 0, "outcome": "valid", "calls": 0, "active": 0, "events": [], "last_request": {}}

def event(kind):
    with LOCK:
        STATE["events"].append({"kind": kind, "time": time.monotonic()})

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def reply(self, data):
        raw = json.dumps(data, ensure_ascii=False).encode()
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def do_GET(self):
        with LOCK:
            data = json.loads(json.dumps(STATE))
        self.reply(data)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        if self.path == "/test/configure":
            with LOCK:
                STATE.update({key: body[key] for key in ("delay", "outcome", "unloadDelay") if key in body})
            self.reply({"ok": True})
            return
        if self.path == "/api/generate":
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                with LOCK:
                    if STATE["active"] == 0:
                        break
                time.sleep(0.01)
            with LOCK:
                unload_delay = STATE["unloadDelay"]
            time.sleep(unload_delay)
            event("unload")
            self.reply({"done": True})
            return
        if str(body.get("model", "")).startswith("translategemma"):
            with LOCK:
                STATE["last_translation"] = body
            event("translation")
            self.reply({"done": True, "message": {"content": "即时译文"}})
            return
        with LOCK:
            STATE["calls"] += 1
            STATE["active"] += 1
            STATE["last_request"] = body
            delay, outcome = STATE["delay"], STATE["outcome"]
        event("chat")
        try:
            deadline = time.monotonic() + delay
            while time.monotonic() < deadline:
                if select.select([self.connection], [], [], 0.01)[0]:
                    try:
                        if not self.connection.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT):
                            event("cancelled")
                            return
                    except BlockingIOError:
                        pass
            content = {"meaning": "形容词；本句指稳健的。", "inContext": "指估计结果在干扰下仍然保持稳定，强调可靠性。", "usage": "robust to noise：对噪声具有抵抗力。"}
            if outcome == "long":
                content["inContext"] = "长" * 200
            text = "{incomplete" if outcome == "invalid" else json.dumps(content, ensure_ascii=False)
            self.reply({"done": True, "done_reason": "length" if outcome == "length" else "stop", "message": {"content": text}})
        finally:
            with LOCK:
                STATE["active"] -= 1

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
