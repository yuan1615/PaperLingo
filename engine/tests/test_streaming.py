import base64
import importlib.util
import json
from pathlib import Path
import threading
import unittest
from unittest.mock import patch
import urllib.request
import uuid
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("stream_bridge", Path(__file__).resolve().parents[1] / "server.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class SegmentationTests(unittest.TestCase):
    def test_sentences_abbreviations_decimals_and_full_text(self):
        text = 'Dr. Smith uses Fig. 2 and e.g. a 3.14 ratio. "Does it generalize?" Yes, it does!'
        parts = bridge.speech_segments(text)
        self.assertEqual(parts, ['Dr. Smith uses Fig. 2 and e.g. a 3.14 ratio.', '"Does it generalize?"', 'Yes, it does!'])
        self.assertEqual(" ".join(parts), text)

    def test_long_sentence_is_bounded_without_omissions(self):
        text = "Although the experiment is computationally expensive, " + "the robust model generalizes across domains, " * 50 + "we observe consistent improvements."
        parts = bridge.speech_segments(text)
        self.assertLessEqual(len(parts[0]), 120)
        self.assertTrue(all(0 < len(part) <= 160 for part in parts))
        self.assertEqual(" ".join(parts), text)

    def test_empty_whitespace_and_unbroken_tokens(self):
        self.assertEqual(bridge.speech_segments(" \n\t"), [])
        self.assertEqual(bridge.speech_segments("Hello.\n\nWorld!"), ["Hello.", "World!"])
        parts = bridge.speech_segments("x" * 1000)
        self.assertEqual("".join(parts), "x" * 1000)
        self.assertTrue(all(len(part) <= 160 for part in parts))


class StreamingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), bridge.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = "http://127.0.0.1:%d" % cls.server.server_port
        cls.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join()

    def post(self, path, payload):
        return self.opener.open(urllib.request.Request(self.base + path, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}), timeout=5)

    def line(self, response):
        return json.loads(response.readline())

    def test_first_audio_is_delivered_while_next_inference_is_blocked(self):
        release, second_started = threading.Event(), threading.Event()
        calls = []
        def fake(text, speed, voice, cancelled, reference=None):
            calls.append(text)
            if len(calls) == 2:
                second_started.set()
                if not release.wait(4):
                    raise RuntimeError("Test did not release second inference")
            return b"RIFF-test-audio"
        try:
            with patch.object(bridge, "synthesize", fake):
                with self.post("/speak/stream", {"request_id":str(uuid.uuid4()), "text":"The first sentence is ready. The second sentence is still being generated."}) as response:
                    self.assertEqual(self.line(response), {"type":"start", "total":2})
                    first = self.line(response)
                    self.assertEqual(first["index"], 1)
                    self.assertEqual(base64.b64decode(first["audio"]), b"RIFF-test-audio")
                    self.assertTrue(second_started.wait(2))
                    self.assertFalse(release.is_set())
                    release.set()
                    self.assertEqual(self.line(response)["index"], 2)
                    self.assertEqual(self.line(response)["type"], "done")
        finally:
            release.set()

    def test_cancel_during_inference_prevents_later_segments(self):
        identifier = str(uuid.uuid4())
        second_started = threading.Event()
        calls = []
        def fake(text, speed, voice, cancelled, reference=None):
            calls.append(text)
            if len(calls) == 2:
                second_started.set()
                cancelled.wait(3)
                bridge.check_cancelled(cancelled)
            return b"audio"
        with patch.object(bridge, "synthesize", fake):
            with self.post("/speak/stream", {"request_id":identifier,"text":"First sentence. Second sentence. Third sentence."}) as response:
                self.line(response); self.assertEqual(self.line(response)["index"], 1)
                self.assertTrue(second_started.wait(2))
                with self.post("/cancel", {"request_id":identifier}) as cancel:
                    self.assertTrue(json.load(cancel)["cancelled"])
                self.assertEqual(self.line(response)["type"], "cancelled")
                self.assertEqual(len(calls), 2)

    def test_cancel_arriving_before_stream_registration(self):
        identifier = str(uuid.uuid4())
        with self.post("/cancel", {"request_id":identifier}) as response:
            self.assertTrue(json.load(response)["cancelled"])
        with patch.object(bridge, "synthesize") as synth:
            with self.post("/speak/stream", {"request_id":identifier,"text":"Never synthesize this."}) as response:
                self.line(response)
                self.assertEqual(self.line(response)["type"], "cancelled")
            synth.assert_not_called()

    def test_later_error_does_not_buffer_or_discard_first_segment(self):
        with patch.object(bridge, "synthesize", side_effect=[b"audio", RuntimeError("inference failure")]):
            with self.post("/speak/stream", {"request_id":str(uuid.uuid4()),"text":"First sentence. Second sentence."}) as response:
                self.line(response)
                self.assertEqual(self.line(response)["type"], "audio")
                self.assertEqual(self.line(response), {"type":"error","error":"inference failure"})


if __name__ == "__main__":
    unittest.main()
