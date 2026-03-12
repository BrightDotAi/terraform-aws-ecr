variable "use_fullname" {
  type        = bool
  default     = false
  description = "Set 'true' to use `namespace-stage-name` for ecr repository name, else `name`"
}

variable "principals_full_access" {
  type        = list(string)
  description = "Principal ARNs to provide with full access to the ECR"
  default     = []
}

variable "principals_push_access" {
  type        = list(string)
  description = "Principal ARNs to provide with push access to the ECR"
  default     = []
}

variable "principals_readonly_access" {
  type        = list(string)
  description = "Principal ARNs to provide with readonly access to the ECR"
  default     = []
}

variable "principals_pull_though_access" {
  type        = list(string)
  description = "Principal ARNs to provide with pull though access to the ECR"
  default     = []
}

variable "scan_images_on_push" {
  type        = bool
  description = "Indicates whether images are scanned after being pushed to the repository (true) or not (false)"
  default     = true
}

variable "principals_lambda" {
  type        = list(string)
  description = "Principal account IDs of Lambdas allowed to consume ECR"
  default     = []
}

variable "scan_images_on_push" {
 type        = bool
 description = "Indicates whether images are scanned after being pushed to the repository (true) or not (false)"
 default     = true
}

variable "repositories" {
  type        = map(object({
    force_delete = optional(bool, false)
    image_tag_mutability = optional(string) #May be one of: `MUTABLE`, `IMMUTABLE`, `IMMUTABLE_WITH_EXCLUSION`, or `MUTABLE_WITH_EXCLUSION`. Defaults to `IMMUTABLE`"
    image_tag_mutability_exclusion_filter = optional(list(object({
      filter      = string
      filter_type = optional(string, "WILDCARD")
    })), [])
    lifecycle_rules_override = optional(list(object({
      description = optional(string)
      rulePriority   = number
      selection = object({
        tagStatus      = string
        storageClass   = optional(string, "standard")
        countType      = string
        countNumber    = number
        countUnit      = optional(string)
        tagPrefixList  = optional(list(string))
        tagPatternList = optional(list(string))
      })
      action = object({
        type               = string
        targetStorageClass = optional(string)
      })
    })))
  }))
  description = "Map of Docker local image names, used as repository names for AWS ECR. Sets `force_delete` option"
}

variable "default_image_tag_mutability" {
  type        = string
  default     = "MUTABLE"
  description = "The tag mutability setting for all repository. Must be one of: `MUTABLE`, `IMMUTABLE`, `IMMUTABLE_WITH_EXCLUSION`, or `MUTABLE_WITH_EXCLUSION`. Defaults to `IMMUTABLE`"
}

variable "default_image_tag_mutability_exclusion_filter" {
  type = list(object({
    filter      = string
    filter_type = optional(string, "WILDCARD")
  }))
  default     = []
  description = "List of exclusion filters for image tag mutability. Each filter object must contain 'filter' and 'filter_type' attributes. Requires AWS provider >= 6.8.0"

  validation {
    condition = alltrue([
      for filter in var.default_image_tag_mutability_exclusion_filter :
      contains(["WILDCARD"], filter.filter_type)
    ])
    error_message = "filter_type must be `WILDCARD`"
  }

  validation {
    condition = alltrue([
      for filter in var.default_image_tag_mutability_exclusion_filter :
      length(trimspace(filter.filter)) > 0
    ])
    error_message = "filter value cannot be empty or contain only whitespace."
  }
}

variable "encryption_configuration" {
  type = object({
    encryption_type = string
    kms_key         = any
  })
  description = "ECR encryption configuration"
  default     = null
}

variable "replication_regions" {
  type        = set(string)
  default     = []
  description = "List of destination regions in the same account for which to replicate ECR images to"
}

variable "prefixes_pullthrough_repositories" {
  type        = list(string)
  description = "Organization IDs to provide with push access to the ECR"
  default     = []
}

