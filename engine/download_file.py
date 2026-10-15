"""Verified resumable HTTP range downloads for large, public model files."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import math
from pathlib import Path
import shutil
import threading
import time
import urllib.request


def download(url, target, size, sha256=None, workers=16, seed=None):
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists() and target.stat().st_size == size:
        if not sha256 or digest(target) == sha256:
            print(f"Already verified: {target.name}", flush=True)
            return
    parts = target.parent / (target.name + ".parts")
    parts.mkdir(exist_ok=True)
    task_root = Path(__file__).resolve().parents[1] / ".runtime" / "logs"
    task_root.mkdir(parents=True, exist_ok=True)
    progress_lock = threading.Lock()
    last_update = [0.0]
    def report(complete=False):
        if target.suffix != ".safetensors":
            return
        with progress_lock:
            if not complete and time.monotonic() - last_update[0] < 3:
                return
            last_update[0] = time.monotonic()
            transferred = size if complete else sum(p.stat().st_size for p in parts.iterdir() if p.is_file())
            progress = {"file": str(target), "ratio": min(1.0, transferred / size), "bytes": transferred, "total": size, "verified": complete}
            temporary_progress = task_root / "model-progress.tmp"
            temporary_progress.write_text(json.dumps(progress))
            temporary_progress.replace(task_root / "model-progress.json")
    chunk = 16 * 1024 * 1024
    count = math.ceil(size / chunk)
    if seed and Path(seed).exists():
        with Path(seed).open("rb") as source:
            for index in range(count):
                data = source.read(chunk)
                if not data:
                    break
                part = parts / f"{index:04d}"
                if not part.exists():
                    part.write_bytes(data)

    def transfer(index):
        start, end = index * chunk, min(size, (index + 1) * chunk) - 1
        part = parts / f"{index:04d}"
        attempt = 0
        while attempt < 6:
            present = part.stat().st_size if part.exists() else 0
            if present == end - start + 1:
                return present
            if present > end - start + 1:
                part.unlink()
                present = 0
            try:
                offset = start + present
                request_end = min(end, offset + 2 * 1024 * 1024 - 1)
                request = urllib.request.Request(url, headers={"Range": f"bytes={offset}-{request_end}", "User-Agent": "PaperLingo/0.1"})
                with urllib.request.urlopen(request, timeout=45) as response:
                    if response.status != 206 or not response.headers.get("Content-Range", "").startswith(f"bytes {offset}-{request_end}/"):
                        raise RuntimeError("Server did not honor exact HTTP byte range")
                    with part.open("ab") as output:
                        while True:
                            block = response.read(256 * 1024)
                            if not block:
                                break
                            output.write(block)
                            report()
                if part.stat().st_size < request_end - start + 1:
                    raise RuntimeError("Incomplete range")
                attempt = 0
            except Exception:
                if attempt == 5:
                    raise
                time.sleep(min(2 ** attempt, 8))
                attempt += 1
    done = 0
    print(f"Downloading {target.name}: {size / 1e9:.2f} GB, {workers} resumable streams", flush=True)
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [executor.submit(transfer, index) for index in range(count)]
        for future in as_completed(futures):
            done += future.result()
            print(f"{target.name}: {done * 100 / size:.1f}% ({done / 1e6:.0f}/{size / 1e6:.0f} MB)", flush=True)
    temporary = target.with_suffix(target.suffix + ".assembling")
    with temporary.open("wb") as output:
        for index in range(count):
            with (parts / f"{index:04d}").open("rb") as source:
                shutil.copyfileobj(source, output, 1024 * 1024)
    if temporary.stat().st_size != size or (sha256 and digest(temporary) != sha256):
        raise RuntimeError("Download verification failed; chunks retained for inspection")
    temporary.replace(target)
    shutil.rmtree(parts)
    report(complete=True)
    print(f"Verified: {target.name}", flush=True)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("target")
    parser.add_argument("size", type=int)
    parser.add_argument("--sha256")
    parser.add_argument("--seed")
    args = parser.parse_args()
    download(args.url, args.target, args.size, args.sha256, seed=args.seed)
