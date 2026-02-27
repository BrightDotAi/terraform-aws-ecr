locals {
  enabled = module.this.enabled && length(var.repositories) > 0
  enabled_count = local.enabled ? 1 : 0

  principals_readonly_access_non_empty     = length(var.principals_readonly_access) > 0
  principals_pullthrough_access_non_empty  = length(var.principals_pullthrough_access) > 0
  principals_push_access_non_empty         = length(var.principals_push_access) > 0
  principals_full_access_non_empty         = length(var.principals_full_access) > 0
  principals_lambda_non_empty              = length(var.principals_lambda) > 0
  organizations_readonly_access_non_empty  = length(var.organizations_readonly_access) > 0
  organizations_full_access_non_empty      = length(var.organizations_full_access) > 0
  organizations_push_non_empty             = length(var.organizations_push_access) > 0

  ecr_need_policy = (
    length(var.principals_full_access)
    + length(var.principals_readonly_access)
    + length(var.principals_pullthrough_access)
    + length(var.principals_push_access)
    + length(var.principals_lambda)
    + length(var.organizations_readonly_access)
    + length(var.organizations_full_access)
    + length(var.organizations_push_access) > 0
  )

  _name       = var.use_fullname ? module.this.id : module.this.name
  image_names = keys(var.repositories)
  repository_creation_enabled   = local.enabled && var.repository_creation_enabled
  principals_pullthrough_access = toset(concat(var.principals_readonly_access, var.principals_pullthrough_access, var.principals_full_access, var.principals_lambda))
  image_names_pullthrough       = toset([ for k,v in var.repositories : k if contains(var.pullthrough_prefixes, split("/", k)[0]) ])

  standard_repositories    = local.ecr_need_policy && local.enabled ? setsubtract(local.image_names, local.image_names_pullthrough) : []
  pullthrough_repositories = local.ecr_need_policy && local.enabled ? local.image_names_pullthrough : []

  existing_repository_names         = length(data.aws_ecr_repositories.existing[0].names) > 0 ? data.aws_ecr_repositories.existing[0].names : []
  standard_repositories_existing    = local.enabled ? setintersection(local.standard_repositories, local.existing_repository_names) : []
  pullthrough_repositories_existing = local.enabled ? setintersection(local.pullthrough_repositories, local.existing_repository_names) : []
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

  # exclusion_filter = { for k, v in var.repositories: 
  #   k => ( v.image_tag_mutability != null ? 
  #   ( strcontains(each.value.image_tag_mutability, "_WITH_EXCLUSION" ) ? each.value.image_tag_mutability_exclusion_filter[*].filter : [] ) : 
  #   ( strcontains(var.default_image_tag_mutability, "_WITH_EXCLUSION" ) ? var.default_image_tag_mutability_exclusion_filter[*].filter : [] ))

}


data "aws_ecr_repositories" "existing" {
  count = local.enabled_count
}

