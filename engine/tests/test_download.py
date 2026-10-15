import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import os
from pathlib import Path
import tempfile
import threading
import unittest

os.environ["NO_PROXY"]=os.environ.get("NO_PROXY","")+",127.0.0.1,localhost"

spec=importlib.util.spec_from_file_location("downloader",Path(__file__).resolve().parents[1]/"download_file.py")
downloader=importlib.util.module_from_spec(spec)
spec.loader.exec_module(downloader)
CONTENT=bytes(range(256))*19000
HASH=hashlib.sha256(CONTENT).hexdigest()


class RangeHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        start,end=map(int,self.headers["Range"].removeprefix("bytes=").split("-"))
        self.send_response(206)
        self.send_header("Content-Range",f"bytes {start}-{end}/{len(CONTENT)}")
        self.send_header("Content-Length",str(end-start+1))
        self.end_headers()
        self.wfile.write(CONTENT[start:end+1])
    def log_message(self,*args):
        pass


class DownloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server=ThreadingHTTPServer(("127.0.0.1",0),RangeHandler)
        cls.thread=threading.Thread(target=cls.server.serve_forever,daemon=True)
        cls.thread.start()
        cls.url=f"http://127.0.0.1:{cls.server.server_port}/file"
    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown();cls.server.server_close();cls.thread.join()
    def test_resumes_seed_and_verifies_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory)/"model.bin"
            seed=Path(directory)/"seed"
            seed.write_bytes(CONTENT[:600000])
            downloader.download(self.url,target,len(CONTENT),HASH,workers=2,seed=seed)
            self.assertEqual(target.read_bytes(),CONTENT)
            self.assertFalse(Path(str(target)+".parts").exists())
    def test_hash_mismatch_never_installs_target(self):
        with tempfile.TemporaryDirectory() as directory:
            target=Path(directory)/"model.bin"
            with self.assertRaisesRegex(RuntimeError,"verification failed"):
                downloader.download(self.url,target,len(CONTENT),"0"*64,workers=2)
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
