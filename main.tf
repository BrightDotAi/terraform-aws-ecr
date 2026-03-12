locals {
  enabled = module.this.enabled && length(var.repositories) > 0
  enabled_count = local.enabled ? 1 : 0

  principals_readonly_access_non_empty     = length(var.principals_readonly_access) > 0
  principals_pullthrough_access_non_empty = length(var.principals_pull_though_access) > 0
  principals_push_access_non_empty         = length(var.principals_push_access) > 0
  principals_full_access_non_empty         = length(var.principals_full_access) > 0
  principals_lambda_non_empty              = length(var.principals_lambda) > 0

  ecr_need_policy = (
    length(var.principals_full_access)
    + length(var.principals_readonly_access)
    + length(var.principals_pull_though_access)
    + length(var.principals_push_access)
    + length(var.principals_lambda) > 0
  )

  image_names = keys(var.repositories)
  repository_creation_enabled   = local.enabled && var.repository_creation_enabled
  principals_pullthrough_access = toset(concat(var.principals_readonly_access, var.principals_full_access, var.principals_lambda))
  image_names_pullthrough       = toset([ for k,v in var.repositories : k if contains(var.pullthrough_repository_prefixes, split("/", k)[0]) ])

  standard_repositories    = local.ecr_need_policy && local.enabled ? setsubtract(local.image_names, local.image_names_pullthrough) : []
  pullthrough_repositories = local.ecr_need_policy && local.enabled ? local.image_names_pullthrough : []

  existing_repository_names         = length(data.aws_ecr_repositories.existing[0].names) > 0 ? data.aws_ecr_repositories.existing[0].names : []
  standard_repositories_existing    = local.enabled ? setintersection(local.standard_repositories, local.existing_repository_names) : []
  pullthrough_repositories_existing = local.enabled ? setintersection(local.pullthrough_repositories, local.existing_repository_names) : []

  # remove key:value pairs from the lifecycle rules object when value is null.  For compliance with ECR API 
  default_lifecycle_rules = [ for rule in var.default_lifecycle_rules : merge(
    {
      for k, v in rule:
      k => v
      if v != null
    },
    {
      selection = {
        for k, v in rule.selection:
        k => v
        if v != null
      }
    },
    {
      action = {
        for k, v in rule.action:
        k => v
        if v != null
      }
    }
  )]
  
  default_lifecycle_rules_json = jsonencode({ rules = local.default_lifecycle_rules})

  # remove key:value pairs from the lifecycle rules object when value is null.  For compliance with ECR API
  custom_lifecycle_rules = { for k, v in var.repositories:
    k => [ for rule in v.lifecycle_rules_override: merge(
      {
        for i, j in rule:
        i => j
        if j != null
      },
      {
        selection = {
        for i, j in rule.selection:
        i => j
        if j != null
        }
      },
      {
        action = {
          for i, j in rule.action:
          i => j
          if j != null
        }
      }
    )]
    if v.lifecycle_rules_override != null
  }

  custom_lifecycle_rules_json = { for k, v in local.custom_lifecycle_rules:
    k => jsonencode({ rules = v})
  }

  image_tag_mutability = { for k, v in var.repositories:
    k => v.image_tag_mutability != null ? {
      image_tag_mutability = v.image_tag_mutability
      image_tag_mutability_exclusion_filter = strcontains( v.image_tag_mutability, "_WITH_EXCLUSION") ? [
        for exclusion_filter in v.image_tag_mutability_exclusion_filter : 
        {
          filter = exclusion_filter.filter
          filter_type = exclusion_filter.filter_type
        }
      ] : []
    } :
    {
      image_tag_mutability = var.default_image_tag_mutability
      image_tag_mutability_exclusion_filter = var.default_image_tag_mutability_exclusion_filter
    }  
  }
}

data "aws_caller_identity" "current" {}

data "aws_ecr_repositories" "existing" {
  count = local.enabled_count
}

resource "aws_ecr_repository" "name" {
  for_each             = local.repository_creation_enabled ? var.repositories : {}
  name                 = each.key
  image_tag_mutability = local.image_tag_mutability[each.key].image_tag_mutability

  dynamic "image_tag_mutability_exclusion_filter" {
    for_each = local.image_tag_mutability[each.key].image_tag_mutability_exclusion_filter
    content {
      filter = image_tag_mutability_exclusion_filter.value.filter
      filter_type = image_tag_mutability_exclusion_filter.value.filter_type
    }
  }
  
  force_delete         = each.value.force_delete

  dynamic "encryption_configuration" {
    for_each = var.encryption_configuration == null ? [] : [var.encryption_configuration]
    content {
      encryption_type = encryption_configuration.value.encryption_type
      kms_key         = encryption_configuration.value.kms_key
    }
  }

  image_scanning_configuration {
    scan_on_push = var.scan_images_on_push
  }

  tags = module.this.tags
}

