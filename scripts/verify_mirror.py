#!/usr/bin/env python3
"""Verify the mirror has wheels for all packages in the requirements file."""

import re
import sys
from pathlib import Path


def normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def verify(requirements_file: str, packages_dir: str):
    reqs = Path(requirements_file).read_text().strip().split("\n")
    available = {f.name.lower() for f in Path(packages_dir).iterdir() if f.is_file()}

    missing = []
    checked = 0
    for req in reqs:
        req = req.strip()
        if not req or req.startswith("#") or req.startswith("-"):
            continue
        match = re.match(r"^([a-zA-Z0-9_.\-\[\]]+)", req)
        if not match:
            continue
        raw_name = match.group(1).split("[")[0]
        pkg_name = normalize(raw_name)
        pkg_underscore = pkg_name.replace("-", "_")
        checked += 1

        pkg_dot = pkg_name.replace("-", ".")
        found = any(
            f.startswith(pkg_name + "-") or f.startswith(pkg_underscore + "-") or f.startswith(pkg_dot + "-")
            for f in available
        )
        if not found:
            missing.append(req)

    if missing:
        print(f"MISSING {len(missing)}/{checked} packages:")
        for m in missing:
            print(f"  - {m}")
        sys.exit(1)
    else:
        print(f"All {checked} packages present in mirror.")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <requirements.txt> <packages_dir>")
        sys.exit(1)
    verify(sys.argv[1], sys.argv[2])
