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
    values(aws_ecr_repository.name)[*].arn
  ) : {}
  description = "Map of repository names to repository ARNs"
}