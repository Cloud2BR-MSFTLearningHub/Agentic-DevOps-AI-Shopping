
# Create resource group if it does not exist
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# Subscription context for role assignments
data "azurerm_client_config" "current" {}

# Random suffix to mimic uniqueString(resourceGroup().id)
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  # Use provided user_principal_id or default to current Azure CLI user
  principal_id        = var.user_principal_id != null ? var.user_principal_id : data.azurerm_client_config.current.object_id
  suffix              = substr(random_id.suffix.hex, 0, 8)
  cosmos_account_name = "${var.name_prefix}${local.suffix}cosmosdb"
  cosmos_db_name      = "zava"
  storage_account     = lower(replace("${var.name_prefix}${local.suffix}sa", "-", ""))
  ai_foundry_name     = "aif-${local.suffix}"  # custom subdomain
  ai_project_name     = "proj-${local.suffix}"
  search_service_name = "${var.name_prefix}-${local.suffix}-search"
  app_service_plan    = "${var.name_prefix}-${local.suffix}-asp"
  log_analytics_name  = "${var.name_prefix}-${local.suffix}-la"
  app_insights_name   = "${var.name_prefix}-${local.suffix}-ai"
  registry_name       = lower(replace("${var.name_prefix}${local.suffix}cosureg", "-", ""))
  web_app_name        = "${var.name_prefix}-${local.suffix}-app"
}

resource "azurerm_cosmosdb_account" "cosmos" {
  name                = local.cosmos_account_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"
  consistency_policy {
    consistency_level       = "Session"
    max_interval_in_seconds = 5
    max_staleness_prefix    = 100
  }
  geo_location {
    location          = var.location
    failover_priority = 0
  }
  free_tier_enabled              = false
  analytical_storage_enabled     = false
  local_authentication_disabled  = !var.enable_cosmos_local_auth
}

resource "azurerm_cosmosdb_sql_database" "cosmosdb" {
  name                = local.cosmos_db_name
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmos.name
  throughput          = 400
}

# Storage account using AzAPI to bypass policy restrictions
resource "azapi_resource" "storage" {
  type      = "Microsoft.Storage/storageAccounts@2023-01-01"
  name      = local.storage_account
  location  = var.location
  parent_id = azurerm_resource_group.rg.id
  
  body = jsonencode({
    sku = {
      name = "Standard_LRS"
    }
    kind = "StorageV2"
    properties = {
      accessTier = "Hot"
      allowSharedKeyAccess = true
      defaultToOAuthAuthentication = false
      allowBlobPublicAccess = false
      minimumTlsVersion = "TLS1_2"
      supportsHttpsTrafficOnly = true
    }
  })
  
  identity {
    type = "SystemAssigned"
  }
}

# AI Foundry account (preview) using AzAPI provider.
resource "azapi_resource" "ai_foundry" {
  type      = "Microsoft.CognitiveServices/accounts@2025-06-01"
  name      = local.ai_foundry_name
  location  = var.location
  parent_id = azurerm_resource_group.rg.id
  schema_validation_enabled = false
  identity { type = "SystemAssigned" }
  body = jsonencode({
    sku  = { name = "S0" }
    kind = "AIServices"
    properties = {
      allowProjectManagement = true
      customSubDomainName    = local.ai_foundry_name
      disableLocalAuth       = false
    }
  })
}

resource "azapi_resource" "ai_project" {
  type      = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  name      = local.ai_project_name
  location  = var.location
  parent_id = azapi_resource.ai_foundry.id
  schema_validation_enabled = false
  identity { type = "SystemAssigned" }
  body = jsonencode({ properties = {} })
  depends_on = [azapi_resource.ai_foundry]
}

resource "azurerm_search_service" "search" {
  name                = local.search_service_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  sku                 = "standard"
  identity { type = "SystemAssigned" }
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = local.log_analytics_name
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 90
  daily_quota_gb      = 1
}

resource "azurerm_application_insights" "appinsights" {
  name                = local.app_insights_name
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.law.id
}

resource "azurerm_container_registry" "acr" {
  name                = local.registry_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  sku                 = "Standard"
  admin_enabled       = true
}

resource "azurerm_container_registry_webhook" "webhook" {
  name                = "${local.registry_name}webhook"
  resource_group_name = azurerm_resource_group.rg.name
  registry_name       = azurerm_container_registry.acr.name
  location            = var.location

  service_uri = "https://${local.web_app_name}.scm.azurewebsites.net/docker/hook"
  status      = "enabled"
  scope       = "${local.suffix}/techworkshopl300/zava:latest"
  actions     = ["push"]
  
  custom_headers = {
    "Content-Type" = "application/json"
  }

  depends_on = [azurerm_container_registry.acr]
}

