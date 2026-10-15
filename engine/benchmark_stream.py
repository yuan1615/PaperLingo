"""Optional real-model benchmark against a running PaperLingo speech engine."""
import base64
import io
import json
from pathlib import Path
import time
import urllib.request
import uuid
import wave

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
TEXT = (
    "Careful evaluation helps researchers understand how a model behaves when the data distribution changes. "
    "Although the proposed architecture is computationally efficient, it must preserve the acoustic details that listeners use to distinguish similar words and phrases. "
    "We therefore measure both intelligibility and speaker consistency across several challenging conditions, including unfamiliar terminology and long scientific sentences. "
    "These experiments provide a more complete picture of the tradeoffs between generation quality, inference cost, and the time a reader waits before hearing the first sentence."
)

def request(path, payload):
    return OPENER.open(urllib.request.Request("http://127.0.0.1:8765"+path, data=json.dumps(payload).encode(),headers={"Content-Type":"application/json"}), timeout=300)

def streamed(text):
    started=time.monotonic(); result={"characters":len(text),"chunks":[]}
    with request("/speak/stream",{"request_id":str(uuid.uuid4()),"text":text}) as response:
        for line in response:
            event=json.loads(line)
            if event["type"]=="error":
                raise RuntimeError(event["error"])
            if event["type"]=="audio":
                elapsed=round(time.monotonic()-started,3)
                with wave.open(io.BytesIO(base64.b64decode(event["audio"]))) as audio:
                    assert audio.getframerate()==24000 and audio.getnframes()>0
                    item={"index":event["index"],"received_s":elapsed,"audio_s":round(audio.getnframes()/24000,3)}
                    result["chunks"].append(item)
                    print(json.dumps(item),flush=True)
    result["first_audio_s"]=result["chunks"][0]["received_s"]
    result["total_s"]=round(time.monotonic()-started,3)
    assert len(result["chunks"])>1 and result["first_audio_s"]<result["total_s"]
    playhead=result["first_audio_s"]
    gaps=[]
    for chunk in result["chunks"]:
        gaps.append(max(0,chunk["received_s"]-playhead))
        playhead=max(playhead,chunk["received_s"])+chunk["audio_s"]
    result["estimated_buffer_gaps_s"]=[round(gap,3) for gap in gaps]
    return result

if __name__=="__main__":
    results={"cold_stream":streamed(TEXT)}
    warm_text=TEXT.replace("Careful evaluation helps researchers understand", "Detailed analysis allows scientists to understand")
    results["warm_stream"]=streamed(warm_text)
    start=time.monotonic()
    with request("/speak",{"text":warm_text}) as response:
        audio=response.read()
        assert audio.startswith(b"RIFF")
    results["warm_whole_text_wait_s"]=round(time.monotonic()-start,3)
    out=Path(__file__).resolve().parents[1]/".runtime/logs/stream-benchmark.json"
    out.write_text(json.dumps(results,indent=2))
    print(json.dumps(results,indent=2),flush=True)
