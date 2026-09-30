#!/usr/bin/env python3
from pathlib import Path
import sys, os

out = Path(sys.argv[1] if len(sys.argv) > 1 else "build/data")
out.mkdir(parents=True, exist_ok=True)
(out / "arg-1k.txt").write_bytes(b"x" * 1024)
line = b"x" * 1023 + b"\n"
(out / "pty-1k.bin").write_bytes(line)
if os.environ.get("SMOKE") == "1":
    raise SystemExit(0)
with (out / "pty-64m.bin").open("wb") as f:
    for _ in range((64 * 1024 * 1024) // len(line)):
        f.write(line)
with (out / "pty-smoke-4m.bin").open("wb") as f:
    for _ in range((4 * 1024 * 1024) // len(line)):
        f.write(line)
