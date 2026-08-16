#!/usr/bin/env python3
"""DEMO-RECOVERY-01의 합성 marker를 처음 한 번만 원자적으로 기록한다."""

from pathlib import Path
import os


path = Path(os.environ["DEMO_RECOVERY_FILE"])
value = b'{"marker":"DEMO-RECOVERY-01-NORMAL","record":"synthetic-only"}\n'
path.parent.mkdir(mode=0o770, parents=True, exist_ok=True)
if not path.exists():
    temporary = path.with_suffix(".tmp")
    with temporary.open("xb") as handle:
        handle.write(value)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
