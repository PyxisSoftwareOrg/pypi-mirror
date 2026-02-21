#!/usr/bin/env python3
"""Parse poetry.lock and export requirements.txt (fallback when poetry CLI unavailable)."""

import re
import sys
from pathlib import Path

try:
    import tomllib
except ImportError:
    import tomli as tomllib


def parse_lock(lock_path: str, output_path: str, exclude_dev: bool = False, pyproject_path: str | None = None):
    lock = tomllib.loads(Path(lock_path).read_text())
    packages = lock.get("package", [])

    dev_packages = set()
    if exclude_dev and pyproject_path:
        pyproject = tomllib.loads(Path(pyproject_path).read_text())
        dev_deps = pyproject.get("tool", {}).get("poetry", {}).get("group", {})
        for group_name, group_data in dev_deps.items():
            if group_name != "main":
                for dep_name in group_data.get("dependencies", {}):
                    dev_packages.add(dep_name.lower())

    # Keep ALL versions (lock file may have multiple versions of same package)
    entries: list[str] = []
    for pkg in packages:
        name = pkg["name"]
        version = pkg["version"]
        category = pkg.get("category", "main")

        if exclude_dev and (category == "dev" or name.lower() in dev_packages):
            continue

        entries.append(f"{name}=={version}")

    lines = sorted(set(entries), key=str.lower)
    Path(output_path).write_text("\n".join(lines) + "\n")
    print(f"Exported {len(lines)} packages to {output_path}")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <poetry.lock> <output.txt> [--without-dev] [--pyproject <pyproject.toml>]")
        sys.exit(1)

    lock_file = sys.argv[1]
    output_file = sys.argv[2]
    exclude_dev = "--without-dev" in sys.argv

    pyproject_file = None
    if "--pyproject" in sys.argv:
        idx = sys.argv.index("--pyproject")
        pyproject_file = sys.argv[idx + 1]

    parse_lock(lock_file, output_file, exclude_dev, pyproject_file)
