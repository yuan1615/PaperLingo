"""Local reference-cloning smoke test and private listening previews."""
import argparse
import base64
import hashlib
import io
import json
from pathlib import Path
import time
import urllib.request
import uuid
import wave

TEXT="Careful reading helps us understand new ideas. Please listen to the complete sentence."
OPENER=urllib.request.build_opener(urllib.request.ProxyHandler({}))


def generate(port,voice,signature):
    payload={"request_id":str(uuid.uuid4()),"text":TEXT,"reference_voice":voice["id"],"voice_catalog":signature}
    request=urllib.request.Request(f"http://127.0.0.1:{port}/speak/stream",data=json.dumps(payload).encode(),headers={"Content-Type":"application/json"})
    started=time.monotonic();first=None;frames=[];indices=[]
    with OPENER.open(request,timeout=300) as response:
        for line in response:
            event=json.loads(line)
            if event["type"]=="error":raise RuntimeError(event["error"])
            if event["type"]=="audio":
                first=first if first is not None else time.monotonic()-started
                with wave.open(io.BytesIO(base64.b64decode(event["audio"]))) as clip:
                    assert clip.getframerate()==24000 and clip.getnchannels()==1 and clip.getsampwidth()==2
                    frames.append(clip.readframes(clip.getnframes()));indices.append(event["index"])
            if event["type"]=="done":assert event["total"]==len(indices)
    assert indices==list(range(1,len(indices)+1)) and len(indices)>=2
    buffer=io.BytesIO()
    with wave.open(buffer,"wb") as clip:
        clip.setnchannels(1);clip.setsampwidth(2);clip.setframerate(24000);clip.writeframes(b"".join(frames))
    return buffer.getvalue(),{"first_audio_seconds":round(first,3),"total_seconds":round(time.monotonic()-started,3),"segments":len(indices)}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port",type=int,default=8766)
    parser.add_argument("--catalog",required=True)
    parser.add_argument("--output",required=True)
    args=parser.parse_args()
    catalog=Path(args.catalog);output=Path(args.output);output.mkdir(parents=True,exist_ok=True)
    raw=(catalog/"manifest.json").read_bytes();document=json.loads(raw)
    signature=hashlib.sha256(raw).hexdigest()
    health=json.load(OPENER.open(f"http://127.0.0.1:{args.port}/health",timeout=5))
    assert health["protocol"]==3 and health["voice_catalog"]==signature
    rows=[]
    for voice in document["voices"]:
        audio,timing=generate(args.port,voice,signature)
        (output/(voice["id"]+".wav")).write_bytes(audio)
        row={"id":voice["id"],"audio_sha256":hashlib.sha256(audio).hexdigest(),**timing}
        rows.append(row);print(json.dumps(row),flush=True)
        (output/"verification.json").write_text(json.dumps({"scope":"Local user-provided references; same synthetic English sentence for comparison","text":TEXT,"results":rows},indent=2))
    repeat,_=generate(args.port,document["voices"][0],signature)
    assert hashlib.sha256(repeat).hexdigest()==rows[0]["audio_sha256"]
    assert len({r["audio_sha256"] for r in rows})==len(rows)
    report={"scope":"Local user-provided references; same synthetic English sentence for comparison","text":TEXT,"results":rows,"all_voices_distinct":True,"same_voice_cache_reused":True,"passed":True}
    (output/"verification.json").write_text(json.dumps(report,indent=2))
    print("PASS",len(rows),"real cloned voices, streaming, distinct caches and cached repeat",flush=True)


if __name__=="__main__":main()
