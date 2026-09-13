#!/usr/bin/env python3
"""Exercise real process-loss windows. Uses only isolated SQLite files and mock CloudKit."""
import pathlib
import subprocess
import sys
import tempfile

probe = pathlib.Path(sys.argv[1]).resolve()
operations = [f"{state}-{change}" for state in ("running", "stopped", "rollback")
              for change in ("insert", "update", "delete")]
for operation in operations + ["accepted-update"]:
    with tempfile.TemporaryDirectory(prefix="SQLiteDataOutgoingCrash-") as directory:
        phase = "accepted" if operation == "accepted-update" else "crash"
        result = subprocess.run([str(probe), phase, operation, directory], capture_output=True, text=True, timeout=40)
        if result.returncode != 73:
            sys.exit(f"{operation}: expected abrupt exit 73, got {result.returncode}\n{result.stdout}\n{result.stderr}")
        subprocess.run([str(probe), "verify", operation, directory], check=True, timeout=40)
print(f"{len(operations) + 1} subprocess crash/reopen scenarios passed")