resource "aws_ecr_repository" "name" {
  for_each             = local.repository_creation_enabled ? var.repositories : {}
  name                 = each.key
  image_tag_mutability = each.value.image_tag_mutability != null ? each.value.image_tag_mutability : var.default_image_tag_mutability
  # dynamic "image_tag_mutability_exclusion_filter" {
  #   for_each = ( each.value.image_tag_mutability != null ? 
  #   ( strcontains(each.value.image_tag_mutability, "_WITH_EXCLUSION" ) ? each.value.image_tag_mutability_exclusion_filter[*].filter : [] ) : 
  #   ( strcontains(var.default_image_tag_mutability, "_WITH_EXCLUSION" ) ? var.default_image_tag_mutability_exclusion_filter[*].filter : [] ))
  #   content {
  #     filter = each.value
  #     filter_type = "WILDCARD"
  #   }
  # }
  force_delete         = each.value.force_delete

  dynamic "encryption_configuration" {
    for_each = var.encryption_configuration == null ? [] : [var.encryption_configuration]
    content {
      encryption_type = encryption_configuration.value.encryption_type
      kms_key         = encryption_configuration.value.kms_key
    }
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

data "aws_iam_policy_document" "organizations_readonly_access" {
  count = module.this.enabled && length(var.organizations_readonly_access) > 0 ? 1 : 0

  statement {
    sid    = "OrganizationsReadonlyAccess"
    effect = "Allow"

    principals {
      identifiers = ["*"]
      type        = "*"
    }

    condition {
      test     = "StringEquals"
      values   = var.organizations_readonly_access
      variable = "aws:PrincipalOrgID"
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

data "aws_iam_policy_document" "organization_full_access" {
  count = module.this.enabled && length(var.organizations_full_access) > 0 ? 1 : 0

  statement {
    sid    = "OrganizationsFullAccess"
    effect = "Allow"

    principals {
      identifiers = ["*"]
      type        = "*"
    }

    condition {
      test     = "StringEquals"
      values   = var.organizations_full_access
      variable = "aws:PrincipalOrgID"
    }

    actions = [
      "ecr:*",
    ]
  }
}

data "aws_iam_policy_document" "organization_push_access" {
  count = module.this.enabled && length(var.organizations_push_access) > 0 ? 1 : 0

  statement {
    sid    = "OrganizationsPushAccess"
    effect = "Allow"

    principals {
      identifiers = ["*"]
      type        = "*"
    }

    condition {
      test     = "StringEquals"
      values   = var.organizations_push_access
      variable = "aws:PrincipalOrgID"
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

data "aws_iam_policy_document" "resource" {
  for_each = toset(local.ecr_need_policy && module.this.enabled ? local.image_names : [])
  source_policy_documents = local.principals_readonly_access_non_empty ? [
    data.aws_iam_policy_document.resource_readonly_access[0].json
  ] : [data.aws_iam_policy_document.empty[0].json]
  override_policy_documents = distinct([
    local.principals_pullthrough_access_non_empty && contains(var.prefixes_pullthrough_repositories, regex("^[a-z][a-z0-9\\-\\.\\_]+", each.value)) ? data.aws_iam_policy_document.resource_pullthrough_cache[0].json : data.aws_iam_policy_document.empty[0].json,
    local.principals_push_access_non_empty ? data.aws_iam_policy_document.resource_push_access[0].json : data.aws_iam_policy_document.empty[0].json,
    local.principals_full_access_non_empty ? data.aws_iam_policy_document.resource_full_access[0].json : data.aws_iam_policy_document.empty[0].json,
    local.principals_lambda_non_empty ? data.aws_iam_policy_document.lambda_access[0].json : data.aws_iam_policy_document.empty[0].json,
    local.organizations_full_access_non_empty ? data.aws_iam_policy_document.organization_full_access[0].json : data.aws_iam_policy_document.empty[0].json,
    local.organizations_readonly_access_non_empty ? data.aws_iam_policy_document.organizations_readonly_access[0].json : data.aws_iam_policy_document.empty[0].json,
    local.organizations_push_non_empty ? data.aws_iam_policy_document.organization_push_access[0].json : data.aws_iam_policy_document.empty[0].json
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

# resource "aws_ecr_replication_configuration" "replication_configuration" {
#   count = module.this.enabled && length(var.replication_configurations) > 0 ? 1 : 0
#   dynamic "replication_configuration" {
#     for_each = var.replication_configurations
#     content {
#       dynamic "rule" {
#         for_each = replication_configuration.value.rules
#         content {
#           dynamic "destination" {
#             for_each = rule.value.destinations
#             content {
#               region      = destination.value.region
#               registry_id = destination.value.registry_id
#             }
#           }
#           dynamic "repository_filter" {
#             for_each = rule.value.repository_filters
#             content {
#               filter      = repository_filter.value.filter
#               filter_type = repository_filter.value.filter_type
#             }
#           }
#         }
#       }
#     }
#   }
# }

# locals {
# # Check if any custom rule has tagStatus = "untagged"
#   has_custom_untagged_rule = length([
#     for rule in var.custom_lifecycle_rules : rule
#     if try(rule.selection.tagStatus, "") == "untagged"
#   ]) > 0

#   # Only include the default untagged rule if no custom untagged rule exists
#   final_untagged_image_rule = local.has_custom_untagged_rule ? [] : local.untagged_image_rule

#   # Prepare all rules that will be included in the policy before assigning priorities
#   all_lifecycle_rules = concat(
#     local.protected_tag_rules,
#     local.final_untagged_image_rule,
#     local.remove_old_image_rule,
#     var.custom_lifecycle_rules
#   )
#   any_tag_status_rules = [
#     for rule in local.all_lifecycle_rules : rule
#     if try(rule.selection.tagStatus, "") == "any"
#   ]
#   other_tag_status_rules = [
#     for rule in local.all_lifecycle_rules : rule
#     if try(rule.selection.tagStatus, "") != "any"
#   ]
#   # when we prioritize rules, we want to ensure that any tag status rules come last (e.g. lower priority)
#   sorted_lifecycle_rules = concat(local.other_tag_status_rules, local.any_tag_status_rules)

#   normalized_rules = [
#     for i, rule in local.sorted_lifecycle_rules : merge(
#       rule,
#       {
#         rulePriority = i + 1
#         selection = merge(
#           {
#             for k, v in rule.selection :
#             k => v
#             if !contains(["tagPrefixList", "tagPatternList", "countUnit"], k) || v != null
#           },
#           length(coalesce(lookup(rule.selection, "tagPrefixList", null), [])) > 0
#           ? { tagPrefixList = coalesce(lookup(rule.selection, "tagPrefixList", null), []) }
#           : {},
#           length(coalesce(lookup(rule.selection, "tagPatternList", null), [])) > 0
#           ? { tagPatternList = coalesce(lookup(rule.selection, "tagPatternList", null), []) }
#           : {},
#           try(rule.selection.countUnit, null) != null
#           ? { countUnit = rule.selection.countUnit }
#           : {}
#         )
#       }
#     )
#   ]

#   lifecycle_policy = jsonencode({
#     rules = [for rule in local.normalized_rules : rule]
#   })
#   default_lifecycle_rules_json = jsonencode({
#     rules = [for rule in var.default_lifecycle_rules : rule]
#   })
# }

# variable "custom_lifecycle_rules" {
#   description = "Custom lifecycle rules to override or complement the default ones. Action type can be 'expire' or 'transition'. Use 'transition' with targetStorageClass='archive' to archive images instead of deleting them. StorageClass can be 'standard' (default) or 'archive'."
#   type = list(object({
#     description = optional(string)
#     selection = object({
#       rulePriority   = number
#       tagStatus      = string
#       storageClass   = optional(string, "standard")
#       countType      = string
#       countNumber    = number
#       countUnit      = optional(string)
#       tagPrefixList  = optional(list(string))
#       tagPatternList = optional(list(string))
#     })
#     action = object({
#       type               = string
#       targetStorageClass = optional(string)
#     })
#   }))
#   default = []
# }