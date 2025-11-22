output "cosmosDbEndpoint" {
  value       = azurerm_cosmosdb_account.cosmos.endpoint
  description = "Cosmos DB account endpoint"
}

output "storageAccountName" {
  value       = azapi_resource.storage.name
  description = "Storage account name"
}

output "searchServiceName" {
  value       = azurerm_search_service.search.name
  description = "Azure AI Search service name"
}

output "container_registry_name" {
  value       = azurerm_container_registry.acr.name
  description = "Azure Container Registry name"
}

output "application_name" {
  value       = azurerm_linux_web_app.app.name
  description = "App Service name"
}

output "application_url" {
  value       = azurerm_linux_web_app.app.default_hostname
  description = "Primary host name for the App Service"
}

output "ai_foundry_name" {
  value       = local.ai_foundry_name
  description = "Azure AI Foundry account name"
}

output "ai_project_name" {
  value       = local.ai_project_name
  description = "Azure AI Foundry project name"
}

output "resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "Resource group name"
}

output "subscription_id" {
  value       = data.azurerm_client_config.current.subscription_id
  description = "Azure subscription ID"
}

output "application_insights_connection_string" {
  value       = azurerm_application_insights.appinsights.connection_string
  description = "Application Insights connection string"
  sensitive   = true
}

output "cosmos_db_name" {
  value       = local.cosmos_db_name
  description = "Cosmos DB database name"
}

output "ai_foundry_endpoint" {
  value       = "https://${local.ai_foundry_name}.cognitiveservices.azure.com/"
  description = "Azure AI Foundry endpoint URL"
}

output "deployed_models" {
  value = var.enable_ai_automation ? [
    "gpt-4o-mini",
    "text-embedding-3-small"
  ] : []
  description = "List of AI models actually deployed (phi-4 not available in this region)"
}

output "env_file_location" {
  value       = var.enable_ai_automation ? "../src/.env" : "Not created (AI automation disabled)"
  description = "Location of the generated .env file"
}
