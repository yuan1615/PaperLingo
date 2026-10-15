import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location("research_install",Path(__file__).resolve().parents[1]/"install_research.py")
installer=importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class ResearchInstallTests(unittest.TestCase):
    def test_empty_resume_metadata_is_repaired_without_allocating_model_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            blob=Path(directory)/"sha256-fixture"
            partial=Path(str(blob)+"-partial")
            with partial.open("wb") as target:
                target.truncate(125_000_000)
            Path(str(blob)+"-partial-0").write_text("")
            self.assertEqual(installer.repair_resume_metadata(blob,125_000_000),2)
            first=json.loads(Path(str(blob)+"-partial-0").read_text())
            last=json.loads(Path(str(blob)+"-partial-1").read_text())
            self.assertEqual(first,{"N":0,"Offset":0,"Size":100_000_000,"Completed":0})
            self.assertEqual(last,{"N":1,"Offset":100_000_000,"Size":25_000_000,"Completed":0})
            self.assertEqual(partial.stat().st_size,125_000_000)
            self.assertEqual(installer.repair_resume_metadata(blob,125_000_000),0)

    def test_wrong_size_or_missing_partial_is_left_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            blob=Path(directory)/"sha256-fixture"
            part=Path(str(blob)+"-partial-0")
            part.write_text("")
            self.assertEqual(installer.repair_resume_metadata(blob,125_000_000),0)
            Path(str(blob)+"-partial").write_bytes(b"short")
            self.assertEqual(installer.repair_resume_metadata(blob,125_000_000),0)
            self.assertEqual(part.read_text(),"")

    def test_interrupted_pull_retries_and_requires_success_event(self):
        with tempfile.TemporaryDirectory() as directory:
            logs=Path(directory)
            responses=[io.BytesIO(b'{"status":"pulling"}\n'),io.BytesIO(b'{"status":"success"}\n')]
            with patch.object(installer,"local",side_effect=responses) as request,patch.object(installer.time,"sleep"):
                installer.pull_model("fixture",logs)
            self.assertEqual(request.call_count,2)
            self.assertEqual(json.loads((logs/"research-progress.json").read_text())["status"],"success")

    def test_compact_ranges_preserve_completed_prefix_and_can_resume_after_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            blob=root/'sha256-fixture'
            partial=Path(str(blob)+'-partial')
            with partial.open('wb') as target:
                target.truncate(2_050_000_000)
            for n,size,completed in [(0,1_000_000_000,1_000_000_000),(1,1_000_000_000,40_000_000),(2,50_000_000,0)]:
                Path(str(blob)+f'-partial-{n}').write_text(json.dumps({'N':n,'Offset':n*1_000_000_000,'Size':size,'Completed':completed}))
            with patch.object(installer,'RUNTIME',root):
                self.assertEqual(installer.compact_resume_metadata(blob,2_050_000_000),21)
            parts=[json.loads(Path(str(blob)+f'-partial-{n}').read_text()) for n in range(21)]
            self.assertEqual(sum(p['Size'] for p in parts),2_050_000_000)
            self.assertEqual(sum(p['Completed'] for p in parts),1_040_000_000)
            self.assertEqual(parts[10]['Completed'],40_000_000)
            Path(str(blob)+'-partial-15').write_text('')
            self.assertEqual(installer.repair_resume_metadata(blob,2_050_000_000),1)
            self.assertEqual(json.loads(Path(str(blob)+'-partial-15').read_text())['Offset'],1_500_000_000)

    def test_overlapping_ranges_are_rejected_without_modifying_files(self):
        with tempfile.TemporaryDirectory() as directory:
            blob=Path(directory)/'sha256-fixture'
            with Path(str(blob)+'-partial').open('wb') as target:
                target.truncate(2_000_000_000)
            path=Path(str(blob)+'-partial-0')
            text=json.dumps({'N':0,'Offset':1,'Size':2_000_000_000,'Completed':0})
            path.write_text(text)
            with self.assertRaises(RuntimeError):installer.compact_resume_metadata(blob,2_000_000_000)
            self.assertEqual(path.read_text(),text)

    def test_interrupted_repartition_is_completed_from_atomic_plan(self):
        with tempfile.TemporaryDirectory() as directory:
            blob=Path(directory)/'sha256-fixture'
            with Path(str(blob)+'-partial').open('wb') as target:target.truncate(125_000_000)
            parts=[{'N':0,'Offset':0,'Size':100_000_000,'Completed':20_000_000},
                   {'N':1,'Offset':100_000_000,'Size':25_000_000,'Completed':0}]
            journal=Path(str(blob)+'.resume-plan.json')
            journal.write_text(json.dumps({'size':125_000_000,'parts':parts}))
            Path(str(blob)+'-partial-0').write_text('incomplete')
            self.assertEqual(installer.repair_resume_metadata(blob,125_000_000),2)
            self.assertFalse(journal.exists())
            self.assertEqual(json.loads(Path(str(blob)+'-partial-0').read_text()),parts[0])


if __name__=="__main__":
    unittest.main()
