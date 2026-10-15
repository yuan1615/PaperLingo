"""Check pinned installation and incomplete-download handling without a network."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ENGINE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("model_install", ENGINE / "download_models.py")
installer = importlib.util.module_from_spec(spec)
with patch.object(sys, "path", [str(ENGINE), *sys.path]):
    spec.loader.exec_module(installer)


class ModelInstallTests(unittest.TestCase):
    def upstream(self, snapshot, names, revision=None):
        api = Mock()
        api.model_info.return_value = SimpleNamespace(
            sha=revision or installer.REVISION,
            siblings=[SimpleNamespace(rfilename=name, size=3, lfs=SimpleNamespace(sha256="a" * 64)) for name in names],
        )
        hub = SimpleNamespace(HfApi=Mock(return_value=api), snapshot_download=Mock(return_value=str(snapshot)))
        return api, hub

    @staticmethod
    def write_weight(url, target, size, sha256):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"abc")

    def test_exact_revision_and_checksums_used_before_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot = root / "snapshot"
            api, hub = self.upstream(snapshot, installer.REQUIRED_WEIGHTS)
            with patch.dict(sys.modules, {"huggingface_hub": hub}), patch.object(installer, "download", side_effect=self.write_weight) as download:
                installer.install_models(root)
            api.model_info.assert_called_once_with(installer.REPOSITORY, revision=installer.REVISION, files_metadata=True)
            self.assertEqual(hub.snapshot_download.call_args.kwargs["revision"], installer.REVISION)
            self.assertEqual(download.call_count, 2)
            for call in download.call_args_list:
                self.assertIn(f"/resolve/{installer.REVISION}/", call.args[0])
                self.assertEqual(call.args[3], "a" * 64)
            self.assertEqual(json.loads((root / "models.ready").read_text()), {"omnivoice": str(snapshot), "revision": installer.REVISION})

    def test_missing_audio_tokenizer_never_marks_snapshot_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, hub = self.upstream(root / "snapshot", ["model.safetensors"])
            with patch.dict(sys.modules, {"huggingface_hub": hub}), patch.object(installer, "download", side_effect=self.write_weight):
                with self.assertRaisesRegex(RuntimeError, "Incomplete OmniVoice snapshot"):
                    installer.install_models(root)
            self.assertFalse((root / "models.ready").exists())

    def test_unexpected_revision_is_rejected_before_download(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _, hub = self.upstream(root / "snapshot", [], revision="unexpected")
            with patch.dict(sys.modules, {"huggingface_hub": hub}), patch.object(installer, "download") as download:
                with self.assertRaisesRegex(RuntimeError, "unexpected OmniVoice revision"):
                    installer.install_models(root)
            hub.snapshot_download.assert_not_called()
            download.assert_not_called()
            self.assertFalse((root / "models.ready").exists())


if __name__ == "__main__":
    unittest.main()
