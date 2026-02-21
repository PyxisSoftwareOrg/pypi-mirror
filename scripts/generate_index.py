#!/usr/bin/env python3
"""Generate PEP 503 compliant index from downloaded wheel/sdist files."""

import hashlib
import re
import sys
from collections import defaultdict
from pathlib import Path


def normalize(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def extract_package_name(filename: str) -> str | None:
    if filename.endswith(".whl"):
        return normalize(filename.split("-")[0])
    elif filename.endswith(".tar.gz"):
        match = re.match(r"^(.+?)-\d+", filename)
        return normalize(match.group(1)) if match else None
    elif filename.endswith(".zip"):
        match = re.match(r"^(.+?)-\d+", filename)
        return normalize(match.group(1)) if match else None
    return None


def sha256_file(filepath: Path) -> str:
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def generate_index(packages_dir: Path, index_dir: Path):
    package_files: dict[str, list[tuple[str, str]]] = defaultdict(list)

    for f in sorted(packages_dir.iterdir()):
        if not f.is_file():
            continue
        pkg_name = extract_package_name(f.name)
        if pkg_name:
            sha = sha256_file(f)
            package_files[pkg_name].append((f.name, sha))

    simple_dir = index_dir / "simple"
    simple_dir.mkdir(parents=True, exist_ok=True)

    root_links = []
    for pkg_name in sorted(package_files.keys()):
        root_links.append(f'    <a href="{pkg_name}/">{pkg_name}</a>')

    root_html = (
        "<!DOCTYPE html>\n<html><head><title>Simple Index</title>"
        "<meta name=\"api-version\" value=\"2\"/></head>\n"
        "<body>\n" + "\n".join(root_links) + "\n</body></html>"
    )
    (simple_dir / "index.html").write_text(root_html)

    for pkg_name, files in sorted(package_files.items()):
        pkg_dir = simple_dir / pkg_name
        pkg_dir.mkdir(parents=True, exist_ok=True)

        file_links = []
        for filename, sha in files:
            href = f"../../packages/{filename}#sha256={sha}"
            file_links.append(f'    <a href="{href}">{filename}</a>')

        pkg_html = (
            f"<!DOCTYPE html>\n<html><head><title>{pkg_name}</title>"
            f"<meta name=\"api-version\" value=\"2\"/></head>\n"
            "<body>\n" + "\n".join(file_links) + "\n</body></html>"
        )
        (pkg_dir / "index.html").write_text(pkg_html)

    total_files = sum(len(v) for v in package_files.values())
    print(f"Generated index: {len(package_files)} packages, {total_files} files")


if __name__ == "__main__":
    packages_path = sys.argv[1] if len(sys.argv) > 1 else "packages/all"
    index_path = sys.argv[2] if len(sys.argv) > 2 else "index"
    generate_index(Path(packages_path), Path(index_path))
