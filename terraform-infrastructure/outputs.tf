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
