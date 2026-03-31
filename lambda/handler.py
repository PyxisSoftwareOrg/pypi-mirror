"""
Lambda function to auto-update the PyPI mirror daily.

Checks PyPI for newer versions of mirrored packages, downloads new wheels
for all target platforms, uploads to S3, regenerates the PEP 503 index,
and invalidates CloudFront.
"""

import hashlib
import json
import os
import re
import time
import urllib.request
import urllib.error
from collections import defaultdict

import boto3
from packaging.version import Version, InvalidVersion

# ---------------------------------------------------------------------------
# Configuration from environment variables
# ---------------------------------------------------------------------------
BUCKET_NAME = os.environ["BUCKET_NAME"]
CLOUDFRONT_DISTRIBUTION_ID = os.environ["CLOUDFRONT_DISTRIBUTION_ID"]
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")
CONFIG_KEY = os.environ.get("CONFIG_KEY", "config/requirements-unpinned.txt")

# Target platforms — matches setup.sh Phase 3
PLATFORM_TAGS = {
    "linux_x86_64": [
        "manylinux2014_x86_64", "manylinux_2_17_x86_64",
        "manylinux_2_28_x86_64", "linux_x86_64",
    ],
    "linux_aarch64": [
        "manylinux2014_aarch64", "manylinux_2_17_aarch64",
        "manylinux_2_28_aarch64", "linux_aarch64",
    ],
    "macos_arm64": [
        "macosx_11_0_arm64", "macosx_12_0_arm64",
        "macosx_13_0_arm64", "macosx_14_0_arm64",
    ],
    "win_amd64": ["win_amd64"],
    "noarch": ["any"],
}
ALL_ACCEPTED_PLATFORMS = set()
for tags in PLATFORM_TAGS.values():
    ALL_ACCEPTED_PLATFORMS.update(tags)

PYTHON_TAGS = {"cp311", "py3", "py2.py3"}
ABI_TAGS = {"cp311", "none", "abi3"}

# Timeout guard — stop new packages at 14 minutes
MAX_RUNTIME_SECONDS = 14 * 60

# Wheel filename regex (same as check_upgrades.py / generate_index.py)
WHEEL_RE = re.compile(
    r"^(?P<name>[A-Za-z0-9]([A-Za-z0-9._]*[A-Za-z0-9])?)"
    r"-(?P<ver>[0-9][0-9A-Za-z._]*?)-.+\.whl$"
)

s3 = boto3.client("s3")
cloudfront = boto3.client("cloudfront")
sns = boto3.client("sns") if SNS_TOPIC_ARN else None


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def normalize(name):
    """PEP 503 package name normalization."""
    return re.sub(r"[-_.]+", "-", name).lower()


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def pypi_json(name, version=None):
    """Fetch package metadata from PyPI JSON API."""
    if version:
        url = "https://pypi.org/pypi/{}/{}/json".format(name, version)
    else:
        url = "https://pypi.org/pypi/{}/json".format(name)
    with urllib.request.urlopen(url, timeout=15) as resp:
        return json.loads(resp.read())


def wheel_matches_platform(filename):
    """Check if a wheel filename matches any of our target platforms."""
    if not filename.endswith(".whl"):
        return False
    # Wheel format: {name}-{ver}-{python}-{abi}-{platform}.whl
    parts = filename[:-4].split("-")
    if len(parts) < 5:
        return False
    python_tag = parts[2]
    abi_tag = parts[3]
    platform_tag = parts[4]

    # Check python tag
    python_ok = any(p in python_tag for p in PYTHON_TAGS)
    if not python_ok:
        return False

    # Check ABI tag
    abi_ok = any(a in abi_tag for a in ABI_TAGS)
    if not abi_ok:
        return False

    # Check platform tag — handle compound tags like "manylinux2014_x86_64.manylinux_2_17_x86_64"
    file_platforms = platform_tag.split(".")
    platform_ok = any(fp in ALL_ACCEPTED_PLATFORMS for fp in file_platforms)
    return platform_ok


# ---------------------------------------------------------------------------
# Step 1: Read package list from S3
# ---------------------------------------------------------------------------

def get_package_list():
    """Read requirements-unpinned.txt from S3."""
    resp = s3.get_object(Bucket=BUCKET_NAME, Key=CONFIG_KEY)
    body = resp["Body"].read().decode("utf-8")
    packages = []
    for line in body.strip().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            packages.append(line)
    return packages


# ---------------------------------------------------------------------------
# Step 2: List current S3 packages and extract versions
# ---------------------------------------------------------------------------

def get_s3_versions():
    """List all wheels in S3 and return {normalized_name: highest_version_str}."""
    versions = {}
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET_NAME, Prefix="packages/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            filename = key.split("/")[-1]
            m = WHEEL_RE.match(filename)
            if not m:
                continue
            name = normalize(m.group("name"))
            ver = m.group("ver")
            if name not in versions:
                versions[name] = ver
            else:
                try:
                    if Version(ver) > Version(versions[name]):
                        versions[name] = ver
                except InvalidVersion:
                    pass
    return versions


