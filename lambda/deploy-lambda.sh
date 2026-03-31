#!/bin/bash
set -euo pipefail

###############################################################################
# Deploy PyPI Mirror Auto-Updater Lambda
#
# Usage:
#   bash lambda/deploy-lambda.sh              # Deploy/update Lambda + EventBridge
#   bash lambda/deploy-lambda.sh --invoke     # Deploy + run immediately
#
# Requires: aws cli, python3, pip3
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_DIR}/config.env"

# Export region so all AWS CLI commands pick it up automatically
export AWS_DEFAULT_REGION="${AWS_REGION}"

INVOKE_AFTER=false
if [[ "${1:-}" == "--invoke" ]]; then
    INVOKE_AFTER=true
fi

FUNCTION_NAME="pypi-mirror-updater"
ROLE_NAME="pypi-mirror-updater-role"
SNS_TOPIC_NAME="pypi-mirror-updates"
RULE_NAME="pypi-mirror-daily-update"
RUNTIME="python3.11"
HANDLER="handler.lambda_handler"
TIMEOUT=900
MEMORY=512
EPHEMERAL_MB=1024

BUILD_DIR="${SCRIPT_DIR}/build"
ZIP_FILE="${SCRIPT_DIR}/lambda.zip"

log() { echo "==> $1"; }

###############################################################################
# Phase 1: Build deployment package
###############################################################################
log "Phase 1: Building deployment package"

rm -rf "${BUILD_DIR}" "${ZIP_FILE}"
mkdir -p "${BUILD_DIR}"
cp "${SCRIPT_DIR}/handler.py" "${BUILD_DIR}/"

pip3 install packaging -t "${BUILD_DIR}/" --quiet 2>/dev/null

# Clean up unnecessary files from pip install
find "${BUILD_DIR}" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "${BUILD_DIR}" -name "*.dist-info" -type d -exec rm -rf {} + 2>/dev/null || true

cd "${BUILD_DIR}" && zip -r "${ZIP_FILE}" . -q && cd "${PROJECT_DIR}"
ZIP_SIZE=$(ls -lh "${ZIP_FILE}" | awk '{print $5}')
log "Built ${ZIP_FILE} (${ZIP_SIZE})"

###############################################################################
# Phase 2: Upload config to S3
###############################################################################
log "Phase 2: Uploading package list to S3"

UNPINNED_FILE="${PROJECT_DIR}/requirements-unpinned.txt"
if [[ ! -f "${UNPINNED_FILE}" ]]; then
    log "Generating requirements-unpinned.txt from requirements-all.txt"
    sed -E 's/\[.*\]//g; s/[<>=!~;].*//' "${PROJECT_DIR}/requirements-all.txt" \
        | grep -E '^[a-zA-Z]' \
        | sort -u > "${UNPINNED_FILE}"
fi

aws s3 cp "${UNPINNED_FILE}" "s3://${BUCKET_NAME}/config/requirements-unpinned.txt" \
    --profile "${AWS_PROFILE}" --region "${AWS_REGION}" --quiet
log "Uploaded requirements-unpinned.txt to s3://${BUCKET_NAME}/config/"

###############################################################################
# Phase 3: Create IAM role (idempotent)
###############################################################################
log "Phase 3: Setting up IAM role"

ACCOUNT_ID=$(aws sts get-caller-identity --profile "${AWS_PROFILE}" --query 'Account' --output text)

TRUST_POLICY='{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "lambda.amazonaws.com"},
        "Action": "sts:AssumeRole"
    }]
}'

# Create role if it doesn't exist
if aws iam get-role --role-name "${ROLE_NAME}" --profile "${AWS_PROFILE}" &>/dev/null; then
    log "IAM role ${ROLE_NAME} already exists"
    ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --profile "${AWS_PROFILE}" \
        --query 'Role.Arn' --output text)
else
    log "Creating IAM role: ${ROLE_NAME}"
    ROLE_ARN=$(aws iam create-role \
        --role-name "${ROLE_NAME}" \
        --assume-role-policy-document "${TRUST_POLICY}" \
        --profile "${AWS_PROFILE}" \
        --query 'Role.Arn' --output text)
    log "Created role: ${ROLE_ARN}"
    # Wait for role to propagate
    sleep 10
fi

# Upsert inline policy
POLICY_DOC=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "S3List",
            "Effect": "Allow",
            "Action": ["s3:ListBucket"],
            "Resource": "arn:aws:s3:::${BUCKET_NAME}"
        },
        {
            "Sid": "S3ReadWrite",
            "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:PutObject", "s3:HeadObject"],
            "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
        },
        {
            "Sid": "CloudFront",
            "Effect": "Allow",
            "Action": ["cloudfront:CreateInvalidation"],
            "Resource": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${CLOUDFRONT_DISTRIBUTION_ID}"
        },
        {
            "Sid": "SNS",
            "Effect": "Allow",
            "Action": ["sns:Publish"],
            "Resource": "arn:aws:sns:${AWS_REGION}:${ACCOUNT_ID}:${SNS_TOPIC_NAME}"
        },
        {
            "Sid": "Logs",
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "arn:aws:logs:${AWS_REGION}:${ACCOUNT_ID}:*"
        }
    ]
}
EOF
)

aws iam put-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-name "pypi-mirror-updater-policy" \
    --policy-document "${POLICY_DOC}" \
    --profile "${AWS_PROFILE}"
log "IAM policy updated"

###############################################################################
# Phase 4: Create SNS topic (idempotent)
###############################################################################
log "Phase 4: Setting up SNS topic"

SNS_TOPIC_ARN=$(aws sns create-topic \
    --name "${SNS_TOPIC_NAME}" \
    --region "${AWS_REGION}" \
    --profile "${AWS_PROFILE}" \
    --query 'TopicArn' --output text)
