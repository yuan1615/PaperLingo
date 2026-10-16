"""Assemble a relocatable, entirely offline arm64 app from installed runtimes."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

ROOT=Path(sys.argv[1]).resolve()
APP=Path(sys.argv[2]).resolve()
RESOURCES=APP/'Contents/Resources'
DEST=RESOURCES/'Runtime'
SOURCE=ROOT/'.runtime'
REVISION='c5fdb5ccb189668d56333f77ba2629f4cd7535f4'
IGNORE=shutil.ignore_patterns('__pycache__','*.pyc','.DS_Store')
VERSION=plistlib.loads((APP/'Contents/Info.plist').read_bytes())['CFBundleShortVersionString']
RESEARCH_MODELS=('qwen3.6:27b-q4_K_M','qwen3-embedding:0.6b')

def copy_file(source,target):
    # APFS clones are independent files, not links to the development runtime.
    # Keep a regular-copy fallback for other filesystems; disk preflight always
    # reserves the full logical size, even when cloning is requested.
    if os.environ.get('PAPERLINGO_CLONE_STAGE')=='1' and sys.platform=='darwin' and Path(source).stat().st_size>=8*1024**2:
        result=subprocess.run(['/bin/cp','-c','-p',str(Path(source).resolve()),str(target)],
                              stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        if result.returncode==0:return str(target)
    return shutil.copy2(source,target)

def model_files(name):
    repository,tag=name.rsplit(':',1)
    manifest=SOURCE/'ollama-models/manifests/registry.ollama.ai/library'/repository/tag
    data=json.loads(manifest.read_text())
    blobs=[]
    for layer in [data['config'],*data['layers']]:
        digest=layer['digest']
        if not digest.startswith('sha256:') or len(digest)!=71:
            raise SystemExit(f'Unexpected model digest: {name}')
        blob=SOURCE/'ollama-models/blobs'/digest.replace(':','-')
        if not blob.is_file() or blob.stat().st_size!=layer['size']:
            raise SystemExit(f'Missing or incomplete model: {name}: {blob.name}')
        blobs.append(blob)
    return manifest,blobs

def tree_size(path):
    return sum(p.stat().st_size for p in path.rglob('*') if p.is_file())

def copy(source,target,links=True):
    print(f'Packaging {target.relative_to(APP)}',flush=True)
    shutil.copytree(source,target,symlinks=links,ignore=IGNORE,dirs_exist_ok=True,copy_function=copy_file)

if DEST.exists():
    raise SystemExit('Runtime already staged. Use a fresh app output directory for a reproducible package.')
ready=json.loads((SOURCE/'models.ready').read_text())
if ready.get('revision') != REVISION:
    raise SystemExit('OmniVoice snapshot differs from the verified version. Run scripts/setup-local.sh first.')
# Package only manifests and blobs required by this version. Partial downloads,
# unrelated Ollama models and writable caches must never enter the app bundle.
required_models=['translategemma:4b',*RESEARCH_MODELS]
research_ready=json.loads((SOURCE/'research-models.ready').read_text())
reranker_ready=json.loads((SOURCE/'reranker.ready').read_text())
reranker=SOURCE/reranker_ready['model']
if not (reranker/'model.safetensors').is_file():
    raise SystemExit('Reranker is incomplete. Run engine/install_reranker.py first.')
with (reranker/'model.safetensors').open('rb') as stream:
    if hashlib.file_digest(stream,'sha256').hexdigest()!=reranker_ready['sha256']:
        raise SystemExit('Reranker checksum mismatch; refusing to package changed weights.')
if not all(name in {m.get('name') for m in research_ready} for name in RESEARCH_MODELS):
    raise SystemExit('Research models are not ready. Run engine/install_research.py first.')
manifests=[]
blobs=set()
for name in required_models:
    manifest,files=model_files(name)
    manifests.append(manifest)
    blobs.update(files)
snapshot=SOURCE/f'huggingface/hub/models--k2-fsa--OmniVoice/snapshots/{REVISION}'
required_space=(tree_size(SOURCE/'python/cpython-3.11.17-macos-aarch64-none')+
                tree_size(SOURCE/'venv/lib/python3.11/site-packages')+
                tree_size(SOURCE/'ollama')+tree_size(snapshot)+
                sum(p.stat().st_size for p in blobs)+tree_size(reranker)+2*1024**3)
if shutil.disk_usage(APP).free < required_space:
    raise SystemExit(f'Offline staging needs at least {required_space/1024**3:.1f} GiB free; no runtime copied.')
DEST.mkdir()
copy(SOURCE/'python/cpython-3.11.17-macos-aarch64-none',DEST/'python')
# Flatten the venv into embedded Python: no pyvenv.cfg, absolute shebangs, uv,
# Homebrew, pip installation, or target-machine Python is required.
packages=DEST/'python/lib/python3.11/site-packages'
shutil.rmtree(packages)
copy(SOURCE/'venv/lib/python3.11/site-packages',packages)
for file in (DEST/'python/bin').iterdir():
    if file.name != 'python3.11':
        file.unlink()
for name in ('python','python3'):
    (DEST/'python/bin'/name).symlink_to('python3.11')
(DEST/'venv/bin').mkdir(parents=True)
(DEST/'venv/bin/python').symlink_to('../../python/bin/python3.11')
(DEST/'venv/bin/python3').symlink_to('python')
copy(SOURCE/'ollama',DEST/'ollama')
(DEST/'bin').mkdir()
(DEST/'bin/ollama').symlink_to('../ollama/ollama')
for file in [*manifests,*sorted(blobs)]:
    target=DEST/'ollama-models'/file.relative_to(SOURCE/'ollama-models')
    target.parent.mkdir(parents=True,exist_ok=True)
    copy_file(file,target)
# Dereference HF cache links: the app contains one independent, full snapshot.
copy(snapshot,DEST/'models/OmniVoice',links=False)
copy(reranker,DEST/'models/Qwen3-Reranker-0.6B',links=False)
(DEST/'reranker.ready').write_text(json.dumps(reranker_ready))
(DEST/'models.ready').write_text(json.dumps({'omnivoice':'models/OmniVoice','revision':REVISION}))
(DEST/'research-models.ready').write_text(json.dumps(research_ready))
(RESOURCES/'runtime.json').write_text(json.dumps({'runtime':'bundled','version':VERSION}))
copy(ROOT/'packaging/third-party',RESOURCES/'ThirdParty')
shutil.copy2(ROOT/'packaging/INSTALL-zh.txt',RESOURCES/'安装说明.txt')
shutil.copy2(ROOT/'engine/verify_portable.py',RESOURCES/'engine/verify_portable.py')
shutil.copy2(ROOT/'engine/rerank.py',RESOURCES/'engine/rerank.py')
# Reject outward/absolute symlinks and developer-machine paths before signing.
for file in DEST.rglob('*'):
    if file.is_symlink():
        target=os.readlink(file)
        if os.path.isabs(target) or not file.resolve().is_relative_to(DEST):
            raise RuntimeError(f'Nonportable symlink: {file}: {target}')
manifest={'version':VERSION,'architecture':'arm64','minimum_macos':'14.0','minimum_ram_gb':32,
          'omnivoice_revision':REVISION,'components':{'python':'3.11.17','omnivoice':'0.2.1','torch':'2.8.0','ollama':'0.40.4','translation':'translategemma:4b','research':RESEARCH_MODELS[0],'embedding':RESEARCH_MODELS[1],'reranker':'Qwen3-Reranker-0.6B@'+reranker_ready['revision']},'files':{}}
for file in sorted(DEST.rglob('*')):
    if file.is_file() and not file.is_symlink():
        if file.suffix=='.safetensors' or (file.parent.name=='blobs' and file.name.startswith('sha256-')):
            digest=hashlib.file_digest(file.open('rb'),'sha256').hexdigest()
            manifest['files'][str(file.relative_to(DEST))]={'size':file.stat().st_size,'sha256':digest}
            if file.parent.name=='blobs' and digest != file.name.removeprefix('sha256-'):
                raise RuntimeError(f'Model blob hash mismatch: {file}')
(RESOURCES/'distribution.json').write_text(json.dumps(manifest,indent=2))
print('Portable runtime staged; every model weight SHA-256 recorded.',flush=True)
