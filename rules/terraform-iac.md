---
description: Terraform & OpenTofu infrastructure-as-code production invariants, state lock safety, IAM least-privilege, and cloud security
globs: **/*.{tf,tfvars,hcl}
alwaysApply: false
---

# Terraform & OpenTofu Infrastructure-as-Code Production Invariants

> Add these rules to your project if writing Terraform or OpenTofu HCL code for AWS, GCP, Azure, or Cloud Infrastructure.

## 1. Remote State Locking & Backend Security
- **Mandatory Remote State with Concurrency Locking**:
  - ❌ **NEVER store Terraform state (`terraform.tfstate`) locally or in Git**. State files contain plaintext secrets, passwords, and private keys.
  - Use an encrypted remote backend with atomic state locking (e.g., AWS S3 + DynamoDB table with `LockID` string hash key, GCS with object versioning, or Terraform Cloud / Spacelift).
  - Configure backend locking timeout to prevent race conditions during concurrent CI/CD pipeline runs:
    ```hcl
    terraform {
      required_version = ">= 1.6.0, < 2.0.0"
      backend "s3" {
        bucket         = "corp-terraform-state-prod"
        key            = "vpc/terraform.tfstate"
        region         = "us-east-1"
        dynamodb_table = "corp-terraform-locks"
        encrypt        = true
      }
    }
    ```
- **State Backend Bucket Hardening**:
  - The S3 state bucket MUST have versioning enabled (`versioning { enabled = true }`), default server-side encryption with KMS, access logging, and `aws_s3_bucket_public_access_block` denying all public access.

## 2. Blast Radius Reduction & Destruction Immunity
- **Mandatory `prevent_destroy` for Stateful Resources**:
  - Production databases, storage buckets, KMS keys, and network backbones MUST declare `lifecycle { prevent_destroy = true }` to protect against accidental `terraform destroy` or inadvertent resource recreation:
    ```hcl
    resource "aws_rds_cluster" "primary" {
      cluster_identifier = "aurora-prod-cluster"
      # ...
      lifecycle {
        prevent_destroy = true
      }
    }
    ```
- **`create_before_destroy` for Zero-Downtime Replacements**:
  - Resources subject to replacement (e.g., Launch Templates, Auto Scaling Groups, Security Groups, TLS Certificates, DNS Records) MUST configure `lifecycle { create_before_destroy = true }` to eliminate traffic blackout windows during updates:
    ```hcl
    resource "aws_launch_template" "app" {
      name_prefix   = "app-v2-"
      image_id      = data.aws_ami.hardened_linux.id
      instance_type = "c6i.xlarge"

      lifecycle {
        create_before_destroy = true
      }
    }
    ```
- **Deliberate `ignore_changes`**:
  - Use `lifecycle { ignore_changes = [ ... ] }` strictly for attributes managed externally (e.g., ECS service `desired_count` managed by autoscaling policies, or tags managed by enterprise security policies). Never use `ignore_changes = all`.

## 3. Cloud Security & IAM Least-Privilege Invariants
- ❌ **ABSOLUTE BAN ON WILDCARD IAM ACTIONS & RESOURCES**:
  - Never generate `"Action": "*"` or `"Resource": "*"` in IAM policy documents.
  - Scope every action to the exact API call required, and scope resources to specific ARNs with account and region bounds:
    ```hcl
    # ❌ CATASTROPHIC PRIVILEGE ESCALATION:
    data "aws_iam_policy_document" "bad" {
      statement {
        actions   = ["*"]
        resources = ["*"]
      }
    }

    # ✅ Scoped least-privilege IAM policy:
    data "aws_iam_policy_document" "s3_read_only" {
      statement {
        sid       = "AllowScopedBucketRead"
        effect    = "Allow"
        actions   = ["s3:GetObject", "s3:ListBucket"]
        resources = [
          aws_s3_bucket.app_assets.arn,
          "${aws_s3_bucket.app_assets.arn}/*"
        ]
      }
    }
    ```
- ❌ **BAN OPEN INGRESS ON NON-PUBLIC PORTS (`0.0.0.0/0`)**:
  - Never expose SSH (22), RDP (3389), database ports (5432, 3306), Redis (6379), or Kafka (9092) to `0.0.0.0/0`.
  - Restrict administrative access to corporate VPNs, private VPC subnets, or use AWS SSM Session Manager / Cloudflare Access without open ingress ports.
  - Security group rules MUST reference source security group IDs instead of CIDR blocks whenever communicating within the same VPC:
    ```hcl
    resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
      security_group_id            = aws_security_group.db.id
      referenced_security_group_id = aws_security_group.app.id
      from_port                    = 5432
      to_port                      = 5432
      ip_protocol                  = "tcp"
      description                  = "Allow PostgreSQL access strictly from app cluster"
    }
    ```

## 4. S3 Bucket & Storage Hardening
- **Mandatory 4-Point S3 Public Access Block**:
  - Every `aws_s3_bucket` MUST be accompanied by an `aws_s3_bucket_public_access_block` resource:
    ```hcl
    resource "aws_s3_bucket_public_access_block" "app_data" {
      bucket = aws_s3_bucket.app_data.id

      block_public_acls       = true
      block_public_policy     = true
      ignore_public_acls      = true
      restrict_public_buckets = true
    }
    ```
- **Enforce SSE-KMS & Bucket Key**:
  - Always enforce KMS server-side encryption and enable Bucket Keys to reduce AWS KMS request costs by up to 99%:
    ```hcl
    resource "aws_s3_bucket_server_side_encryption_configuration" "app_data" {
      bucket = aws_s3_bucket.app_data.id

      rule {
        apply_server_side_encryption_by_default {
          kms_master_key_id = aws_kms_key.app_storage.arn
          sse_algorithm     = "aws:kms"
        }
        bucket_key_enabled = true
      }
    }
    ```

## 5. Secret Hygiene & Sensitive Variable Shielding
- ❌ **NEVER HARDCODE CREDENTIALS OR STORE IN `.tf` / `.tfvars`**:
  - Passwords, API tokens, and private keys MUST NOT appear in configuration files or Git commits.
  - Retrieve secrets dynamically from AWS Secrets Manager, SSM Parameter Store, or HashiCorp Vault using data sources or runtime IAM roles.
- **Mandatory `sensitive = true`**:
  - All variables and outputs that accept or expose credentials MUST declare `sensitive = true` to mask values in CLI logs and CI/CD console traces:
    ```hcl
    variable "db_master_password" {
      type        = string
      description = "Master password for primary database instance"
      sensitive   = true
      nullable    = false
    }

    output "db_endpoint" {
      value       = aws_rds_cluster.primary.endpoint
      description = "Direct RDS write endpoint"
      sensitive   = false
    }
    ```

## 6. Deterministic Versioning & Input Validation
- **Pessimistic Provider Version Pinning**:
  - Pin provider versions using pessimistic operator `~>` to allow patch releases while preventing breaking API changes:
    ```hcl
    terraform {
      required_providers {
        aws = {
          source  = "hashicorp/aws"
          version = "~> 5.40"
        }
      }
    }
    ```
- **Strict Variable Validation Blocks**:
  - Use `validation {}` blocks to reject malformed inputs before reaching `terraform plan`:
    ```hcl
    variable "environment" {
      type        = string
      description = "Deployment tier (dev, staging, prod)"
      validation {
        condition     = contains(["dev", "staging", "prod"], var.environment)
        error_message = "The environment must be one of: 'dev', 'staging', or 'prod'."
      }
    }

    variable "vpc_cidr" {
      type        = string
      description = "VPC IPv4 CIDR block"
      validation {
        condition     = can(cidrnetmask(var.vpc_cidr))
        error_message = "The vpc_cidr value must be a valid CIDR notation string (e.g. 10.0.0.0/16)."
      }
    }
    ```
- **Mandatory Resource Tagging Standards**:
  - Enforce global default tags on provider blocks for cost allocation, ownership, and compliance auditing:
    ```hcl
    provider "aws" {
      region = var.aws_region
      default_tags {
        tags = {
          Environment = var.environment
          Project     = var.project_name
          ManagedBy   = "Terraform"
          Repository  = var.git_repo_url
        }
      }
    }
    ```
