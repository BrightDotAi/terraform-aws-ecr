 locals {
   enabled       = module.this.enabled
   enabled_count = local.enabled ? 1 : 0
   
  principals_readonly_access_non_empty = length(var.principals_readonly_access) > 0
  principals_push_access_non_empty     = length(var.principals_push_access) > 0
  principals_full_access_non_empty     = length(var.principals_full_access) > 0
  principals_lambda_non_empty          = length(var.principals_lambda) > 0
  ecr_need_policy                      = length(var.principals_full_access) + length(var.principals_readonly_access) + length(var.principals_push_access) + length(var.principals_lambda) > 0
  
   _name                       = var.use_fullname ? module.this.id : module.this.name
  image_names                 = length(var.image_names) > 0 ? var.image_names : tomap(local._name)
  repository_creation_enabled = local.enabled && var.repository_creation_enabled

  principals_pullthrough_access = toset(concat(var.principals_readonly_access, var.principals_full_access, var.principals_lambda))
  image_names_pullthrough       = toset([ for k,v in local.image_names : k if contains(var.pullthrough_prefixes, split("/", k)[0]) ])

   standard_repositories    = local.ecr_need_policy && local.enabled ? setsubtract(keys(local.image_names), local.image_names_pullthrough) : []
   pullthrough_repositories = local.ecr_need_policy && local.enabled ? local.image_names_pullthrough : []

   standard_repositories_existing    = local.enabled ?  setintersection(local.standard_repositories, data.aws_ecr_repositories.existing[0].names) : []
   pullthrough_repositories_existing = local.enabled ? setintersection(local.pullthrough_repositories, data.aws_ecr_repositories.existing[0].names) : []
}

 data "aws_ecr_repositories" "existing" {
   count = local.enabled_count
 }

resource "aws_ecr_repository" "name" {
  for_each             = local.repository_creation_enabled ? local.image_names : {}
  name                 = each.key
  image_tag_mutability = var.image_tag_mutability
  force_delete         = each.value.force_delete_override

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

locals {
  untagged_image_rule = [{
    rulePriority = length(var.protected_tags) + 1
    description  = "Remove untagged images"
    selection = {
      tagStatus   = "untagged"
      countType   = "imageCountMoreThan"
      countNumber = 1
    }
    action = {
      type = "expire"
    }
  }]

  remove_old_image_rule = [{
    rulePriority = length(var.protected_tags) + 2
    description  = "Rotate images when reach ${var.max_image_count} images stored",
    selection = {
      tagStatus   = "any"
      countType   = "imageCountMoreThan"
      countNumber = var.max_image_count
    }
    action = {
      type = "expire"
    }
  }]

  protected_tag_rules = [
    for index, tagPrefix in zipmap(range(length(var.protected_tags)), tolist(var.protected_tags)) :
    {
      rulePriority = tonumber(index) + 1
      description  = "Protects images tagged with ${tagPrefix}"
      selection = {
        tagStatus     = "tagged"
        tagPrefixList = [tagPrefix]
        countType     = "imageCountMoreThan"
        countNumber   = 999999
      }
      action = {
        type = "expire"
      }
    }
  ]

  archive_remove_all_rule = [{
    rulePriority = 2
    description  = "Remove all images for archived repos"
    selection = {
      tagStatus   = "any"
      countType   = "imageCountMoreThan"
      countNumber = 1
    }
    action = {
      type = "expire"
    }
  }]

  archive_protected_tag_rules = [
    
    {
      rulePriority = 1
      description  = "Protects archived repo release images"
      selection = {
        tagStatus     = "tagged"
        tagPrefixList = ["*.*.*"]
        countType     = "imageCountMoreThan"
        countNumber   = 999999
      }
      action = {
        type = "expire"
      }
    }
  ]

  lifecycle_policy_default = jsonencode({
    rules = concat(local.protected_tag_rules, local.untagged_image_rule, local.remove_old_image_rule)
  })

  lifecycle_policy_archive = jsonencode({
    rules = concat(local.archive_protected_tag_rules, local.archive_remove_all_rule)
  })
}

resource "aws_ecr_lifecycle_policy" "name" {
  for_each   = local.repository_creation_enabled && var.enable_lifecycle_policy ? local.image_names : {}
  repository = aws_ecr_repository.name[each.key].name

  policy = each.value.archive_enabled ? local.lifecycle_policy_archive : local.lifecycle_policy_default
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

 data "aws_iam_policy_document" "resource_pull_through_cache" {
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

data "aws_iam_policy_document" "lambda_access" {
  count = local.enabled && length(var.principals_lambda) > 0 ? 1 : 0

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
  count                   = local.enabled_count
  source_policy_documents = local.principals_readonly_access_non_empty ? [data.aws_iam_policy_document.resource_readonly_access[0].json] : [data.aws_iam_policy_document.empty[0].json]
  override_policy_documents = distinct([
    local.principals_push_access_non_empty ? data.aws_iam_policy_document.resource_push_access[0].json : data.aws_iam_policy_document.empty[0].json,
    local.principals_full_access_non_empty ? data.aws_iam_policy_document.resource_full_access[0].json : data.aws_iam_policy_document.empty[0].json,
    local.principals_lambda_non_empty ? data.aws_iam_policy_document.lambda_access[0].json : data.aws_iam_policy_document.empty[0].json,
  ])
}

 data "aws_iam_policy_document" "pullthrough_resource" {
   count                   = local.enabled_count
   source_policy_documents = [data.aws_iam_policy_document.resource_pull_through_cache[0].json]
   override_policy_documents = distinct([
       local.principals_readonly_access_non_empty ? data.aws_iam_policy_document.resource_readonly_access[0].json : data.aws_iam_policy_document.empty[0].json,
       local.principals_full_access_non_empty ? data.aws_iam_policy_document.resource_full_access[0].json : data.aws_iam_policy_document.empty[0].json,
       local.principals_lambda_non_empty ? data.aws_iam_policy_document.lambda_access[0].json : data.aws_iam_policy_document.empty[0].json,
   ])
 }

resource "aws_ecr_repository_policy" "name" {
  for_each   = var.repository_creation_enabled ? local.standard_repositories : local.standard_repositories_existing
  repository = each.key
  policy     = join("", data.aws_iam_policy_document.resource[*].json)
}

 resource "aws_ecr_repository_policy" "pullthrough" {
   for_each   = var.repository_creation_enabled ? local.pullthrough_repositories : local.pullthrough_repositories_existing
   repository = each.key
   policy = join("", data.aws_iam_policy_document.pullthrough_resource[*].json)
 }

data "aws_caller_identity" "current" {}

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
