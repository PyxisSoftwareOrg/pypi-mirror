#!/bin/bash
set -euo pipefail

###############################################################################
# PyPI Mirror Setup & Refresh
#
# Usage:
#   bash setup.sh              # Full setup (infra + download + index + push)
#   bash setup.sh --refresh    # Skip infra, re-download and sync
#
# Requires: aws cli, python3, pip3 (poetry optional — falls back to lock parser)
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/config.env"

REFRESH_ONLY=false
if [[ "${1:-}" == "--refresh" ]]; then
    REFRESH_ONLY=true
fi

PKG_DIR="${SCRIPT_DIR}/packages"
INDEX_DIR="${SCRIPT_DIR}/index"
REQS_ALL="${SCRIPT_DIR}/requirements-all.txt"
REQS_PROD="${SCRIPT_DIR}/requirements-prod.txt"

log() { echo "==> $1"; }
warn() { echo "WARNING: $1" >&2; }

###############################################################################
# Phase 1: AWS Infrastructure (skipped with --refresh)
###############################################################################
setup_infra() {
    log "Phase 1: AWS Infrastructure"

    # Check if bucket exists
    if aws s3api head-bucket --bucket "${BUCKET_NAME}" --profile "${AWS_PROFILE}" 2>/dev/null; then
        log "Bucket s3://${BUCKET_NAME} already exists, skipping creation"
    else
        log "Creating S3 bucket: ${BUCKET_NAME}"
        aws s3 mb "s3://${BUCKET_NAME}" \
            --region "${AWS_REGION}" \
            --profile "${AWS_PROFILE}"

        log "Blocking public access"
        aws s3api put-public-access-block \
            --bucket "${BUCKET_NAME}" \
            --public-access-block-configuration \
                BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
            --profile "${AWS_PROFILE}"

        log "Enabling versioning"
        aws s3api put-bucket-versioning \
            --bucket "${BUCKET_NAME}" \
            --versioning-configuration Status=Enabled \
            --profile "${AWS_PROFILE}"

        log "Adding lifecycle rule (delete old versions after 30 days)"
        aws s3api put-bucket-lifecycle-configuration \
            --bucket "${BUCKET_NAME}" \
            --lifecycle-configuration '{
                "Rules": [{
                    "ID": "cleanup-old-versions",
                    "Status": "Enabled",
                    "Filter": {"Prefix": ""},
                    "NoncurrentVersionExpiration": {
                        "NoncurrentDays": 30
                    }
                }]
            }' \
            --profile "${AWS_PROFILE}"
    fi

    # CloudFront setup
    if [[ -n "${CLOUDFRONT_DISTRIBUTION_ID}" ]]; then
        log "CloudFront distribution already configured: ${CLOUDFRONT_DISTRIBUTION_ID}"
    else
        log "Creating CloudFront Origin Access Control"
        OAC_ID=$(aws cloudfront create-origin-access-control \
            --origin-access-control-config '{
                "Name": "orbit-pypi-mirror-oac",
                "Description": "OAC for PyPI mirror S3 bucket",
                "SigningProtocol": "sigv4",
                "SigningBehavior": "always",
                "OriginAccessControlOriginType": "s3"
            }' \
            --profile "${AWS_PROFILE}" \
            --query 'OriginAccessControl.Id' \
            --output text)
        log "Created OAC: ${OAC_ID}"

        BUCKET_DOMAIN="${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com"

        log "Creating CloudFront distribution"
        CF_RESULT=$(aws cloudfront create-distribution \
            --profile "${AWS_PROFILE}" \
            --distribution-config "{
                \"CallerReference\": \"orbit-pypi-mirror-$(date +%s)\",
                \"Comment\": \"PyPI mirror for orbit-core-agent\",
                \"Enabled\": true,
                \"DefaultRootObject\": \"index.html\",
                \"PriceClass\": \"PriceClass_100\",
                \"Origins\": {
                    \"Quantity\": 1,
                    \"Items\": [{
                        \"Id\": \"pypi-s3\",
                        \"DomainName\": \"${BUCKET_DOMAIN}\",
                        \"OriginAccessControlId\": \"${OAC_ID}\",
                        \"S3OriginConfig\": {
                            \"OriginAccessIdentity\": \"\"
                        }
                    }]
                },
                \"DefaultCacheBehavior\": {
                    \"TargetOriginId\": \"pypi-s3\",
                    \"ViewerProtocolPolicy\": \"redirect-to-https\",
                    \"AllowedMethods\": {
                        \"Quantity\": 2,
                        \"Items\": [\"GET\", \"HEAD\"],
                        \"CachedMethods\": {
                            \"Quantity\": 2,
                            \"Items\": [\"GET\", \"HEAD\"]
                        }
                    },
                    \"ForwardedValues\": {
                        \"QueryString\": false,
                        \"Cookies\": {\"Forward\": \"none\"}
                    },
                    \"MinTTL\": 0,
                    \"DefaultTTL\": 86400,
                    \"MaxTTL\": 604800,
                    \"Compress\": true
                },
                \"ViewerCertificate\": {
                    \"CloudFrontDefaultCertificate\": true
                },
                \"Restrictions\": {
                    \"GeoRestriction\": {
                        \"RestrictionType\": \"none\",
                        \"Quantity\": 0
                    }
                }
            }")

        CF_DIST_ID=$(echo "${CF_RESULT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['Distribution']['Id'])")
        CF_DOMAIN=$(echo "${CF_RESULT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['Distribution']['DomainName'])")

        log "CloudFront distribution created: ${CF_DIST_ID} (${CF_DOMAIN})"

        # Get AWS account ID for bucket policy
        ACCOUNT_ID=$(aws sts get-caller-identity --profile "${AWS_PROFILE}" --query 'Account' --output text)
        CF_ARN="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${CF_DIST_ID}"

        log "Applying bucket policy for CloudFront OAC"
        aws s3api put-bucket-policy \
            --bucket "${BUCKET_NAME}" \
            --profile "${AWS_PROFILE}" \
            --policy "{
                \"Version\": \"2012-10-17\",
                \"Statement\": [{
                    \"Sid\": \"AllowCloudFrontOAC\",
                    \"Effect\": \"Allow\",
                    \"Principal\": {\"Service\": \"cloudfront.amazonaws.com\"},
                    \"Action\": \"s3:GetObject\",
                    \"Resource\": \"arn:aws:s3:::${BUCKET_NAME}/*\",
                    \"Condition\": {
                        \"StringEquals\": {
                            \"AWS:SourceArn\": \"${CF_ARN}\"
                        }
                    }
                }]
            }"

        # Save to config.env
        sed -i.bak "s|^CLOUDFRONT_DISTRIBUTION_ID=.*|CLOUDFRONT_DISTRIBUTION_ID=\"${CF_DIST_ID}\"|" "${SCRIPT_DIR}/config.env"
        sed -i.bak "s|^CLOUDFRONT_DOMAIN=.*|CLOUDFRONT_DOMAIN=\"${CF_DOMAIN}\"|" "${SCRIPT_DIR}/config.env"
        rm -f "${SCRIPT_DIR}/config.env.bak"

        log "Config saved. Mirror URL: https://${CF_DOMAIN}/simple/"
        log "NOTE: CloudFront may take 5-15 minutes to fully deploy"
    fi
}