variable "repository_creation_enabled" {
  type        = bool
  description = "Whether ECR repositories should be created"
  default     = true
}

variable "pullthrough_repository_prefixes" {
  description = "image name prefixes that indicate the image is a pullthrough cache"
  type = list(string)
  default = []
}

variable "default_lifecycle_rules" {
  description = "Default rules that will apply to all repositories unless overridden by repository specific rules. Action type can be 'expire' or 'transition'. Use 'transition' with targetStorageClass='archive' to archive images instead of deleting them. StorageClass can be 'standard' (default) or 'archive'."
  type = list(object({
    description = optional(string)
    rulePriority   = number
    selection = object({
      tagStatus      = string
      storageClass   = optional(string, "standard")
      countType      = string
      countNumber    = number
      countUnit      = optional(string)
      tagPrefixList  = optional(list(string))
      tagPatternList = optional(list(string))
    })
    action = object({
      type               = string
      targetStorageClass = optional(string)
    })
  }))
  default = []
  validation {
    condition = alltrue([
      for rule in var.default_lifecycle_rules :
      rule.selection.tagStatus != "tagged" || (length(coalesce(rule.selection.tagPrefixList, [])) > 0 || length(coalesce(rule.selection.tagPatternList, [])) > 0)
    ])
    error_message = "if tagStatus is tagged - specify tagPrefixList or tagPatternList"
  }

  validation {
    condition = alltrue([
      for rule in var.default_lifecycle_rules :
      (length(coalesce(rule.selection.tagPrefixList, [])) == 0 || length(coalesce(rule.selection.tagPatternList, [])) == 0)
    ])
    error_message = "Cannot specify both tagPrefixList and tagPatternList in the same rule.  Separate them into multiple rules"
  }

  validation {
    condition = alltrue([
      for rule in var.default_lifecycle_rules :
      rule.selection.countNumber > 0
    ])
    error_message = "Count number should be > 0"
  }

  validation {
    condition = alltrue([
      for rule in var.default_lifecycle_rules :
      contains(["tagged", "untagged", "any"], rule.selection.tagStatus)
    ])
    error_message = "Valid values for tagStatus are: tagged, untagged, or any."
  }
  validation {
    condition = alltrue([
      for rule in var.default_lifecycle_rules :
      contains(["imageCountMoreThan", "sinceImagePushed"], rule.selection.countType)
    ])
    error_message = "Valid values for countType are: imageCountMoreThan or sinceImagePushed."
  }

  validation {
    condition = alltrue([
      for rule in var.default_lifecycle_rules :
      rule.selection.countType != "sinceImagePushed" || rule.selection.countUnit != null
    ])
    error_message = "For countType = 'sinceImagePushed', countUnit must be specified."
  }

  validation {
    condition = alltrue([
      for rule in var.default_lifecycle_rules :
      contains(["expire", "transition"], rule.action.type)
    ])
    error_message = "Valid values for action.type are: expire or transition."
  }

  validation {
    condition = alltrue([
      for rule in var.default_lifecycle_rules :
      rule.action.type != "transition" || rule.action.targetStorageClass != null
    ])
    error_message = "For action.type = 'transition', targetStorageClass must be specified."
  }

  validation {
    condition = alltrue([
      for rule in var.default_lifecycle_rules :
      contains(["standard", "archive"], rule.selection.storageClass)
    ])
    error_message = "Valid values for storageClass are: standard or archive. Defaults to standard."
  }

  validation {
    condition = alltrue([
      for rule in var.default_lifecycle_rules :
      rule.selection.tagPrefixList == null || alltrue([for prefix in rule.selection.tagPrefixList : can(regex("^[[:alnum:]\\-\\._]+$", prefix))])
    ])
    error_message = "Valid values for tagPrefixList matches may only contain alphanumeric characters, '.', '-', and '_'. If you are trying to use '*', use tagPatternList instead."
  }
}
