output "registry_ids" {
  value       = local.repository_creation_enabled ? distinct(values(aws_ecr_repository.name)[*].registry_id) : []
  description = "Registry ID"
}

output "repository_names" {
  value       = local.repository_creation_enabled ? distinct(values(aws_ecr_repository.name)[*].name) : []
  description = "Name of first repository created"
}

output "repository_urls" {
  value       = local.repository_creation_enabled ? distinct(values(aws_ecr_repository.name)[*].repository_url) : []
  description = "URL of first repository created"
}

output "repository_arns" {
  value       = local.repository_creation_enabled ? distinct(values(aws_ecr_repository.name)[*].arn) : []
  description = "ARN of first repository created"
}

output "repository_url_map" {
  value = local.repository_creation_enabled ? zipmap(
    values(aws_ecr_repository.name)[*].name,
    values(aws_ecr_repository.name)[*].repository_url
  ) : {}
  description = "Map of repository names to repository URLs"
}

output "repository_arn_map" {
  value = local.repository_creation_enabled ? zipmap(
    values(aws_ecr_repository.name)[*].name,
    [for k, v in zipmap(values(aws_ecr_repository.name)[*].arn, values(aws_ecr_repository.name)[*].repository_url) : {
      repository_arn = k
      repository_url = v
    }]
  ) : {}
  description = "Map of repository names to repository ARNs"
}

output "default_lifecycle_rules_json" {
  value = local.default_lifecycle_rules_json
  description = "debug output lifecycle rules json"
}

output "custom_lifecycle_rules_json" {
  value = local.custom_lifecycle_rules_json
  description = "debug output custom rules json"
}