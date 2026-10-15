"""Read-only loopback diagnostics; --smoke also runs actual local translation and speech."""
import argparse
import array
import io
import json
from pathlib import Path
import re
import sys
import time
import urllib.request
import wave

ROOT=Path(__file__).resolve().parents[1]
OPENER=urllib.request.build_opener(urllib.request.ProxyHandler({}))


def request(port,path,body=None):
    payload=json.dumps(body).encode() if body is not None else None
    req=urllib.request.Request(f"http://127.0.0.1:{port}{path}",data=payload,headers={"Content-Type":"application/json"})
    with OPENER.open(req,timeout=300) as response:
        return response.read()


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--smoke",action="store_true")
    args=parser.parse_args()
    result={"time":time.strftime("%Y-%m-%dT%H:%M:%S%z"),"checks":{}}
    checks=result["checks"]
    try:
        checks["ollama"]=json.loads(request(11434,"/api/version"))
        models=json.loads(request(11434,"/api/tags"))["models"]
        checks["translation_model"]=next(m for m in models if m["name"]=="translategemma:4b")
        checks["speech"]=json.loads(request(8765,"/health"))
        assert checks["speech"]["service"]=="paperlingo-omnivoice" and checks["speech"]["installed"]
        if args.smoke:
            translations=[]
            for text in ["spurious correlations","A robust representation should generalize beyond the training distribution."]:
                prompt=("You are a professional English (en) to Chinese (zh-Hans) translator. "
                        "Your goal is to accurately convey the meaning and nuances of the original English text "
                        "while adhering to Chinese grammar, vocabulary, and cultural sensitivities.\n"
                        "Produce only the Chinese translation, without any additional explanations or commentary. "
                        "Please translate the following English text into Chinese:\n\n\n"+text)
                start=time.monotonic()
                output=json.loads(request(11434,"/api/chat",{"model":"translategemma:4b","stream":False,
                    "messages":[{"role":"user","content":prompt}],"options":{"temperature":0.1,"num_ctx":4096,"num_predict":2048},"keep_alive":"2m"}))
                translation=output["message"]["content"].strip()
                assert re.search(r"[\u4e00-\u9fff]",translation),"Translation must contain Chinese text"
                assert output.get("done_reason")!="length","Truncated translation"
                translations.append({"text":text,"translation":translation,"seconds":round(time.monotonic()-start,2)})
            checks["translations"]=translations
            speech=[]
            for index,text in enumerate(["intelligibility","A little reading, a little growth."]):
                start=time.monotonic()
                audio=request(8765,"/speak",{"text":text,"speed":1.0,"voice":"american"})
                with wave.open(io.BytesIO(audio)) as wav:
                    rate=wav.getframerate();frames=wav.getnframes();width=wav.getsampwidth()
                    assert rate==24000 and frames>2400 and width==2,"Unexpected PCM WAV output"
                    samples=array.array("h",wav.readframes(frames))
                    assert max(abs(v) for v in samples)>100 and max(samples)-min(samples)>100,"Speech output appears silent or constant"
                output=ROOT/".runtime/logs"/f"smoke-speech-{index}.wav"
                output.parent.mkdir(parents=True,exist_ok=True);output.write_bytes(audio)
                speech.append({"text":text,"rate":rate,"duration":round(frames/rate,2),"seconds":round(time.monotonic()-start,2),"file":str(output)})
            checks["audio"]=speech
        result["passed"]=True
    except Exception as error:
        result["passed"]=False;result["error"]=str(error)
    report=ROOT/".runtime/logs/smoke-test.json"
    report.parent.mkdir(parents=True,exist_ok=True)
    report.write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(json.dumps(result,ensure_ascii=False,indent=2),flush=True)
    if not result["passed"]:sys.exit(1)


if __name__=="__main__":main()
