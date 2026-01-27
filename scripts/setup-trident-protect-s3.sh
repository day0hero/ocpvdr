#!/bin/bash
# Setup S3 bucket and IAM policy for Trident Protect AppVault
#
# Usage: ./scripts/setup-trident-protect-s3.sh [OPTIONS]
#
# Options:
#   -b, --bucket NAME     S3 bucket name (default: from values-trident.yaml)
#   -r, --region REGION   AWS region (default: auto-detect from cluster)
#   -p, --policy NAME     IAM policy name (default: trident-protect-s3-policy)
#   -d, --delete          Delete resources instead of creating
#   -h, --help            Show this help message

set -euo pipefail

# Default values
BUCKET_NAME="${BUCKET_NAME:-ocpvdr-trident-protect}"
REGION="${REGION:-}"
POLICY_NAME="${POLICY_NAME:-trident-protect-s3-policy}"
DELETE_MODE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    head -14 "$0" | tail -11
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--bucket) BUCKET_NAME="$2"; shift 2 ;;
        -r|--region) REGION="$2"; shift 2 ;;
        -p|--policy) POLICY_NAME="$2"; shift 2 ;;
        -d|--delete) DELETE_MODE=true; shift ;;
        -h|--help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Auto-detect region from cluster if not provided
if [[ -z "$REGION" ]]; then
    log_info "Auto-detecting region from cluster..."
    REGION=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}' 2>/dev/null || true)
    if [[ -z "$REGION" ]]; then
        log_error "Could not detect region from cluster. Please specify with -r/--region"
        exit 1
    fi
fi

log_info "Using region: $REGION"
log_info "Using bucket: $BUCKET_NAME"
log_info "Using policy: $POLICY_NAME"

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log_info "AWS Account ID: $AWS_ACCOUNT_ID"

# IAM Policy document
POLICY_DOCUMENT=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "TridentProtectS3Access",
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
                "s3:GetBucketLocation",
                "s3:AbortMultipartUpload",
                "s3:ListMultipartUploadParts"
            ],
            "Resource": [
                "arn:aws:s3:::${BUCKET_NAME}",
                "arn:aws:s3:::${BUCKET_NAME}/*"
            ]
        }
    ]
}
EOF
)

delete_resources() {
    log_warn "Deleting Trident Protect S3 resources..."

    # Delete IAM policy
    log_info "Deleting IAM policy $POLICY_NAME..."
    aws iam delete-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}" 2>/dev/null || true

    # Empty and delete bucket
    log_info "Emptying and deleting bucket $BUCKET_NAME..."
    aws s3 rm "s3://${BUCKET_NAME}" --recursive 2>/dev/null || true
    aws s3 rb "s3://${BUCKET_NAME}" --region "$REGION" 2>/dev/null || true

    log_info "Deletion complete!"
}

create_resources() {
    log_info "Creating Trident Protect S3 resources..."

    # Create S3 bucket
    log_info "Creating S3 bucket $BUCKET_NAME..."
    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        log_warn "Bucket $BUCKET_NAME already exists"
    else
        if [[ "$REGION" == "us-east-1" ]]; then
            aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION"
        else
            aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$REGION" \
                --create-bucket-configuration LocationConstraint="$REGION"
        fi
        log_info "Created bucket $BUCKET_NAME"
    fi

    # Enable versioning (recommended for backups)
    log_info "Enabling versioning on bucket..."
    aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled

    # Block public access
    log_info "Blocking public access..."
    aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    # Create IAM policy
    log_info "Creating IAM policy $POLICY_NAME..."
    if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}" 2>/dev/null; then
        log_warn "Policy $POLICY_NAME already exists"
    else
        aws iam create-policy --policy-name "$POLICY_NAME" \
            --policy-document "$POLICY_DOCUMENT" \
            --description "Trident Protect S3 access policy for AppVault"
        log_info "Created policy $POLICY_NAME"
    fi

    log_info "Setup complete!"
    echo ""
    log_info "S3 Bucket: s3://${BUCKET_NAME}"
    log_info "Region: ${REGION}"
    log_info "IAM Policy ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
    echo ""
    log_info "Attach the policy to your IAM user/role that has credentials in Vault"
}

# Main
if [[ "$DELETE_MODE" == "true" ]]; then
    delete_resources
else
    create_resources
fi