###############################################################################
# Phase 2: Export requirements from poetry.lock
###############################################################################
export_requirements() {
    log "Phase 2: Exporting requirements from orbit-core-agent"

    if [[ ! -d "${ORBIT_PROJECT}" ]]; then
        echo "ERROR: orbit-core-agent not found at ${ORBIT_PROJECT}" >&2
        exit 1
    fi

    LOCK_FILE="${ORBIT_PROJECT}/poetry.lock"
    PYPROJECT_FILE="${ORBIT_PROJECT}/pyproject.toml"

    if [[ ! -f "${LOCK_FILE}" ]]; then
        echo "ERROR: poetry.lock not found at ${LOCK_FILE}" >&2
        exit 1
    fi

    if command -v poetry &>/dev/null; then
        log "Using poetry CLI to export"
        cd "${ORBIT_PROJECT}"
        poetry export -f requirements.txt --without-hashes --without dev \
            -o "${REQS_PROD}" 2>/dev/null || true
        poetry export -f requirements.txt --without-hashes \
            -o "${REQS_ALL}" 2>/dev/null || true
        cd "${SCRIPT_DIR}"
    else
        log "Poetry not found, parsing poetry.lock directly"
        python3 "${SCRIPT_DIR}/scripts/export_from_lock.py" \
            "${LOCK_FILE}" "${REQS_PROD}" --without-dev --pyproject "${PYPROJECT_FILE}"
        python3 "${SCRIPT_DIR}/scripts/export_from_lock.py" \
            "${LOCK_FILE}" "${REQS_ALL}"
    fi

    PROD_COUNT=$(grep -c '[a-zA-Z]' "${REQS_PROD}" 2>/dev/null || echo 0)
    ALL_COUNT=$(grep -c '[a-zA-Z]' "${REQS_ALL}" 2>/dev/null || echo 0)
    log "Exported ${PROD_COUNT} production + ${ALL_COUNT} total packages"
}

