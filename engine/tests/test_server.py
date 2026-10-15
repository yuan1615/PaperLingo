import importlib.util
import json
from pathlib import Path
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("bridge", Path(__file__).resolve().parents[1] / "server.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), bridge.Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = "http://127.0.0.1:%d" % cls.server.server_port
        cls.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def request(self, path, payload=None, headers=None):
        request = urllib.request.Request(self.base + path, data=json.dumps(payload).encode() if payload is not None else None,
                                         headers=headers or {"Content-Type": "application/json"})
        try:
            with self.opener.open(request) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def test_health_reports_real_service(self):
        status, body = self.request("/health")
        self.assertEqual(status, 200)
        self.assertEqual(body["service"], "paperlingo-omnivoice")
        self.assertFalse(body["loaded"])

    def test_browser_origin_is_rejected(self):
        status, _ = self.request("/speak", {"text": "hello"}, {"Content-Type": "application/json", "Origin": "https://example.org"})
        self.assertEqual(status, 403)

    def test_simple_form_is_rejected(self):
        status, _ = self.request("/speak", {"text": "hello"}, {"Content-Type": "text/plain"})
        self.assertEqual(status, 403)

    def test_invalid_speed_empty_or_oversized_text(self):
        for payload in [{"text": ""}, {"text": "x" * 2001}, {"text": "hello", "speed": 9}, {"text": "hello", "voice": "unknown"}]:
            self.assertEqual(self.request("/speak", payload)[0], 400)

    def test_unknown_routes_are_not_speech_endpoints(self):
        self.assertEqual(self.request("/arbitrary")[0], 404)
        self.assertEqual(self.request("/arbitrary", {"text": "hello"})[0], 404)


if __name__ == "__main__":
    unittest.main()