# ---------------------------------------------------------------------------
# Step 3: Check PyPI for newer versions
# ---------------------------------------------------------------------------

def find_upgradeable(package_list, s3_versions):
    """Return list of (name, mirror_ver, latest_ver) for packages with updates."""
    upgradeable = []
    errors = []
    for pkg in package_list:
        norm = normalize(pkg)
        try:
            data = pypi_json(pkg)
            latest = data["info"]["version"]
            mirror_ver = s3_versions.get(norm)
            if mirror_ver is None:
                # New package not yet in mirror
                upgradeable.append((pkg, None, latest))
            elif Version(latest) > Version(mirror_ver):
                upgradeable.append((pkg, mirror_ver, latest))
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            errors.append((pkg, str(e)))
        except (InvalidVersion, KeyError, json.JSONDecodeError) as e:
            errors.append((pkg, str(e)))
    return upgradeable, errors


# ---------------------------------------------------------------------------
# Step 4: Download and upload new wheels
# ---------------------------------------------------------------------------

def download_and_upload(pkg_name, version):
    """Download matching wheels from PyPI for a specific version, upload to S3.

    Returns (uploaded_count, skipped_count, errors).
    """
    uploaded = 0
    skipped = 0
    errors = []

    try:
        data = pypi_json(pkg_name, version)
    except Exception as e:
        return 0, 0, ["{} {}: failed to fetch release info: {}".format(pkg_name, version, e)]

    for file_info in data.get("urls", []):
        filename = file_info["filename"]
        if not wheel_matches_platform(filename):
            continue

        sha256_expected = file_info.get("digests", {}).get("sha256", "")
        download_url = file_info["url"]

        try:
            # Download to memory (wheels are typically small)
            with urllib.request.urlopen(download_url, timeout=60) as resp:
                wheel_data = resp.read()

            # Verify SHA256
            if sha256_expected:
                sha256_actual = sha256_bytes(wheel_data)
                if sha256_actual != sha256_expected:
                    errors.append("{}: SHA256 mismatch".format(filename))
                    continue

            # Check if already in S3
            try:
                head = s3.head_object(Bucket=BUCKET_NAME, Key="packages/" + filename)
                if head["ContentLength"] == len(wheel_data):
                    skipped += 1
                    continue
            except s3.exceptions.ClientError:
                pass  # Not in S3 yet, proceed with upload

            # Upload to S3
            s3.put_object(
                Bucket=BUCKET_NAME,
                Key="packages/" + filename,
                Body=wheel_data,
            )
            uploaded += 1

        except Exception as e:
            errors.append("{}: {}".format(filename, str(e)))

    return uploaded, skipped, errors


# ---------------------------------------------------------------------------
# Step 5: Regenerate PEP 503 index
# ---------------------------------------------------------------------------

def regenerate_index():
    """Rebuild the full PEP 503 index from the S3 packages listing."""
    package_files = defaultdict(list)

    # List all wheels and compute structure
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=BUCKET_NAME, Prefix="packages/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            filename = key.split("/")[-1]
            if not filename.endswith(".whl"):
                continue
            pkg_name = normalize(filename.split("-")[0])

            # We need the SHA256 — fetch the object's ETag or compute from metadata
            # For efficiency, download the object to compute SHA256
            # But this is expensive for all files. Instead, use a HEAD + ETag approach.
            # However, S3 ETags for non-multipart uploads ARE the MD5, not SHA256.
            # We must download to compute SHA256.
            # Optimization: download in parallel or cache hashes.
            # For now, download each file to compute SHA256 (they're already in S3).
            resp = s3.get_object(Bucket=BUCKET_NAME, Key=key)
            data = resp["Body"].read()
            sha = sha256_bytes(data)
            package_files[pkg_name].append((filename, sha))

    # Generate root index
    root_links = []
    for pkg_name in sorted(package_files.keys()):
        root_links.append('    <a href="{0}/">{0}</a>'.format(pkg_name))

    root_html = (
        "<!DOCTYPE html>\n<html><head><title>Simple Index</title>"
        '<meta name="api-version" value="2"/></head>\n'
        "<body>\n" + "\n".join(root_links) + "\n</body></html>"
    )
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key="simple/index.html",
        Body=root_html.encode("utf-8"),
        ContentType="text/html",
    )

    # Generate per-package indexes
    for pkg_name, files in sorted(package_files.items()):
        file_links = []
        for filename, sha in files:
            href = "../../packages/{}#sha256={}".format(filename, sha)
            file_links.append('    <a href="{}">{}</a>'.format(href, filename))

        pkg_html = (
            "<!DOCTYPE html>\n<html><head><title>{}</title>".format(pkg_name)
            + '<meta name="api-version" value="2"/></head>\n'
            + "<body>\n" + "\n".join(file_links) + "\n</body></html>"
        )
        s3.put_object(
            Bucket=BUCKET_NAME,
            Key="simple/{}/index.html".format(pkg_name),
            Body=pkg_html.encode("utf-8"),
            ContentType="text/html",
        )

    return len(package_files)