###############################################################################
# Phase 3: Download packages per platform
###############################################################################
download_packages() {
    log "Phase 3: Downloading packages from pypi.org"

    mkdir -p "${PKG_DIR}/linux-amd64" "${PKG_DIR}/linux-arm64" "${PKG_DIR}/macos-arm64" "${PKG_DIR}/win-amd64" "${PKG_DIR}/noarch" "${PKG_DIR}/all"

    PYPI="https://pypi.org/simple/"

    # Download function: iterates per-package so one failure doesn't abort all
    download_for_platform() {
        local label="$1" dest="$2" reqs="$3"
        shift 3
        local platform_args=("$@")
        local ok=0 fail=0

        log "Downloading ${label} wheels"
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            pkg="$line"
            if pip3 download "$pkg" \
                --dest "$dest" \
                --index-url "${PYPI}" \
                --no-deps \
                "${platform_args[@]}" \
                --quiet 2>/dev/null; then
                ((ok++))
            else
                ((fail++))
            fi
        done < "$reqs"
        log "${label}: ${ok} downloaded, ${fail} skipped (no wheel for platform)"
    }

    # --- Linux amd64 (all deps — needed for Docker dev builds too) ---
    download_for_platform "linux/amd64" "${PKG_DIR}/linux-amd64" "${REQS_ALL}" \
        --python-version 311 --implementation cp --only-binary=:all: --abi cp311 \
        --platform manylinux2014_x86_64 \
        --platform manylinux_2_17_x86_64 \
        --platform manylinux_2_28_x86_64 \
        --platform linux_x86_64

    # --- Linux arm64 (local Docker on Apple Silicon) ---
    download_for_platform "linux/arm64" "${PKG_DIR}/linux-arm64" "${REQS_ALL}" \
        --python-version 311 --implementation cp --only-binary=:all: --abi cp311 \
        --platform manylinux2014_aarch64 \
        --platform manylinux_2_17_aarch64 \
        --platform manylinux_2_28_aarch64 \
        --platform linux_aarch64

    # --- macOS arm64 (dev) ---
    download_for_platform "macOS/arm64" "${PKG_DIR}/macos-arm64" "${REQS_ALL}" \
        --python-version 311 --implementation cp --only-binary=:all: --abi cp311 \
        --platform macosx_11_0_arm64 \
        --platform macosx_12_0_arm64 \
        --platform macosx_13_0_arm64 \
        --platform macosx_14_0_arm64

    # --- Windows amd64 ---
    download_for_platform "Windows/amd64" "${PKG_DIR}/win-amd64" "${REQS_ALL}" \
        --python-version 311 --implementation cp --only-binary=:all: --abi cp311 \
        --platform win_amd64

    # --- Pure Python (noarch) ---
    download_for_platform "noarch" "${PKG_DIR}/noarch" "${REQS_ALL}" \
        --python-version 311 --implementation cp --only-binary=:all: \
        --abi none --platform any

    # --- Consolidate (cp -n = don't overwrite) ---
    log "Consolidating packages"
    cp -n "${PKG_DIR}"/linux-amd64/*.whl "${PKG_DIR}/all/" 2>/dev/null || true
    cp -n "${PKG_DIR}"/linux-arm64/*.whl "${PKG_DIR}/all/" 2>/dev/null || true
    cp -n "${PKG_DIR}"/macos-arm64/*.whl "${PKG_DIR}/all/" 2>/dev/null || true
    cp -n "${PKG_DIR}"/win-amd64/*.whl "${PKG_DIR}/all/" 2>/dev/null || true
    cp -n "${PKG_DIR}"/noarch/*.whl "${PKG_DIR}/all/" 2>/dev/null || true

    TOTAL=$(ls -1 "${PKG_DIR}/all/" 2>/dev/null | wc -l | tr -d ' ')
    log "Consolidated ${TOTAL} unique wheel files"
}

###############################################################################
# Phase 4: Generate PEP 503 index
###############################################################################
generate_index() {
    log "Phase 4: Generating PEP 503 index"
    python3 "${SCRIPT_DIR}/scripts/generate_index.py" "${PKG_DIR}/all" "${INDEX_DIR}"
}

###############################################################################
# Phase 5: Push to S3
###############################################################################
push_to_s3() {
    log "Phase 5: Syncing to S3"

    log "Uploading packages (skipping unchanged)"
    aws s3 sync "${PKG_DIR}/all/" "s3://${BUCKET_NAME}/packages/" \
        --profile "${AWS_PROFILE}" \
        --size-only \
        --no-progress

    log "Uploading index"
    aws s3 sync "${INDEX_DIR}/simple/" "s3://${BUCKET_NAME}/simple/" \
        --profile "${AWS_PROFILE}" \
        --delete \
        --content-type "text/html" \
        --no-progress

    # Re-source config in case Phase 1 updated it
    source "${SCRIPT_DIR}/config.env"

    if [[ -n "${CLOUDFRONT_DISTRIBUTION_ID}" ]]; then
        log "Invalidating CloudFront cache"
        aws cloudfront create-invalidation \
            --distribution-id "${CLOUDFRONT_DISTRIBUTION_ID}" \
            --paths "/simple/*" \
            --profile "${AWS_PROFILE}" \
            --query 'Invalidation.Id' \
            --output text
    fi
}

###############################################################################
# Phase 6: Verify
###############################################################################
verify_mirror() {
    log "Phase 6: Verifying mirror"
    python3 "${SCRIPT_DIR}/scripts/verify_mirror.py" "${REQS_ALL}" "${PKG_DIR}/all" || true

    source "${SCRIPT_DIR}/config.env"
    if [[ -n "${CLOUDFRONT_DOMAIN}" ]]; then
        echo ""
        echo "============================================"
        echo "  PyPI Mirror Ready!"
        echo "============================================"
        echo ""
        echo "  Mirror URL: https://${CLOUDFRONT_DOMAIN}/simple/"
        echo ""
        echo "  Usage:"
        echo "    pip install <pkg> --index-url https://${CLOUDFRONT_DOMAIN}/simple/"
        echo ""
        echo "  pip.conf:"
        echo "    [global]"
        echo "    index-url = https://${CLOUDFRONT_DOMAIN}/simple/"
        echo "    extra-index-url = https://pypi.org/simple/"
        echo ""
        echo "  Refresh: bash $(basename "$0") --refresh"
        echo "============================================"
    fi
}

###############################################################################
# Main
###############################################################################
echo ""
echo "PyPI Mirror Setup — orbit-core-agent"
echo "Bucket: s3://${BUCKET_NAME} | Profile: ${AWS_PROFILE} | Region: ${AWS_REGION}"
echo ""

if [[ "${REFRESH_ONLY}" == false ]]; then
    setup_infra
fi

export_requirements
download_packages
generate_index
push_to_s3
verify_mirror
