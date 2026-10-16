"""Install executable bytes atomically, avoiding stale macOS code-signing caches.

SOURCE and DESTINATION may be the same path after signing. The signed bytes are
preserved exactly; replacement uses a newly written inode, never an APFS clone.
"""
import argparse
import hashlib
import os
from pathlib import Path
import stat
import tempfile


def replace(source: Path, destination: Path):
    mode = stat.S_IMODE(source.stat().st_mode)
    descriptor, name = tempfile.mkstemp(prefix=".PaperLingo-", dir=destination.parent)
    temporary = Path(name)
    digest = hashlib.sha256()
    try:
        with os.fdopen(descriptor, "wb") as output, source.open("rb") as original:
            while block := original.read(1024 * 1024):
                output.write(block)
                digest.update(block)
            output.flush()
            os.fsync(output.fileno())
        if hashlib.sha256(temporary.read_bytes()).digest() != digest.digest():
            raise RuntimeError("Executable copy verification failed")
        os.chmod(temporary, mode)
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            temporary.unlink()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    replace(args.source, args.destination)
