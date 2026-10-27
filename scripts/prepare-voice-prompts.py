"""Prepare private, user-supplied voice references; never uploads recordings."""
import argparse
import hashlib
import json
import math
from pathlib import Path

import numpy as np
from scipy.signal import resample_poly
import soundfile as sf


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source",required=True)
    parser.add_argument("--output",required=True)
    parser.add_argument("--asr",required=True,help="Local Whisper model directory; used only during preparation")
    args=parser.parse_args()
    import torch
    from transformers import pipeline
    torch.set_num_threads(4)
    asr=pipeline("automatic-speech-recognition",model=args.asr,device="cpu",dtype=torch.float32)
    source,output=Path(args.source),Path(args.output)
    output.mkdir(parents=True,exist_ok=True)
    entries=[]
    for number in range(1,11):
        identifier=f"{number:03}"
        original=source/(identifier+".wav")
        audio,rate=sf.read(original,dtype="float32",always_2d=True)
        mono=audio.mean(axis=1)
        if not 1<=len(mono)/rate<=20 or not np.isfinite(mono).all() or float(np.max(np.abs(mono)))<0.001:
            raise ValueError("Invalid or empty reference: "+identifier)
        transcript=asr({"array":mono.copy(),"sampling_rate":rate})["text"].strip()
        if not transcript:
            raise ValueError("No transcript: "+identifier)
        divisor=math.gcd(rate,24000)
        prepared=resample_poly(mono,24000//divisor,rate//divisor) if rate!=24000 else mono
        target=output/(identifier+".wav")
        sf.write(target,prepared,24000,subtype="PCM_16")
        entry={"id":identifier,"label":"声音 "+identifier,"file":target.name,"text":transcript,
               "sha256":hashlib.sha256(target.read_bytes()).hexdigest(),"seconds":round(len(prepared)/24000,3),
               "source_sha256":hashlib.sha256(original.read_bytes()).hexdigest(),
               "transcript_source":"local-whisper-base.en","transcript_verified":False}
        entries.append(entry)
        (output/"transcription-progress.json").write_text(json.dumps(entries,ensure_ascii=False,indent=2))
        print(identifier,transcript,flush=True)
    document={"version":1,"source":"user-provided recordings","voices":entries}
    temporary=output/"manifest.json.tmp"
    temporary.write_text(json.dumps(document,ensure_ascii=False,indent=2)+"\n")
    temporary.replace(output/"manifest.json")
    print("Prepared",len(entries),"private voice references; no ASR model is required at runtime.",flush=True)


if __name__=="__main__":main()