# ---------------------------------------------------------------------------
# Step 6: Invalidate CloudFront
# ---------------------------------------------------------------------------

def invalidate_cloudfront():
    cloudfront.create_invalidation(
        DistributionId=CLOUDFRONT_DISTRIBUTION_ID,
        InvalidationBatch={
            "Paths": {"Quantity": 1, "Items": ["/simple/*"]},
            "CallerReference": "lambda-{}".format(int(time.time())),
        },
    )


# ---------------------------------------------------------------------------
# Step 7: Send SNS notification
# ---------------------------------------------------------------------------

def send_notification(subject, message):
    if sns and SNS_TOPIC_ARN:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=subject[:100],
            Message=message,
        )


# ---------------------------------------------------------------------------
# Lambda handler
# ---------------------------------------------------------------------------

def lambda_handler(event, context):
    start_time = time.time()
    print("Starting PyPI mirror update")

    # Step 1: Get package list
    package_list = get_package_list()
    print("Monitoring {} packages".format(len(package_list)))

    # Step 2: Get current S3 versions
    s3_versions = get_s3_versions()
    print("Found {} packages in S3 mirror".format(len(s3_versions)))

    # Step 3: Find upgradeable packages
    upgradeable, check_errors = find_upgradeable(package_list, s3_versions)
    print("Found {} packages to upgrade, {} check errors".format(
        len(upgradeable), len(check_errors)))

    if not upgradeable:
        msg = "PyPI Mirror: all {} packages up to date.".format(len(package_list))
        if check_errors:
            msg += "\n\nErrors checking {} packages:\n".format(len(check_errors))
            for pkg, err in check_errors:
                msg += "  - {}: {}\n".format(pkg, err)
        print(msg)
        send_notification("PyPI Mirror: No updates", msg)
        return {"statusCode": 200, "updated": 0, "message": msg}

    # Step 4: Download and upload new wheels
    total_uploaded = 0
    total_skipped = 0
    upload_errors = []
    updated_packages = []
    deferred_packages = []

    for pkg_name, mirror_ver, latest_ver in upgradeable:
        elapsed = time.time() - start_time
        if elapsed > MAX_RUNTIME_SECONDS:
            deferred_packages.append((pkg_name, mirror_ver, latest_ver))
            continue

        print("Updating {}: {} -> {}".format(pkg_name, mirror_ver or "NEW", latest_ver))
        uploaded, skipped, errors = download_and_upload(pkg_name, latest_ver)
        total_uploaded += uploaded
        total_skipped += skipped
        upload_errors.extend(errors)
        if uploaded > 0:
            updated_packages.append((pkg_name, mirror_ver, latest_ver))

    # Step 5: Regenerate index
    if updated_packages:
        print("Regenerating PEP 503 index...")
        pkg_count = regenerate_index()
        print("Index regenerated for {} packages".format(pkg_count))

        # Step 6: Invalidate CloudFront
        print("Invalidating CloudFront cache...")
        invalidate_cloudfront()

    # Step 7: Send notification
    lines = ["PyPI Mirror Update Summary", ""]
    lines.append("Packages checked: {}".format(len(package_list)))
    lines.append("Packages updated: {}".format(len(updated_packages)))
    lines.append("Wheels uploaded: {}".format(total_uploaded))
    lines.append("Wheels skipped (already present): {}".format(total_skipped))

    if updated_packages:
        lines.append("")
        lines.append("Updated packages:")
        for pkg, old, new in updated_packages:
            lines.append("  {} {} -> {}".format(pkg, old or "NEW", new))

    if deferred_packages:
        lines.append("")
        lines.append("Deferred (timeout): {}".format(len(deferred_packages)))
        for pkg, old, new in deferred_packages:
            lines.append("  {} {} -> {}".format(pkg, old or "NEW", new))

    if check_errors:
        lines.append("")
        lines.append("Check errors:")
        for pkg, err in check_errors:
            lines.append("  {}: {}".format(pkg, err))

    if upload_errors:
        lines.append("")
        lines.append("Upload errors:")
        for err in upload_errors:
            lines.append("  {}".format(err))

    msg = "\n".join(lines)
    print(msg)

    subject = "PyPI Mirror: {} packages updated".format(len(updated_packages))
    if deferred_packages:
        subject += ", {} deferred".format(len(deferred_packages))
    send_notification(subject, msg)

    return {
        "statusCode": 200,
        "updated": len(updated_packages),
        "uploaded": total_uploaded,
        "deferred": len(deferred_packages),
        "errors": len(check_errors) + len(upload_errors),
    }
