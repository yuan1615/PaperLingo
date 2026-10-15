"""Install v0.2 research models into this project using a dedicated Ollama port."""
import json
import fcntl
from collections import Counter
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / ".runtime"
MODELS = ("qwen3.6:27b-q4_K_M", "qwen3-embedding:0.6b")
PORT = 11435
LOCAL = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def validate_ranges(parts, size):
    cursor = 0
    for index, part in enumerate(parts):
        if (part['N'] != index or part['Offset'] != cursor or part['Size'] <= 0 or
                not 0 <= part['Completed'] <= part['Size']):
            raise RuntimeError('下载范围不连续，请保留日志并重新检查断点。')
        cursor += part['Size']
    if cursor != size:
        raise RuntimeError('下载范围与模型尺寸不一致，未修改断点。')


def write_native_ranges(blob, parts):
    for path in blob.parent.glob(blob.name + '-partial-*'):
        path.unlink()
    for part in parts:
        target = Path(str(blob) + f"-partial-{part['N']}")
        temporary = Path(str(blob) + f".range-{part['N']}.tmp")
        temporary.write_text(json.dumps(part))
        temporary.replace(target)


def repair_resume_metadata(blob, size):
    """Recover interrupted Ollama 0.40.x part JSON; final blob SHA still applies.

    Ollama truncates part metadata before rewriting it. A terminated download
    can leave empty files that make every subsequent pull fail with EOF.
    """
    partial = Path(str(blob) + "-partial")
    if not partial.exists() or partial.stat().st_size != size:
        return 0
    journal = Path(str(blob) + '.resume-plan.json')
    if journal.exists():
        plan = json.loads(journal.read_text())
        if plan['size'] != size:
            raise RuntimeError('待恢复的下载计划与模型尺寸不一致。')
        validate_ranges(plan['parts'], size)
        write_native_ranges(blob, plan['parts'])
        journal.unlink()
        return len(plan['parts'])
    parts = list(blob.parent.glob(blob.name + "-partial-*"))
    if not parts:
        return 0
    width = max(100_000_000, min(1_000_000_000, size // 16))
    # A resumed download may have been compacted into smaller native ranges.
    candidates = []
    for part in parts:
        try:
            saved = json.loads(part.read_text())
            number, offset = saved['N'], saved['Offset']
            if number > 0 and offset % number == 0 and 100_000_000 <= offset // number <= 1_000_000_000:
                candidates.append(offset // number)
        except (OSError, ValueError, KeyError, TypeError):
            pass
    if candidates:
        width = Counter(candidates).most_common(1)[0][0]
    repaired = 0
    with partial.open("rb") as data:
        for index, offset in enumerate(range(0, size, width)):
            part = Path(str(blob) + f"-partial-{index}")
            length = min(width, size - offset)
            try:
                saved = json.loads(part.read_text())
                if saved["N"] == index and saved["Offset"] == offset and saved["Size"] == length and 0 <= saved["Completed"] <= length:
                    continue
            except (OSError, ValueError, KeyError, TypeError):
                pass
            completed = 0
            try:
                first = os.lseek(data.fileno(), offset, os.SEEK_DATA)
                hole = os.lseek(data.fileno(), offset, os.SEEK_HOLE)
                if first == offset:
                    # Discard a conservative 1 MiB tail, including allocation
                    # rounding. The complete model is SHA-256 verified by Ollama.
                    completed = max(0, min(length, (hole - offset) // 1_048_576 * 1_048_576 - 1_048_576))
            except (OSError, AttributeError):
                pass
            temporary = Path(str(part) + ".repair")
            temporary.write_text(json.dumps({"N": index, "Offset": offset, "Size": length, "Completed": completed}))
            temporary.replace(part)
            repaired += 1
    return repaired


def compact_resume_metadata(blob, size):
    """Keep native SHA verification, but avoid a few 1 GB ranges trailing behind.

    Called only before this installer's Ollama starts. No model bytes are copied
    or changed; the sparse file's safe written prefixes are retained.
    """
    partial = Path(str(blob) + '-partial')
    paths = list(blob.parent.glob(blob.name + '-partial-*'))
    if not partial.exists() or partial.stat().st_size != size or not paths:
        return 0
    old = sorted((json.loads(p.read_text()) for p in paths), key=lambda p: p['Offset'])
    validate_ranges(old, size)
    if max(part['Size'] for part in old) <= 100_000_000:
        return 0
    with partial.open('rb') as data:
        for part in old:
            try:
                first = os.lseek(data.fileno(), part['Offset'], os.SEEK_DATA)
                hole = os.lseek(data.fileno(), part['Offset'], os.SEEK_HOLE)
                if first == part['Offset']:
                    safe = max(0, min(part['Size'], (hole-part['Offset'])//1_048_576*1_048_576-1_048_576))
                    part['Completed'] = max(part['Completed'], safe)
            except (OSError, AttributeError):
                pass
    new = []
    for index, offset in enumerate(range(0, size, 100_000_000)):
        length = min(100_000_000, size-offset)
        source = next(p for p in old if p['Offset'] <= offset < p['Offset']+p['Size'])
        # A new range crossing an old range boundary must be redownloaded.
        completed = max(0, min(length, source['Offset']+source['Completed']-offset))
        if offset+length > source['Offset']+source['Size']:
            completed = 0
        new.append({'N':index,'Offset':offset,'Size':length,'Completed':completed})
    backup = RUNTIME / 'logs' / f'resume-metadata-{time.time_ns()}.json'
    backup.parent.mkdir(parents=True, exist_ok=True)
    backup.write_text(json.dumps(old))
    validate_ranges(new, size)
    # An atomic plan survives interruption between removing old metadata and
    # writing the new ranges. The next run finishes it before Ollama starts.
    journal = Path(str(blob) + '.resume-plan.json')
    temporary = Path(str(blob) + '.resume-plan.tmp')
    temporary.write_text(json.dumps({'size':size,'parts':new}))
    temporary.replace(journal)
    write_native_ranges(blob, new)
    journal.unlink()
    return len(new)


def local(path, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    return LOCAL.open(urllib.request.Request(
        f"http://127.0.0.1:{PORT}{path}", data=data,
        headers={"Content-Type": "application/json"}), timeout=timeout)


def pull_model(model, logs):
    for attempt in range(6):
        try:
            last = 0
            with local("/api/pull", {"model": model, "stream": True}, timeout=180) as response:
                complete = False
                for line in response:
                    event = json.loads(line)
                    if "error" in event:
                        raise RuntimeError(event["error"])
                    complete = event.get("status") == "success"
                    if time.monotonic() - last > 5 or complete:
                        last = time.monotonic()
                        total = event.get("total", 0)
                        completed = event.get("completed", 0)
                        print(f"{model}: {event.get('status', '')} {completed/total:.1%}" if total else f"{model}: {event.get('status', '')}", flush=True)
                        (logs / "research-progress.json").write_text(json.dumps({"model": model, **event}))
                if not complete:
                    raise RuntimeError("下载流提前关闭")
            return
        except (OSError, RuntimeError) as error:
            if attempt == 5:
                raise
            print(f"连接中断：{error}。保留断点，稍后重试（{attempt+1}/6）。", flush=True)
            time.sleep(min(5 * (attempt + 1), 25))


def install():
    binary = RUNTIME / "bin/ollama"
    if not binary.is_file():
        raise SystemExit("请先运行 scripts/setup-local.sh 安装基础运行环境。")
    try:
        with local("/api/version", timeout=2):
            raise SystemExit(f"{PORT} 端口已被占用；请结束之前的研究模型安装后重试。")
    except urllib.error.URLError:
        pass
    logs = RUNTIME / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    manifests = []
    needed = 0
    for model in MODELS:
        name, tag = model.split(":", 1)
        url = f"https://registry.ollama.ai/v2/library/{name}/manifests/{tag}"
        with urllib.request.urlopen(url, timeout=60) as response:
            manifest = json.load(response)
        manifests.append(manifest)
        for layer in manifest["layers"]:
            blob = RUNTIME / "ollama-models/blobs" / layer["digest"].replace(":", "-")
            repaired = repair_resume_metadata(blob, layer["size"])
            if repaired:
                print(f"已修复 {repaired} 项中断的下载元数据，保留安全的已下载范围。", flush=True)
            compacted = compact_resume_metadata(blob, layer['size'])
            if compacted:
                print(f'已将大块断点细分为 {compacted} 个原生下载范围；最终仍校验完整 SHA-256。', flush=True)
            if blob.exists() and blob.stat().st_size == layer["size"]:
                continue
            partial = Path(str(blob) + "-partial")
            allocated = partial.stat().st_blocks * 512 if partial.exists() else 0
            needed += max(0, layer["size"] - allocated)
    available = shutil.disk_usage(RUNTIME).free
    print(f"预计新增下载 {needed/1e9:.2f} GB；当前剩余 {available/1e9:.2f} GB。", flush=True)
    if available < needed + 2_000_000_000:
        raise SystemExit("剩余空间不足：请为模型下载另留至少 2 GB 余量，释放空间后重试。")
    env = os.environ.copy()
    env.update({"OLLAMA_MODELS": str(RUNTIME / "ollama-models"), "OLLAMA_HOST": f"127.0.0.1:{PORT}",
                "OLLAMA_NO_CLOUD": "1", "OLLAMA_NUM_PARALLEL": "1", "OLLAMA_MAX_LOADED_MODELS": "1"})
    with (logs / "research-installer-ollama.log").open("ab") as log:
        process = subprocess.Popen([str(binary), "serve"], env=env, stdout=log, stderr=log)
        try:
            for _ in range(60):
                if process.poll() is not None:
                    raise RuntimeError("安装服务未启动，请查看 research-installer-ollama.log")
                try:
                    with local("/api/version", timeout=2):
                        break
                except OSError:
                    time.sleep(0.3)
            else:
                raise RuntimeError("等待安装服务超时")
            for model in MODELS:
                print(f"开始安装 {model}", flush=True)
                pull_model(model, logs)
            with local("/api/tags") as response:
                installed = json.load(response)["models"]
            selected = [m for m in installed if m["name"] in MODELS]
            if len(selected) != len(MODELS):
                raise RuntimeError("下载未完成，请重新运行安装程序。")
            (RUNTIME / "research-models.ready").write_text(json.dumps(selected, ensure_ascii=False, indent=2))
            print("研究模型安装完成；打开 PaperLingo v0.2，在设置检查连接。", flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    def cancel(*_):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, cancel)
    RUNTIME.mkdir(parents=True, exist_ok=True)
    with (RUNTIME / "research-download.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("另一个研究模型安装正在运行，请等待其完成。")
        install()
