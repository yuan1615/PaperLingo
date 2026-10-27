import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
import threading
import types
import unittest
from unittest.mock import Mock, patch
import urllib.error
import urllib.request
import uuid
import wave
from http.server import ThreadingHTTPServer

spec=importlib.util.spec_from_file_location("voice_bridge",Path(__file__).parents[1]/"server.py")
bridge=importlib.util.module_from_spec(spec);spec.loader.exec_module(bridge)


class VoicePromptTests(unittest.TestCase):
    def setUp(self):
        self.work=tempfile.TemporaryDirectory()
        self.root=Path(self.work.name)
        buffer=io.BytesIO()
        with wave.open(buffer,"wb") as audio:
            audio.setnchannels(1);audio.setsampwidth(2);audio.setframerate(24000)
            audio.writeframes(struct.pack("<h",1000)*48000)
        self.audio=buffer.getvalue()
        self.entry={"id":"001","label":"Fixture 001","file":"001.wav","text":"Reference speech.","sha256":hashlib.sha256(self.audio).hexdigest()}
        (self.root/"001.wav").write_bytes(self.audio)
        self.write([self.entry])
        bridge.REFERENCE_VOICES,bridge.VOICE_CATALOG_SIGNATURE=bridge.load_voice_catalog(self.root)
        bridge.ARGS=types.SimpleNamespace(model="test-model",cache=self.work.name)
        bridge.MODEL=None
    def tearDown(self):
        bridge.REFERENCE_VOICES={};bridge.VOICE_CATALOG_SIGNATURE=None;bridge.MODEL=None
        self.work.cleanup()
    def write(self,entries):
        (self.root/"manifest.json").write_text(json.dumps({"version":1,"voices":entries}))
    def test_catalog_requires_matching_audio_and_transcript(self):
        reference=bridge.reference_for({"reference_voice":"001","voice_catalog":bridge.VOICE_CATALOG_SIGNATURE})
        self.assertEqual(reference["audio"],self.audio)
        self.assertEqual(reference["text"],"Reference speech.")
        self.assertIsNone(reference["prompt"])
        (self.root/"001.wav").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError,"checksum"):bridge.load_voice_catalog(self.root)
    def test_catalog_rejects_duplicate_traversal_and_empty_text(self):
        for entries in [[self.entry,self.entry],[dict(self.entry,file="../001.wav")],[dict(self.entry,text=" ")]]:
            self.write(entries)
            with self.assertRaises(ValueError):bridge.load_voice_catalog(self.root)
    def test_catalog_rejects_outward_symlink(self):
        with tempfile.TemporaryDirectory() as outside:
            target=Path(outside)/"audio.wav";target.write_bytes(self.audio)
            (self.root/"001.wav").unlink();(self.root/"001.wav").symlink_to(target)
            with self.assertRaises(ValueError):bridge.load_voice_catalog(self.root)
    def test_unknown_voice_or_stale_catalog_never_falls_back(self):
        for payload in [{"reference_voice":"missing"},{"reference_voice":"001","voice_catalog":"outdated"},{"reference_voice":[]}]:
            with self.assertRaises(ValueError):bridge.reference_for(payload)
    def test_short_words_use_reference_and_prompt_is_encoded_once(self):
        model=Mock();model.generate.return_value=[[0.1,0.2]]
        bridge.MODEL=model
        fake_torch=types.SimpleNamespace(inference_mode=contextlib.nullcontext,from_numpy=lambda x:x)
        fake_sf=types.SimpleNamespace(read=lambda *a,**kw:([0.1],24000),write=lambda buffer,*a,**kw:buffer.write(b"RIFF-result"))
        reference=bridge.REFERENCE_VOICES["001"]
        with patch.dict("sys.modules",{"torch":fake_torch,"soundfile":fake_sf,"omnivoice":types.SimpleNamespace(OmniVoice=Mock())}):
            bridge.synthesize("word",1,"american",reference=reference)
            bridge.synthesize("Another sentence.",1,"american",reference=reference)
            bridge.synthesize("word",1,"american",reference=reference)
            bridge.synthesize("word",.75,"american",reference=reference)
        self.assertEqual(model.create_voice_clone_prompt.call_count,1)
        self.assertEqual(model.generate.call_count,3)
        for call in model.generate.call_args_list:
            self.assertIn("voice_clone_prompt",call.kwargs)
            self.assertNotIn("instruct",call.kwargs)
    def test_cache_changes_with_reference_text(self):
        model=Mock();model.generate.return_value=[[0.1]];bridge.MODEL=model
        fake_torch=types.SimpleNamespace(inference_mode=contextlib.nullcontext,from_numpy=lambda x:x)
        fake_sf=types.SimpleNamespace(read=lambda *a,**kw:([0.1],24000),write=lambda buffer,*a,**kw:buffer.write(b"RIFF-result"))
        with patch.dict("sys.modules",{"torch":fake_torch,"soundfile":fake_sf,"omnivoice":types.SimpleNamespace(OmniVoice=Mock())}):
            bridge.synthesize("word",1,"american",reference=bridge.REFERENCE_VOICES["001"])
            bridge.synthesize("word",1,"american",reference=dict(bridge.REFERENCE_VOICES["001"],text="Corrected transcript.",prompt=None))
        self.assertEqual(model.generate.call_count,2)
    def test_stream_keeps_reference_for_first_and_all_later_segments(self):
        server=ThreadingHTTPServer(("127.0.0.1",0),bridge.Handler)
        worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
        payload={"request_id":str(uuid.uuid4()),"text":"One word. Another sentence.","reference_voice":"001","voice_catalog":bridge.VOICE_CATALOG_SIGNATURE}
        request=urllib.request.Request(f"http://127.0.0.1:{server.server_port}/speak/stream",data=json.dumps(payload).encode(),headers={"Content-Type":"application/json"})
        references=[]
        def fake(text,speed,voice,cancelled=None,reference=None):
            references.append(reference);return self.audio
        try:
            with patch.object(bridge,"synthesize",fake),opener.open(request,timeout=4) as response:
                events=[json.loads(line) for line in response]
            self.assertEqual([e["type"] for e in events],["start","audio","audio","done"])
            self.assertEqual(len(references),2)
            self.assertTrue(all(r is bridge.REFERENCE_VOICES["001"] for r in references))
        finally:server.shutdown();server.server_close();worker.join()


if __name__=="__main__":unittest.main()