resource "azurerm_service_plan" "appserviceplan" {
  name                = local.app_service_plan
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = "S1"
}

resource "azurerm_linux_web_app" "app" {
  name                = local.web_app_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  service_plan_id     = azurerm_service_plan.appserviceplan.id
  https_only          = true

  site_config {
    application_stack {
      docker_image_name   = "${local.registry_name}.azurecr.io/${local.suffix}/techworkshopl300/zava:latest"
      docker_registry_url = "https://${local.registry_name}.azurecr.io"
    }
    http2_enabled  = true
    minimum_tls_version = "1.2"
  }

  app_settings = {
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
    DOCKER_REGISTRY_SERVER_URL          = "https://${local.registry_name}.azurecr.io"
    DOCKER_REGISTRY_SERVER_USERNAME     = azurerm_container_registry.acr.name
    DOCKER_REGISTRY_SERVER_PASSWORD     = azurerm_container_registry.acr.admin_password
    APPINSIGHTS_INSTRUMENTATIONKEY      = azurerm_application_insights.appinsights.instrumentation_key
  }

  depends_on = [azurerm_container_registry.acr]
}

# Cosmos DB SQL Role Assignments (data plane) using AzAPI
locals {
  cosmos_db_data_reader_role_id      = "00000000-0000-0000-0000-000000000001"
  cosmos_db_data_contributor_role_id = "00000000-0000-0000-0000-000000000002"
  cosmos_account_reader_role_id      = "fbdf93bf-df7d-467e-a4d2-9458aa1360c8"
  cognitive_openai_user_role_id      = "5e0bd9bd-7b93-4f28-af87-19fc36ad61bd"
  cognitive_contributor_role_id      = "25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68"
}

# Assign Cosmos DB Built-in Data Contributor role to specified user principal
resource "azapi_resource" "cosmos_user_data_contributor" {
  type      = "Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-04-15"
  name      = md5("${azurerm_cosmosdb_account.cosmos.id}-${local.principal_id}-${local.cosmos_db_data_contributor_role_id}")
  parent_id = azurerm_cosmosdb_account.cosmos.id
  body = jsonencode({
    properties = {
      roleDefinitionId = "${azurerm_cosmosdb_account.cosmos.id}/sqlRoleDefinitions/${local.cosmos_db_data_contributor_role_id}"
      principalId      = local.principal_id
      scope            = azurerm_cosmosdb_account.cosmos.id
    }
  })
}

# Role assignments for Search managed identity
resource "azurerm_role_assignment" "search_cosmos_account_reader" {
  scope              = azurerm_cosmosdb_account.cosmos.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.cosmos_account_reader_role_id}"
  principal_id       = azurerm_search_service.search.identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azapi_resource" "search_cosmos_data_reader" {
  type      = "Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-04-15"
  name      = md5("${azurerm_cosmosdb_account.cosmos.id}-${azurerm_search_service.search.identity[0].principal_id}-${local.cosmos_db_data_reader_role_id}")
  parent_id = azurerm_cosmosdb_account.cosmos.id
  body = jsonencode({
    properties = {
      roleDefinitionId = "${azurerm_cosmosdb_account.cosmos.id}/sqlRoleDefinitions/${local.cosmos_db_data_reader_role_id}"
      principalId      = azurerm_search_service.search.identity[0].principal_id
      scope            = azurerm_cosmosdb_account.cosmos.id
    }
  })
}

resource "azapi_resource" "search_cosmos_data_contributor" {
  type      = "Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-04-15"
  name      = md5("${azurerm_cosmosdb_account.cosmos.id}-${azurerm_search_service.search.identity[0].principal_id}-${local.cosmos_db_data_contributor_role_id}")
  parent_id = azurerm_cosmosdb_account.cosmos.id
  body = jsonencode({
    properties = {
      roleDefinitionId = "${azurerm_cosmosdb_account.cosmos.id}/sqlRoleDefinitions/${local.cosmos_db_data_contributor_role_id}"
      principalId      = azurerm_search_service.search.identity[0].principal_id
      scope            = azurerm_cosmosdb_account.cosmos.id
    }
  })
}

# Role assignments for AI Project & AI Foundry
resource "azurerm_role_assignment" "search_project_openai_user" {
  scope              = azapi_resource.ai_project.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.cognitive_openai_user_role_id}"
  principal_id       = azurerm_search_service.search.identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "search_foundry_openai_user" {
  scope              = azapi_resource.ai_foundry.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.cognitive_openai_user_role_id}"
  principal_id       = azurerm_search_service.search.identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "search_project_contributor" {
  scope              = azapi_resource.ai_project.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.cognitive_contributor_role_id}"
  principal_id       = azurerm_search_service.search.identity[0].principal_id
  principal_type     = "ServicePrincipal"
}
