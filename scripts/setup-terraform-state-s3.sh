#!/bin/bash
# Setup S3 bucket and DynamoDB table for Terraform state storage
#
# Usage: ./scripts/setup-terraform-state-s3.sh [OPTIONS]
#
# Options:
#   -b, --bucket NAME     S3 bucket name for Terraform state
#   -r, --region REGION   AWS region (default: auto-detect from cluster)
#   -t, --table NAME      DynamoDB table name (default: terraform-state-lock)
#   -d, --delete          Delete resources instead of creating
#   -h, --help            Show this help message
#
# This script creates:
#   - S3 bucket with versioning and encryption enabled
#   - DynamoDB table for state locking
#   - Appropriate bucket policies

set -euo pipefail

# Default values
BUCKET_NAME="${BUCKET_NAME:-}"
REGION="${REGION:-}"
TABLE_NAME="${TABLE_NAME:-terraform-state-lock}"
DELETE_MODE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

usage() {
    head -16 "$0" | tail -13
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--bucket) BUCKET_NAME="$2"; shift 2 ;;
        -r|--region) REGION="$2"; shift 2 ;;
        -t|--table) TABLE_NAME="$2"; shift 2 ;;
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

# Default bucket name if not provided
if [[ -z "$BUCKET_NAME" ]]; then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
    BUCKET_NAME="terraform-state-${AWS_ACCOUNT_ID}-${REGION}"
    log_info "Using default bucket name: $BUCKET_NAME"
fi

log_section "Configuration"
log_info "Region: $REGION"
log_info "Bucket: $BUCKET_NAME"
log_info "DynamoDB Table: $TABLE_NAME"

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log_info "AWS Account ID: $AWS_ACCOUNT_ID"

delete_resources() {
    log_section "Deleting Terraform State Resources"

    # Delete DynamoDB table
    log_info "Deleting DynamoDB table $TABLE_NAME..."
    if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" 2>/dev/null; then
        aws dynamodb delete-table --table-name "$TABLE_NAME" --region "$REGION"
        log_info "Waiting for table deletion..."
        aws dynamodb wait table-not-exists --table-name "$TABLE_NAME" --region "$REGION" 2>/dev/null || true
        log_info "Deleted DynamoDB table"
    else
        log_warn "DynamoDB table $TABLE_NAME does not exist"
    fi

    # Empty and delete S3 bucket
    log_info "Emptying and deleting S3 bucket $BUCKET_NAME..."
    if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
        # Delete all versions and delete markers
        log_info "Removing all object versions..."
        aws s3api list-object-versions --bucket "$BUCKET_NAME" --output json 2>/dev/null | \
            jq -r '.Versions[]? | "\(.Key) \(.VersionId)"' | \
            while read -r key version; do
                aws s3api delete-object --bucket "$BUCKET_NAME" --key "$key" --version-id "$version" 2>/dev/null || true
            done

        log_info "Removing all delete markers..."
        aws s3api list-object-versions --bucket "$BUCKET_NAME" --output json 2>/dev/null | \
            jq -r '.DeleteMarkers[]? | "\(.Key) \(.VersionId)"' | \
            while read -r key version; do
                aws s3api delete-object --bucket "$BUCKET_NAME" --key "$key" --version-id "$version" 2>/dev/null || true
            done

        # Delete bucket
        aws s3 rb "s3://${BUCKET_NAME}" --region "$REGION" 2>/dev/null || true
        log_info "Deleted S3 bucket"
    else
        log_warn "S3 bucket $BUCKET_NAME does not exist"
    fi

    log_section "Deletion Complete"
}

create_resources() {
    log_section "Creating Terraform State Resources"

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

    # Enable versioning (required for state recovery)
    log_info "Enabling versioning on bucket..."
    aws s3api put-bucket-versioning --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled

    # Enable server-side encryption
    log_info "Enabling server-side encryption..."
    aws s3api put-bucket-encryption --bucket "$BUCKET_NAME" \
        --server-side-encryption-configuration '{
            "Rules": [
                {
                    "ApplyServerSideEncryptionByDefault": {
                        "SSEAlgorithm": "AES256"
                    },
                    "BucketKeyEnabled": true
                }
            ]
        }'

    # Block public access
    log_info "Blocking public access..."
    aws s3api put-public-access-block --bucket "$BUCKET_NAME" \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    # Add lifecycle rule to clean up old versions
    log_info "Adding lifecycle rule for old versions..."
    aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET_NAME" \
        --lifecycle-configuration '{
            "Rules": [
                {
                    "ID": "cleanup-old-versions",
                    "Status": "Enabled",
                    "NoncurrentVersionExpiration": {
                        "NoncurrentDays": 90
                    },
                    "Filter": {
                        "Prefix": ""
                    }
                }
            ]
        }'

    # Create DynamoDB table for state locking
    log_info "Creating DynamoDB table $TABLE_NAME for state locking..."
    if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" 2>/dev/null; then
        log_warn "DynamoDB table $TABLE_NAME already exists"
    else
        aws dynamodb create-table \
            --table-name "$TABLE_NAME" \
            --attribute-definitions AttributeName=LockID,AttributeType=S \
            --key-schema AttributeName=LockID,KeyType=HASH \
            --billing-mode PAY_PER_REQUEST \
            --region "$REGION" \
            --tags Key=Name,Value="$TABLE_NAME" Key=Purpose,Value="Terraform State Locking"
        
        log_info "Waiting for table to be active..."
        aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
        log_info "Created DynamoDB table"
    fi

    log_section "Setup Complete"
    echo ""
    log_info "Terraform State Backend Configuration:"
    echo ""
    echo "Add the following to your terraform/fsx-ontap/backend.tf:"
    echo ""
    cat <<EOF
terraform {
  backend "s3" {
    bucket         = "${BUCKET_NAME}"
    key            = "fsx-ontap/terraform.tfstate"
    region         = "${REGION}"
    encrypt        = true
    dynamodb_table = "${TABLE_NAME}"
  }
}
EOF
    echo ""
    log_info "Or run: make build-fsx-terraform TERRAFORM_STATE_BUCKET=$BUCKET_NAME"
}

# Main
if [[ "$DELETE_MODE" == "true" ]]; then
    delete_resources
else
    create_resources
fi
