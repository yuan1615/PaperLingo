"""Assemble a relocatable, entirely offline arm64 app from installed runtimes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

ROOT=Path(sys.argv[1]).resolve()
APP=Path(sys.argv[2]).resolve()
RESOURCES=APP/'Contents/Resources'
DEST=RESOURCES/'Runtime'
SOURCE=ROOT/'.runtime'
REVISION='c5fdb5ccb189668d56333f77ba2629f4cd7535f4'
IGNORE=shutil.ignore_patterns('__pycache__','*.pyc','.DS_Store')

def copy(source,target,links=True):
    print(f'Packaging {target.relative_to(APP)}',flush=True)
    shutil.copytree(source,target,symlinks=links,ignore=IGNORE,dirs_exist_ok=True)

if DEST.exists():
    raise SystemExit('Runtime already staged. Use a fresh app output directory for a reproducible package.')
ready=json.loads((SOURCE/'models.ready').read_text())
if ready.get('revision') != REVISION:
    raise SystemExit('OmniVoice snapshot differs from the verified v0.1.0 version. Run scripts/setup-local.sh first.')
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
copy(SOURCE/'ollama-models/blobs',DEST/'ollama-models/blobs')
copy(SOURCE/'ollama-models/manifests',DEST/'ollama-models/manifests')
# Dereference HF cache links: the app contains one independent, full snapshot.
copy(SOURCE/f'huggingface/hub/models--k2-fsa--OmniVoice/snapshots/{REVISION}',DEST/'models/OmniVoice',links=False)
(DEST/'models.ready').write_text(json.dumps({'omnivoice':'models/OmniVoice','revision':REVISION}))
(RESOURCES/'runtime.json').write_text(json.dumps({'runtime':'bundled','version':'0.1.0'}))
copy(ROOT/'packaging/third-party',RESOURCES/'ThirdParty')
shutil.copy2(ROOT/'packaging/INSTALL-zh.txt',RESOURCES/'安装说明.txt')
shutil.copy2(ROOT/'engine/verify_portable.py',RESOURCES/'engine/verify_portable.py')
# Reject outward/absolute symlinks and developer-machine paths before signing.
for file in DEST.rglob('*'):
    if file.is_symlink():
        target=os.readlink(file)
        if os.path.isabs(target) or not file.resolve().is_relative_to(DEST):
            raise RuntimeError(f'Nonportable symlink: {file}: {target}')
manifest={'version':'0.1.0','architecture':'arm64','minimum_macos':'14.0','minimum_ram_gb':16,
          'omnivoice_revision':REVISION,'components':{'python':'3.11.17','omnivoice':'0.2.1','torch':'2.8.0','ollama':'0.40.4','translation':'translategemma:4b'},'files':{}}
for file in sorted(DEST.rglob('*')):
    if file.is_file() and not file.is_symlink():
        if file.suffix=='.safetensors' or (file.parent.name=='blobs' and file.name.startswith('sha256-')):
            digest=hashlib.file_digest(file.open('rb'),'sha256').hexdigest()
            manifest['files'][str(file.relative_to(DEST))]={'size':file.stat().st_size,'sha256':digest}
            if file.parent.name=='blobs' and digest != file.name.removeprefix('sha256-'):
                raise RuntimeError(f'Model blob hash mismatch: {file}')
(RESOURCES/'distribution.json').write_text(json.dumps(manifest,indent=2))
print('Portable runtime staged; every model weight SHA-256 recorded.',flush=True)
