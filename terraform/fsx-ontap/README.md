# FSx ONTAP Terraform Module

This Terraform module creates an AWS FSx for NetApp ONTAP file system with associated resources.

## Resources Created

- FSx for NetApp ONTAP file system
- Storage Virtual Machine (SVM)
- Security group with all required ports for ONTAP access
- AWS Secrets Manager secrets for admin passwords (optional)

## Prerequisites

1. **Terraform** >= 1.0.0
2. **AWS CLI** configured with appropriate credentials
3. **OpenShift cluster** running on AWS (for auto-detection of VPC/subnets)

## S3 Backend Setup

Before using the S3 backend for state storage, create the required infrastructure:

```bash
# From the repository root
make setup-terraform-state

# Or with a specific bucket name
BUCKET_NAME=my-terraform-state make setup-terraform-state
```

This creates:
- S3 bucket with versioning and encryption
- DynamoDB table for state locking

## Usage

### Via Makefile (Recommended)

The Makefile wraps Ansible which orchestrates Terraform and handles network discovery.

```bash
# Create FSx ONTAP with local state
make build-fsx-terraform

# Create FSx ONTAP with S3 backend
make build-fsx-terraform TERRAFORM_STATE_BUCKET=my-bucket

# Destroy FSx ONTAP
make destroy-fsx-terraform

# Destroy with S3 backend
make destroy-fsx-terraform TERRAFORM_STATE_BUCKET=my-bucket
```

### Direct Terraform Usage

For direct Terraform usage:

```bash
cd terraform/fsx-ontap

# Copy example files
cp terraform.tfvars.example terraform.tfvars
cp backend.tf.example backend.tf  # If using S3 backend

# Edit terraform.tfvars with your values

# Initialize and apply
terraform init
terraform plan
terraform apply
```

## Variables

See `variables.tf` for all available variables. Key variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region | Required |
| `vpc_id` | VPC ID | Required |
| `subnet_ids` | List of subnet IDs (2 for MULTI_AZ) | Required |
| `route_table_ids` | List of route table IDs | Required |
| `file_system_name` | Name for the FSx file system (via Make: `cluster-region-fsx`) | Required |
| `storage_capacity` | Storage capacity in GiB | `1024` |
| `throughput_capacity` | Throughput in MBps | `1024` |
| `deployment_type` | `MULTI_AZ_1` or `SINGLE_AZ_1` | `MULTI_AZ_1` |
| `fsx_admin_password` | FSx admin password | Required |
| `svm_admin_password` | SVM admin password | Required |

## Outputs

| Output | Description |
|--------|-------------|
| `file_system_id` | FSx file system ID |
| `file_system_dns_name` | FSx DNS name |
| `svm_id` | Storage Virtual Machine ID |
| `svm_management_endpoint_dns_name` | SVM management endpoint DNS |
| `security_group_id` | Security group ID |
| `trident_config` | Configuration for Trident integration |

## Password Management

Passwords can be provided via:

1. **~/.fsx file** (recommended): Create a file with the password
   ```bash
   echo "MySecurePassword123!" > ~/.fsx
   chmod 600 ~/.fsx
   ```

2. **Command line**: Pass via `-e` flag
   ```bash
   ansible-playbook ... -e fsx_admin_password=MyPassword
   ```

3. **terraform.tfvars**: Add to the tfvars file (not recommended for production)

## State Management

### Local State

By default (when not using S3), Terraform state is stored locally in `terraform.tfstate`. This is suitable for development but not recommended for production.

### S3 Backend (per cluster/region)

For production, use the S3 backend. The Makefile scopes state by cluster and region so that different regions or branches do not share state and cannot destroy each other's resources:

- **State key**: `fsx-ontap/<CLUSTER>/<REGION>/terraform.tfstate` (e.g. `fsx-ontap/my-cluster/us-west-1/terraform.tfstate`)
- Override with `TERRAFORM_STATE_KEY=...` if needed.

```bash
# Setup S3 bucket and DynamoDB table
make setup-terraform-state

# Use the S3 backend (state key is auto-derived from CLUSTER and REGION)
make build-fsx-terraform TERRAFORM_STATE_BUCKET=<bucket-name>
```

Benefits of S3 backend:
- State is stored remotely and versioned
- State locking prevents concurrent modifications
- Per-cluster/region state avoids cross-region destroy

## Cleanup

```bash
# Delete FSx ONTAP resources
make destroy-fsx-terraform

# Delete Terraform state infrastructure (if using S3)
make destroy-terraform-state
```