log "SNS topic: ${SNS_TOPIC_ARN}"

###############################################################################
# Phase 5: Create/update Lambda function
###############################################################################
log "Phase 5: Deploying Lambda function"

ENV_VARS=$(cat <<EOF
{
    "Variables": {
        "BUCKET_NAME": "${BUCKET_NAME}",
        "CLOUDFRONT_DISTRIBUTION_ID": "${CLOUDFRONT_DISTRIBUTION_ID}",
        "SNS_TOPIC_ARN": "${SNS_TOPIC_ARN}",
        "CONFIG_KEY": "config/requirements-unpinned.txt"
    }
}
EOF
)

if aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}" --profile "${AWS_PROFILE}" &>/dev/null; then
    log "Updating existing Lambda function"
    aws lambda update-function-code \
        --function-name "${FUNCTION_NAME}" \
        --zip-file "fileb://${ZIP_FILE}" \
        --profile "${AWS_PROFILE}" \
        --query 'FunctionArn' --output text

    # Wait for update to complete before updating configuration
    aws lambda wait function-updated --function-name "${FUNCTION_NAME}" --profile "${AWS_PROFILE}"

    aws lambda update-function-configuration \
        --function-name "${FUNCTION_NAME}" \
        --runtime "${RUNTIME}" \
        --handler "${HANDLER}" \
        --timeout "${TIMEOUT}" \
        --memory-size "${MEMORY}" \
        --ephemeral-storage "Size=${EPHEMERAL_MB}" \
        --environment "${ENV_VARS}" \
        --profile "${AWS_PROFILE}" \
        --query 'FunctionArn' --output text
else
    log "Creating Lambda function"
    aws lambda create-function \
        --function-name "${FUNCTION_NAME}" \
        --runtime "${RUNTIME}" \
        --handler "${HANDLER}" \
        --role "${ROLE_ARN}" \
        --zip-file "fileb://${ZIP_FILE}" \
        --timeout "${TIMEOUT}" \
        --memory-size "${MEMORY}" \
        --ephemeral-storage "Size=${EPHEMERAL_MB}" \
        --environment "${ENV_VARS}" \
        --profile "${AWS_PROFILE}" \
        --query 'FunctionArn' --output text
fi

LAMBDA_ARN=$(aws lambda get-function --function-name "${FUNCTION_NAME}" --profile "${AWS_PROFILE}" \
    --query 'Configuration.FunctionArn' --output text)
log "Lambda deployed: ${LAMBDA_ARN}"

###############################################################################
# Phase 6: Create EventBridge rule
###############################################################################
log "Phase 6: Setting up EventBridge daily schedule"

RULE_ARN=$(aws events put-rule \
    --name "${RULE_NAME}" \
    --schedule-expression "cron(0 6 * * ? *)" \
    --state ENABLED \
    --description "Daily PyPI mirror update at 6:00 AM UTC" \
    --profile "${AWS_PROFILE}" \
    --query 'RuleArn' --output text)
log "EventBridge rule: ${RULE_ARN}"

# Grant EventBridge permission to invoke Lambda (idempotent via statement-id)
aws lambda add-permission \
    --function-name "${FUNCTION_NAME}" \
    --statement-id "eventbridge-daily-update" \
    --action "lambda:InvokeFunction" \
    --principal "events.amazonaws.com" \
    --source-arn "${RULE_ARN}" \
    --profile "${AWS_PROFILE}" 2>/dev/null || true

aws events put-targets \
    --rule "${RULE_NAME}" \
    --targets "[{\"Id\":\"1\",\"Arn\":\"${LAMBDA_ARN}\"}]" \
    --profile "${AWS_PROFILE}" \
    --query 'FailedEntryCount' --output text

log "EventBridge target configured"

###############################################################################
# Done
###############################################################################

echo ""
echo "============================================"
echo "  PyPI Mirror Auto-Updater Deployed!"
echo "============================================"
echo ""
echo "  Lambda:     ${FUNCTION_NAME}"
echo "  Schedule:   Daily at 6:00 AM UTC"
echo "  SNS Topic:  ${SNS_TOPIC_ARN}"
echo ""
echo "  Subscribe to notifications:"
echo "    aws sns subscribe \\"
echo "      --topic-arn ${SNS_TOPIC_ARN} \\"
echo "      --protocol email \\"
echo "      --notification-endpoint YOUR_EMAIL \\"
echo "      --profile ${AWS_PROFILE}"
echo ""
echo "  Manual invoke:"
echo "    aws lambda invoke --function-name ${FUNCTION_NAME} --profile ${AWS_PROFILE} /dev/stdout"
echo ""
echo "  Update package list:"
echo "    aws s3 cp requirements-unpinned.txt s3://${BUCKET_NAME}/config/requirements-unpinned.txt --profile ${AWS_PROFILE}"
echo ""
echo "============================================"

###############################################################################
# Optional: Test invoke
###############################################################################
if [[ "${INVOKE_AFTER}" == true ]]; then
    log "Invoking Lambda for test run..."

    # Wait for function to be active
    aws lambda wait function-active-v2 --function-name "${FUNCTION_NAME}" --profile "${AWS_PROFILE}" 2>/dev/null || sleep 5

    aws lambda invoke \
        --function-name "${FUNCTION_NAME}" \
        --profile "${AWS_PROFILE}" \
        --log-type Tail \
        --query 'LogResult' \
        --output text \
        "/tmp/pypi-mirror-lambda-output.json" | base64 -d

    echo ""
    log "Lambda response:"
    cat "/tmp/pypi-mirror-lambda-output.json"
    echo ""
fi
