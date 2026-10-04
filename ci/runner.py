#!/usr/bin/env python3
"""A stuck test's backend teardown must retain its name and phase."""
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
cache = root / ".zig-cache"
cache.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="runner-probe-", dir=cache) as temporary:
    env = os.environ.copy()
    for key in ("SSH_AUTH_SOCK", "SSH_AGENT_PID", "GPG_AGENT_INFO"):
        env.pop(key, None)
    for key in ("HOME", "XDG_CONFIG_HOME", "TMPDIR"):
        destination = pathlib.Path(temporary) / key.lower()
        destination.mkdir()
        env[key] = str(destination)
    env["ZIG_GLOBAL_CACHE_DIR"] = str(cache / "runner-global")
    env["CONDUIT_TEARDOWN_PROBE"] = "1"
    result = subprocess.run(
        ["zig", "build", "unit", "-Dtest-filter=runner teardown probe",
         "-Dtest-watchdog-ms=200", "--test-timeout", "45s"],
        cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=60,
    )
    expected = ("conduit: watchdog: src/testing/test_support.zig: "
                "testing.test_support.test.runner teardown probe; phase=io_teardown")
    if result.returncode == 0 or expected not in result.stdout:
        raise SystemExit("runner probe did not identify backend teardown:\n" + result.stdout)
print("runner probe: stuck backend teardown names its test and source")
