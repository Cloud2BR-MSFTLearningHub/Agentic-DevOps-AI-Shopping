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

# Real agent IDs & statuses (external data source from agents_state.json)
output "agent_ids" {
  value = {
    for k, v in data.external.agents_state.result :
    k => v if length(regexall("_id$", k)) > 0
  }
  description = "Map of agent environment variable names to their resolved IDs"
}

output "agent_statuses" {
  value = {
    for k, v in data.external.agents_state.result :
    k => v if length(regexall("_status$", k)) > 0
  }
  description = "Map of agent environment variable names to provisioning statuses (created/existing/updated/etc.)"
}

output "key_vault_name" {
  value       = azurerm_key_vault.kv.name
  description = "Name of the Key Vault used for secret storage"
}

output "key_vault_uri" {
  value       = azurerm_key_vault.kv.vault_uri
  description = "Base URI of the Key Vault"
}

# === Real Agent Outputs (ochartarotr) ===
# NOTE: Commented out - Azure Agents API not yet available via ARM/Terraform
# output "cora_agent_id" {
#   value       = azapi_resource.cora_agent.id
#   description = "Cora agent resource ID"
# }
# output "interior_design_agent_id" {
#   value       = azapi_resource.interior_design_agent.id
#   description = "Interior Designer agent resource ID"
# }
# output "inventory_agent_id" {
#   value       = azapi_resource.inventory_agent.id
#   description = "Inventory Manager agent resource ID"
# }
# output "customer_loyalty_agent_id" {
#   value       = azapi_resource.customer_loyalty_agent.id
#   description = "Customer Loyalty agent resource ID"
# }
# output "cart_manager_agent_id" {
#   value       = azapi_resource.cart_manager_agent.id
#   description = "Cart Manager agent resource ID"
# }

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

output "chat_application_url" {
  value       = "http://127.0.0.1:8000"
  description = "URL to access the Zava AI Shopping Assistant chat application"
}

output "chat_application_health" {
  value       = "http://127.0.0.1:8000/health"
  description = "Health check endpoint for the chat application"
}

output "application_instructions" {
  value = <<-EOT

  ============================================================================
  ZAVA AI SHOPPING ASSISTANT - DEPLOYMENT COMPLETE
  ============================================================================

  AZURE WEB APP:
    - App Name: ${azurerm_linux_web_app.app.name}
    - URL: https://${azurerm_linux_web_app.app.default_hostname}
    - Health Check: https://${azurerm_linux_web_app.app.default_hostname}/health

  LOCAL TESTING:
    - URL: http://127.0.0.1:8000
    - To run locally:
      cd ../src
      venv\Scripts\Activate.ps1
      uvicorn chat_app:app --host 0.0.0.0 --port 8000

  TEST PROMPTS:
    - "What colors of paint do you have available?"
    - "Tell me about lattices"
    - "Where can I find your store?"
    - "Do you have history books?" (tests scope limits)

  AZURE RESOURCES:
    - Resource Group: ${azurerm_resource_group.rg.name}
    - AI Foundry: ${local.ai_foundry_name}
    - Cosmos DB: ${local.cosmos_account_name}
    - Search Service: ${local.search_service_name}
    - Container Registry: ${local.registry_name}

  ============================================================================

  EOT
  description = "Deployment summary and usage instructions"
}
