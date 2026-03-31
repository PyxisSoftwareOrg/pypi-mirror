#!/usr/bin/env python3
"""Compare mirror package versions against latest on PyPI and report upgradeable packages."""

import json
import re
import subprocess
import sys
import urllib.request
from typing import Dict, Optional
from packaging.version import Version, InvalidVersion


def normalize(name):
    return re.sub(r"[-_.]+", "-", name).lower()


# Regex: name-version-rest.whl
WHEEL_RE = re.compile(
    r"^(?P<name>[A-Za-z0-9]([A-Za-z0-9._]*[A-Za-z0-9])?)-(?P<ver>[0-9][0-9A-Za-z._]*?)-.+\.whl$"
)


def get_s3_packages(bucket, profile):
    """Return {normalized_name: version} from S3 listing."""
    result = subprocess.run(
        ["aws", "s3", "ls", "s3://{}/packages/".format(bucket), "--profile", profile],
        capture_output=True, text=True, check=True,
    )
    versions = {}
    for line in result.stdout.strip().splitlines():
        filename = line.split()[-1]
        m = WHEEL_RE.match(filename)
        if not m:
            continue
        name = normalize(m.group("name"))
        ver = m.group("ver")
        # Keep the highest version per package
        if name not in versions:
            versions[name] = ver
        else:
            try:
                if Version(ver) > Version(versions[name]):
                    versions[name] = ver
            except InvalidVersion:
                pass
    return versions


def get_pypi_latest(name):
    """Fetch latest version from PyPI JSON API."""
    url = f"https://pypi.org/pypi/{name}/json"
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            data = json.loads(resp.read())
            return data["info"]["version"]
    except Exception:
        return None


def main():
    bucket = "orbit-pypi-mirror"
    profile = "pyxis"

    print("Fetching package list from S3...")
    mirror = get_s3_packages(bucket, profile)
    print(f"Found {len(mirror)} unique packages in mirror.\n")

    upgradeable = []
    up_to_date = []
    errors = []

    for i, (name, mirror_ver) in enumerate(sorted(mirror.items()), 1):
        sys.stdout.write(f"\r  Checking {i}/{len(mirror)}: {name:<40}")
        sys.stdout.flush()
        latest = get_pypi_latest(name)
        if latest is None:
            errors.append((name, mirror_ver, "could not fetch from PyPI"))
            continue
        try:
            if Version(latest) > Version(mirror_ver):
                upgradeable.append((name, mirror_ver, latest))
            else:
                up_to_date.append(name)
        except InvalidVersion:
            errors.append((name, mirror_ver, f"invalid version: {latest}"))

    print("\r" + " " * 60)

    if upgradeable:
        print(f"\n{'='*70}")
        print(f"  UPGRADEABLE: {len(upgradeable)} packages")
        print(f"{'='*70}")
        print(f"  {'Package':<35} {'Mirror':<15} {'Latest':<15}")
        print(f"  {'-'*35} {'-'*15} {'-'*15}")
        for name, old, new in sorted(upgradeable):
            print(f"  {name:<35} {old:<15} {new:<15}")

    print(f"\n  Up to date: {len(up_to_date)} packages")

    if errors:
        print(f"\n  Errors ({len(errors)}):")
        for name, ver, err in errors:
            print(f"    {name} ({ver}): {err}")

    print()
    return 0 if not upgradeable else 1


if __name__ == "__main__":
    sys.exit(main())
