#!/usr/bin/env python3
"""Reproducibility check: after `make all`, every committed file under results/ and figures/ must be unchanged and
no new file may appear there (compared with the last commit through git). Prints the differences and exits 1."""
import subprocess
import sys

paths = ["results", "figures"]
changed = subprocess.run(["git", "status", "--porcelain", "--", *paths], capture_output=True, text=True,
                         check=True).stdout.splitlines()
if not changed:
    print("reproduced: every result and figure is identical to the committed version")
    sys.exit(0)
print("these files differ from the committed versions:")
print("\n".join("  " + c for c in changed))
print("\n".join(subprocess.run(["git", "diff", "-U1", "--", *paths], capture_output=True,
                               text=True).stdout.splitlines()[:200]))
sys.exit(1)
