import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import types
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch
from http.server import ThreadingHTTPServer

spec=importlib.util.spec_from_file_location("rerank_bridge_test",Path(__file__).parents[1]/"server.py")
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)


class RerankProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root=tempfile.TemporaryDirectory()
        (Path(cls.root.name)/"model.safetensors").write_bytes(b"fixture")
        bridge.ARGS=types.SimpleNamespace(reranker=cls.root.name)
        cls.server=ThreadingHTTPServer(("127.0.0.1",0),bridge.Handler)
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True);cls.thread.start()
        cls.url=f"http://127.0.0.1:{cls.server.server_port}/rerank"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown();cls.server.server_close();cls.thread.join();cls.root.cleanup()

    def request(self,payload,origin=False):
        headers={"Content-Type":"application/json"}
        if origin:headers["Origin"]="https://example.com"
        return urllib.request.urlopen(urllib.request.Request(self.url,data=json.dumps(payload).encode(),headers=headers),timeout=3)

    def test_local_reranking_returns_one_score_per_document(self):
        fake=types.SimpleNamespace(score=lambda q,docs:[0.9,0.01])
        with patch.object(bridge,"RERANKER",fake):
            with self.request({"query":"streaming speech","documents":["Speech chunks","Image classifier"]}) as r:
                result=json.load(r)
        self.assertEqual(result["scores"],[0.9,0.01]);self.assertEqual(result["model"],"Qwen3-Reranker-0.6B")

    def test_origin_invalid_documents_and_size_are_rejected(self):
        for body,origin,expected in [({"query":"x","documents":["y"]},True,403),({"query":"x","documents":[]},False,400),({"query":"x","documents":["z"*4001]},False,400),({"query":"x","documents":["z"]*33},False,400)]:
            with self.assertRaises(urllib.error.HTTPError) as error:self.request(body,origin)
            self.assertEqual(error.exception.code,expected)

    def test_missing_model_reports_unavailable_without_download(self):
        with patch.object(bridge,"ARGS",types.SimpleNamespace(reranker="")):
            with self.assertRaises(urllib.error.HTTPError) as error:self.request({"query":"x","documents":["y"]})
        self.assertEqual(error.exception.code,503)
