"""Install the pinned official Qwen reranker without changing Python packages."""
import fcntl
import hashlib
import json
from pathlib import Path
import shutil
import urllib.request

from download_file import download

REPOSITORY = "Qwen/Qwen3-Reranker-0.6B"
REVISION = "e61197ed45024b0ed8a2d74b80b4d909f1255473"
WEIGHT_SHA = "27cd75a405b9c1b46b59abfd88aaa209e6fed2a1972cde9b70e7659537c5e65b"
FILES = {"config.json": 727, "tokenizer_config.json": 9706, "tokenizer.json": 11422654,
         "merges.txt": 1671853, "vocab.json": 2776833, "model.safetensors": 1191588280}


def install(root):
    root = Path(root)
    target = root / "models/Qwen3-Reranker-0.6B"
    target.mkdir(parents=True, exist_ok=True)
    with (root / "reranker-install.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        missing = sum(size for name, size in FILES.items() if not (target/name).is_file())
        if shutil.disk_usage(target).free < missing + 2*1024**3:
            raise RuntimeError("重排模型安装需要约 1.2 GB 和额外 2 GB 可用空间")
        for name, size in FILES.items():
            download(f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{name}",
                     target/name, size, WEIGHT_SHA if name == "model.safetensors" else None, workers=8)
        ready = {"repository": REPOSITORY, "revision": REVISION,
                 "model": "models/Qwen3-Reranker-0.6B", "sha256": WEIGHT_SHA}
        temporary = root / "reranker.ready.tmp"
        temporary.write_text(json.dumps(ready))
        temporary.replace(root / "reranker.ready")
        print("Qwen reranker verified and ready", flush=True)


if __name__ == "__main__":
    install(Path(__file__).resolve().parents[1]/".runtime")
