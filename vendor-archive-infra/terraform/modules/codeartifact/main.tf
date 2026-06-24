data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ──────────────────────────────────────────────────────────────────────────────
# CodeArtifact - npm package registry for vendor-logger
# Domain: vendor
# Repository: vendor-logger-npm
# Upstream: npmjs.com (for transitive deps)
# ──────────────────────────────────────────────────────────────────────────────

resource "aws_codeartifact_domain" "vendor_logger" {
  domain         = var.domain_name
  encryption_key = var.kms_key_arn

  tags = var.tags
}

# Upstream proxy to public npm
resource "aws_codeartifact_repository" "npm_upstream" {
  repository = "npm-upstream"
  domain     = aws_codeartifact_domain.vendor_logger.domain

  external_connections {
    external_connection_name = "public:npmjs"
  }

  tags = var.tags
}

# Internal repository - vendor-logger published here
resource "aws_codeartifact_repository" "vendor_logger" {
  repository  = var.repository_name
  domain      = aws_codeartifact_domain.vendor_logger.domain
  description = "vendor-logger - shared NestJS vendor call interceptor"

  upstream {
    repository_name = aws_codeartifact_repository.npm_upstream.repository
  }

  tags = var.tags
}

# ── Repository policy - who can read / publish ────────────────────────────────
resource "aws_codeartifact_repository_permissions_policy" "vendor_logger" {
  repository  = aws_codeartifact_repository.vendor_logger.repository
  domain      = aws_codeartifact_domain.vendor_logger.domain
  policy_document = data.aws_iam_policy_document.repo_policy.json
}

data "aws_iam_policy_document" "repo_policy" {
  # CI/CD publish role - for the package build pipeline
  statement {
    sid    = "AllowPublish"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = var.publisher_role_arns
    }
    actions = [
      "codeartifact:PublishPackageVersion",
      "codeartifact:PutPackageMetadata",
      "codeartifact:DescribePackageVersion",
      "codeartifact:ListPackageVersionAssets",
      "codeartifact:GetPackageVersionReadme",
      "codeartifact:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  # NestJS service roles - install vendor-logger during CI build
  statement {
    sid    = "AllowRead"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = concat(var.reader_role_arns, [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root",
      ])
    }
    actions = [
      "codeartifact:GetPackageVersionAsset",
      "codeartifact:GetPackageVersionReadme",
      "codeartifact:DescribePackageVersion",
      "codeartifact:ListPackageVersionAssets",
      "codeartifact:ListPackageVersionDependencies",
      "codeartifact:ListPackageVersions",
      "codeartifact:ListPackages",
      "codeartifact:ReadFromRepository",
      "codeartifact:GetRepositoryEndpoint",
      "codeartifact:GetAuthorizationToken",
    ]
    resources = ["*"]
  }
}

# ── Domain policy - allow GetAuthorizationToken across the account ────────────
resource "aws_codeartifact_domain_permissions_policy" "vendor_logger" {
  domain          = aws_codeartifact_domain.vendor_logger.domain
  policy_document = data.aws_iam_policy_document.domain_policy.json
}

data "aws_iam_policy_document" "domain_policy" {
  statement {
    sid    = "AllowGetToken"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["codeartifact:GetAuthorizationToken", "sts:GetServiceBearerToken"]
    resources = ["*"]
  }
}
