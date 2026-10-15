"""Install the verified OmniVoice snapshot and its bundled audio tokenizer."""
import fcntl
import json
from pathlib import Path

from download_file import download

REPOSITORY = "k2-fsa/OmniVoice"
REVISION = "c5fdb5ccb189668d56333f77ba2629f4cd7535f4"
REQUIRED_WEIGHTS = ("model.safetensors", "audio_tokenizer/model.safetensors")


def install_models(root):
    # Keep import and all network work inside the entry point. Protocol checks
    # can exercise this installer without installing the inference packages.
    from huggingface_hub import HfApi, snapshot_download

    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    with (root / "model-download.lock").open("w") as download_lock:
        try:
            fcntl.flock(download_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("另一个 OmniVoice 下载进程正在运行，请等待它完成。")

        info = HfApi().model_info(REPOSITORY, revision=REVISION, files_metadata=True)
        if info.sha != REVISION:
            raise RuntimeError("Upstream returned an unexpected OmniVoice revision")
        model = Path(snapshot_download(
            REPOSITORY, revision=REVISION,
            allow_patterns=["*.json", "*.txt", "*.model", "*.jinja", "*.md", "LICENSE*"],
        ))
        for file in info.siblings:
            if file.rfilename.endswith((".safetensors", ".bin")):
                if not file.lfs or not file.lfs.sha256 or not file.size:
                    raise RuntimeError(f"Missing weight verification metadata: {file.rfilename}")
                download(
                    f"https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{file.rfilename}",
                    model / file.rfilename, file.size, file.lfs.sha256,
                )
        for name in REQUIRED_WEIGHTS:
            file = model / name
            if not file.is_file() or not file.stat().st_size:
                raise RuntimeError(f"Incomplete OmniVoice snapshot: {name}. Re-run the installer.")
        (root / "models.ready").write_text(json.dumps({"omnivoice": str(model), "revision": REVISION}))
        print("OmniVoice and audio tokenizer downloaded", flush=True)


if __name__ == "__main__":
    install_models(Path(__file__).resolve().parents[1] / ".runtime")
