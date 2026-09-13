#!/usr/bin/env python3
"""Crash and reopen independent processes using isolated files and mock CloudKit only."""
import pathlib
import subprocess
import sys
import tempfile

probe = pathlib.Path(sys.argv[1]).resolve()
for scenario in ("update-asset", "deletion", "retirement", "account"):
    with tempfile.TemporaryDirectory(prefix="SQLiteDataIncomingCrash-") as directory:
        result = subprocess.run([str(probe), "crash", scenario, directory], capture_output=True,
                                text=True, timeout=40)
        if result.returncode != 73:
            sys.exit(f"{scenario}: expected exit 73, got {result.returncode}\n{result.stdout}\n{result.stderr}")
        subprocess.run([str(probe), "verify", scenario, directory], check=True, timeout=40)
print("4 incoming/account subprocess scenarios passed")
