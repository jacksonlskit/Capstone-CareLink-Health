terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

# ------------------------------------------------------------------------------
# Provider Configurations
# ------------------------------------------------------------------------------
provider "aws" {
  region = local.aws_region
}

provider "github" {
  owner = local.github_owner
}

# ------------------------------------------------------------------------------
# Locals & Shared Parameters
# ------------------------------------------------------------------------------
locals {
  github_owner = "jacksonlskit"

  # IMPORTANT: Match the EXACT slug from https://github.com/jacksonlskit/<repo-name>
  github_repo = "Capstone-CareLink-Health"

  repo_path  = "${local.github_owner}/${local.github_repo}"
  aws_region = "us-east-1"
  oidc_url   = "https://token.actions.githubusercontent.com"
  audience   = "sts.amazonaws.com"
}

# Fetch authenticated user ID to assign as production reviewer
data "github_user" "current" {
  username = local.github_owner
}

# ==============================================================================
# 1. Look up existing AWS IAM OIDC Provider (Prevents 409 Conflict)
# ==============================================================================
data "aws_iam_openid_connect_provider" "github" {
  url = local.oidc_url
}

# ==============================================================================
# 2. AWS IAM Role: DevOps (CD / Deployment Role)
# ==============================================================================
data "aws_iam_policy_document" "devops_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = [local.audience]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.repo_path}:environment:staging",
        "repo:${local.repo_path}:environment:production"
      ]
    }
  }
}

resource "aws_iam_role" "devops" {
  name               = "carelink-github-devops-role"
  assume_role_policy = data.aws_iam_policy_document.devops_trust.json

  tags = {
    Role    = "DevOps"
    Project = "CareLink-Health"
  }
}

resource "aws_iam_role_policy_attachment" "devops_ecr" {
  role       = aws_iam_role.devops.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# ==============================================================================
# 3. AWS IAM Role: Solutions Architect (IaC Plan & Audit Role)
# ==============================================================================
data "aws_iam_policy_document" "sa_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = [local.audience]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.repo_path}:ref:refs/heads/*",
        "repo:${local.repo_path}:pull_request"
      ]
    }
  }
}

resource "aws_iam_role" "sa" {
  name               = "carelink-github-sa-role"
  assume_role_policy = data.aws_iam_policy_document.sa_trust.json

  tags = {
    Role    = "SolutionsArchitect"
    Project = "CareLink-Health"
  }
}

resource "aws_iam_role_policy_attachment" "sa_readonly" {
  role       = aws_iam_role.sa.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ==============================================================================
# 4. AWS IAM Role: SRE (Observability & Ops Maintenance Role)
# ==============================================================================
data "aws_iam_policy_document" "sre_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = [local.audience]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:job_workflow_ref"
      values = [
        "${local.repo_path}/.github/workflows/sre-ops.yml@*"
      ]
    }
  }
}

resource "aws_iam_role" "sre" {
  name               = "carelink-github-sre-role"
  assume_role_policy = data.aws_iam_policy_document.sre_trust.json

  tags = {
    Role    = "SRE"
    Project = "CareLink-Health"
  }
}

resource "aws_iam_role_policy_attachment" "sre_cloudwatch" {
  role       = aws_iam_role.sre.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
}

# ==============================================================================
# 5. GitHub Environments (Staging & Production)
# ==============================================================================
resource "github_repository_environment" "staging" {
  repository  = local.github_repo
  environment = "staging"
}

resource "github_repository_environment" "production" {
  repository  = local.github_repo
  environment = "production"

  reviewers {
    users = [data.github_user.current.id]
  }

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "production_branch" {
  repository     = local.github_repo
  environment    = github_repository_environment.production.environment
  branch_pattern = "main"
}

# ==============================================================================
# 6. GitHub Actions Variables
# ==============================================================================
resource "github_actions_environment_variable" "staging_devops_role" {
  repository    = local.github_repo
  environment   = github_repository_environment.staging.environment
  variable_name = "DEVOPS_ROLE_ARN"
  value         = aws_iam_role.devops.arn
}

resource "github_actions_environment_variable" "prod_devops_role" {
  repository    = local.github_repo
  environment   = github_repository_environment.production.environment
  variable_name = "DEVOPS_ROLE_ARN"
  value         = aws_iam_role.devops.arn
}

resource "github_actions_variable" "sa_role" {
  repository    = local.github_repo
  variable_name = "SA_ROLE_ARN"
  value         = aws_iam_role.sa.arn
}

resource "github_actions_variable" "sre_role" {
  repository    = local.github_repo
  variable_name = "SRE_ROLE_ARN"
  value         = aws_iam_role.sre.arn
}

resource "github_actions_variable" "aws_region" {
  repository    = local.github_repo
  variable_name = "AWS_REGION"
  value         = local.aws_region
}

# ==============================================================================
# 7. GitHub Repository Ruleset: Main Branch Protection
# ==============================================================================
resource "github_repository_ruleset" "main_protection" {
  name        = "main-protection"
  repository  = local.github_repo
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      required_approving_review_count = 1
      dismiss_stale_reviews_on_push   = true
      require_code_owner_review       = false
      require_last_push_approval      = true
    }

    required_status_checks {
      strict_required_status_checks_policy = true

      required_check {
        context = "test"
      }
      required_check {
        context = "lint-and-typecheck"
      }
    }
  }
}

# ==============================================================================
# Outputs
# ==============================================================================
output "oidc_provider_arn" {
  value = data.aws_iam_openid_connect_provider.github.arn
}

output "devops_role_arn" {
  value = aws_iam_role.devops.arn
}

output "sa_role_arn" {
  value = aws_iam_role.sa.arn
}

output "sre_role_arn" {
  value = aws_iam_role.sre.arn
}