resource "aws_ecr_lifecycle_policy" "name" {
  for_each   = local.repository_creation_enabled ? var.repositories : {}
  repository = aws_ecr_repository.name[each.key].name

  policy = each.value.lifecycle_rules_override == null ? local.default_lifecycle_rules_json : local.custom_lifecycle_rules_json[each.key]
}

data "aws_iam_policy_document" "empty" {
  count = local.enabled_count
}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "resource_readonly_access" {
  count = local.enabled_count

  statement {
    sid    = "ReadonlyAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.principals_readonly_access
    }

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImageScanFindings",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetLifecyclePolicy",
      "ecr:GetLifecyclePolicyPreview",
      "ecr:GetRepositoryPolicy",
      "ecr:ListImages",
      "ecr:ListTagsForResource",
    ]
  }
}
data "aws_iam_policy_document" "resource_pullthrough_cache" {
  count = local.enabled_count

  statement {
    sid    = "PullThroughAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = local.principals_pullthrough_access
    }

    actions = [
      "ecr:BatchImportUpstreamImage",
      "ecr:TagResource"
    ]
  }
}

data "aws_iam_policy_document" "resource_push_access" {
  count = local.enabled_count

  statement {
    sid    = "PushAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.principals_push_access
    }

    actions = [
      "ecr:CompleteLayerUpload",
      "ecr:GetAuthorizationToken",
      "ecr:UploadLayerPart",
      "ecr:InitiateLayerUpload",
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
    ]
  }
}

data "aws_iam_policy_document" "resource_full_access" {
  count = local.enabled_count

  statement {
    sid    = "FullAccess"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.principals_full_access
    }

    actions = ["ecr:*"]
  }
}

data "aws_iam_policy_document" "lambda_access" {
  count = module.this.enabled && length(var.principals_lambda) > 0 ? 1 : 0

  statement {
    sid    = "LambdaECRImageCrossAccountRetrievalPolicy"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      values   = local.principals_lambda_non_empty ? formatlist("arn:%s:lambda:*:%s:function:*", data.aws_partition.current.partition, var.principals_lambda) : []
      variable = "aws:SourceArn"
    }
  }

  statement {
    sid    = "CrossAccountPermission"
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ]

    principals {
      type        = "AWS"
      identifiers = local.principals_lambda_non_empty ? formatlist("arn:%s:iam::%s:root", data.aws_partition.current.partition, var.principals_lambda) : []
    }
  }
}

data "aws_iam_policy_document" "resource" {
  for_each = toset(local.ecr_need_policy && module.this.enabled ? local.image_names : [])
  source_policy_documents = local.principals_readonly_access_non_empty ? [
    data.aws_iam_policy_document.resource_readonly_access[0].json
  ] : [data.aws_iam_policy_document.empty[0].json]
  override_policy_documents = distinct([
    local.principals_push_access_non_empty ? data.aws_iam_policy_document.resource_push_access[0].json : data.aws_iam_policy_document.empty[0].json,
    local.principals_full_access_non_empty ? data.aws_iam_policy_document.resource_full_access[0].json : data.aws_iam_policy_document.empty[0].json,
    local.principals_lambda_non_empty ? data.aws_iam_policy_document.lambda_access[0].json : data.aws_iam_policy_document.empty[0].json
  ])
}

data "aws_iam_policy_document" "pullthrough_resource" {
  count                   = local.enabled_count
  source_policy_documents = [data.aws_iam_policy_document.resource_pullthrough_cache[0].json]
  override_policy_documents = distinct([
      local.principals_readonly_access_non_empty ? data.aws_iam_policy_document.resource_readonly_access[0].json : data.aws_iam_policy_document.empty[0].json,
      local.principals_full_access_non_empty ? data.aws_iam_policy_document.resource_full_access[0].json : data.aws_iam_policy_document.empty[0].json,
      local.principals_lambda_non_empty ? data.aws_iam_policy_document.lambda_access[0].json : data.aws_iam_policy_document.empty[0].json,
  ])
}

resource "aws_ecr_repository_policy" "name" {
  for_each   = toset(local.ecr_need_policy && module.this.enabled ? local.image_names : [])
  repository = aws_ecr_repository.name[each.value].name
  policy     = data.aws_iam_policy_document.resource[each.value].json
}

resource "aws_ecr_repository_policy" "pullthrough" {
  for_each   = local.repository_creation_enabled ? local.pullthrough_repositories : local.pullthrough_repositories_existing
  repository = each.key
  policy = join("", data.aws_iam_policy_document.pullthrough_resource[*].json)
}

resource "aws_ecr_replication_configuration" "same_account_cross_region" {
  count = local.repository_creation_enabled && length(var.replication_regions) > 0 ? 1 : 0

  replication_configuration {
    dynamic "rule" {
      for_each = var.replication_regions
      content {
        destination {
          region      = rule.value
          registry_id = data.aws_caller_identity.current.account_id
        }
      }
    }
  }
}
