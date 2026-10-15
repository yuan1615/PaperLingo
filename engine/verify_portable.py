"""Verify the embedded runtime after relocation; --smoke runs both local models.

Run with PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 and the Python inside
PaperLingo.app, never the developer's interpreter.
No downloads or services outside loopback are used.
"""
import sys
sys.dont_write_bytecode = True

import argparse
import array
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request
import uuid
import wave


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0))
        return sock.getsockname()[1]


def verify(app, work, smoke=False):
    resources=app/'Contents/Resources'
    runtime=resources/'Runtime'
    report={'app':str(app),'passed':False,'checks':{}}
    checks=report['checks']
    processes=[]; handles=[]
    work.mkdir(parents=True,exist_ok=True)
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def request(port,path,body=None):
        data=json.dumps(body).encode() if body is not None else None
        return opener.open(urllib.request.Request(f'http://127.0.0.1:{port}{path}',data=data,headers={'Content-Type':'application/json'}),timeout=300)
    try:
        assert Path(sys.prefix).resolve()==(runtime/'python').resolve(),'Use the embedded Python to run this check'
        assert all('.runtime' not in Path(p).parts or Path(p).resolve().is_relative_to(runtime.resolve())
                   for p in sys.path if p),'Developer Python path leaked'
        assert json.loads((resources/'runtime.json').read_text())['runtime']=='bundled'
        manifest=json.loads((resources/'distribution.json').read_text())
        for name,info in manifest['files'].items():
            file=runtime/name
            assert file.stat().st_size==info['size'],f'Truncated model file: {name}'
            with file.open('rb') as stream:
                assert hashlib.file_digest(stream,'sha256').hexdigest()==info['sha256'],f'Model checksum mismatch: {name}'
        checks['verified_weight_files']=len(manifest['files'])
        import torch
        import torchaudio
        import soundfile
        from omnivoice import OmniVoice
        embedded=(runtime/'python').resolve()
        for module in (torch,torchaudio,soundfile,sys.modules['omnivoice']):
            assert Path(module.__file__).resolve().is_relative_to(embedded),f'External dependency imported: {module.__name__}'
        checks['python']=sys.version.split()[0]
        checks['torch']=torch.__version__
        checks['mps']=torch.backends.mps.is_available()
        assert checks['mps'],'MPS unavailable on this Mac'
        assert torch.ones(1,device='mps').cpu().item()==1
        assert (runtime/'models/OmniVoice/audio_tokenizer/model.safetensors').is_file()
        checks['embedded_imports']=True
        if smoke:
            models=work/'ollama-models'
            (models/'blobs').mkdir(parents=True,exist_ok=True)
            for file in (runtime/'ollama-models/blobs').iterdir():
                target=models/'blobs'/file.name
                if target.is_symlink(): target.unlink()
                if not target.exists():target.symlink_to(file)
            shutil.copytree(runtime/'ollama-models/manifests',models/'manifests',dirs_exist_ok=True)
            translate_port=free_port();voice_port=free_port()
            while voice_port==translate_port:voice_port=free_port()
            env=os.environ.copy()
            env.update({'OLLAMA_HOST':f'127.0.0.1:{translate_port}','OLLAMA_MODELS':str(models),
                        'OLLAMA_NO_CLOUD':'1','OLLAMA_CONTEXT_LENGTH':'4096','HF_HOME':str(work/'huggingface'),
                        'HF_HUB_OFFLINE':'1','TRANSFORMERS_OFFLINE':'1','HF_HUB_DISABLE_TELEMETRY':'1',
                        'PYTORCH_ENABLE_MPS_FALLBACK':'1','PYTHONDONTWRITEBYTECODE':'1',
                        'PYTHONNOUSERSITE':'1','NO_PROXY':'127.0.0.1,localhost','NUMBA_CACHE_DIR':str(work/'numba-cache')})
            commands=[([str(runtime/'bin/ollama'),'serve'],'ollama'),
                      ([str(runtime/'venv/bin/python'),str(resources/'engine/server.py'),'--port',str(voice_port),
                        '--model',str(runtime/'models/OmniVoice'),'--cache',str(work/'audio-cache')],'voice')]
            for command,name in commands:
                handle=(work/f'{name}.log').open('wb');handles.append(handle)
                processes.append(subprocess.Popen(command,env=env,stdout=handle,stderr=handle))
            for port,path in [(translate_port,'/api/tags'),(voice_port,'/health')]:
                for attempt in range(80):
                    if any(p.poll() is not None for p in processes):raise RuntimeError('A local engine exited; inspect logs')
                    try:
                        with request(port,path) as response:body=json.load(response)
                        break
                    except (OSError,ValueError):time.sleep(0.25)
                else:raise RuntimeError('Local engine did not become ready')
            with request(translate_port,'/api/tags') as response:tags=json.load(response)
            assert any(m['name']=='translategemma:4b' for m in tags['models'])
            prompt='You are a professional English (en) to Chinese (zh-Hans) translator. Produce only the Chinese translation of: A robust model should generalize beyond its training data.'
            started=time.monotonic()
            with request(translate_port,'/api/chat',{'model':'translategemma:4b','stream':False,'messages':[{'role':'user','content':prompt}],
                          'options':{'temperature':0.1,'num_ctx':4096,'num_predict':256},'keep_alive':'0s'}) as response:
                result=json.load(response)
            translation=result['message']['content'].strip()
            assert re.search(r'[\u4e00-\u9fff]',translation) and result.get('done_reason')!='length'
            checks['translation']={'text':translation,'seconds':round(time.monotonic()-started,3)}
            text='Reading a scientific paper can become a daily language lesson. Each unfamiliar expression is easier to remember when we hear it in context.'
            started=time.monotonic();clips=[];done=False
            with request(voice_port,'/speak/stream',{'request_id':str(uuid.uuid4()),'text':text,'voice':'american'}) as response:
                for line in response:
                    event=json.loads(line)
                    if event['type']=='error':raise RuntimeError(event['error'])
                    if event['type']=='audio':
                        import base64
                        data=base64.b64decode(event['audio'])
                        with wave.open(io.BytesIO(data)) as wav:
                            assert wav.getframerate()==24000 and wav.getnframes()>2400 and wav.getsampwidth()==2
                            samples=array.array('h',wav.readframes(wav.getnframes()))
                            assert max(abs(v) for v in samples)>100
                            duration=wav.getnframes()/24000
                        clips.append({'index':event['index'],'received_s':round(time.monotonic()-started,3),'duration_s':round(duration,3)})
                    if event['type']=='done':done=True
            assert done and len(clips)>=2 and clips[0]['received_s']<clips[-1]['received_s']
            checks['progressive_audio']=clips
        report['passed']=True
    except Exception as error:
        report['error']=str(error)
    finally:
        for process in processes:
            if process.poll() is None:process.terminate()
        for process in processes:
            try:process.wait(timeout=10)
            except subprocess.TimeoutExpired:process.kill();process.wait()
        for handle in handles:handle.close()
    (work/'verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps(report,ensure_ascii=False,indent=2),flush=True)
    return report['passed']

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--app',type=Path,default=Path(__file__).resolve().parents[3])
    parser.add_argument('--work',type=Path,default=Path(tempfile.mkdtemp(prefix='paperlingo-offline-check-')))
    parser.add_argument('--smoke',action='store_true')
    args=parser.parse_args()
    sys.exit(0 if verify(args.app.resolve(),args.work.resolve(),args.smoke) else 1)
