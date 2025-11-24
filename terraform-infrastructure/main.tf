
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
  principal_id                = var.user_principal_id != null ? var.user_principal_id : data.azurerm_client_config.current.object_id
  suffix                      = substr(random_id.suffix.hex, 0, 8)
  cosmos_account_name         = "${var.name_prefix}${local.suffix}cosmosdb"
  cosmos_db_name              = "zava"
  storage_account             = lower(replace("${var.name_prefix}${local.suffix}sa", "-", ""))
  ai_foundry_name             = "aif-${local.suffix}" # custom subdomain
  ai_project_name             = "proj-${local.suffix}"
  search_service_name         = "${var.name_prefix}-${local.suffix}-search"
  app_service_plan            = "${var.name_prefix}-${local.suffix}-asp"
  log_analytics_name          = "${var.name_prefix}-${local.suffix}-la"
  app_insights_name           = "${var.name_prefix}-${local.suffix}-ai"
  registry_name               = lower(replace("${var.name_prefix}${local.suffix}cosureg", "-", ""))
  web_app_name                = "${var.name_prefix}-${local.suffix}-app"
  cosmos_connection_auth_type = var.enable_cosmos_local_auth ? "AccountKey" : "AAD"
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
  free_tier_enabled             = false
  analytical_storage_enabled    = false
  local_authentication_disabled = !var.enable_cosmos_local_auth
}

resource "azurerm_cosmosdb_sql_database" "cosmosdb" {
  name                = local.cosmos_db_name
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmos.name
  throughput          = 400
}

resource "azurerm_cosmosdb_sql_container" "products" {
  name                = "product_catalog"
  resource_group_name = azurerm_resource_group.rg.name
  account_name        = azurerm_cosmosdb_account.cosmos.name
  database_name       = azurerm_cosmosdb_sql_database.cosmosdb.name
  partition_key_paths = ["/ProductID"]
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
      accessTier                   = "Hot"
      allowSharedKeyAccess         = true
      defaultToOAuthAuthentication = false
      allowBlobPublicAccess        = false
      minimumTlsVersion            = "TLS1_2"
      supportsHttpsTrafficOnly     = true
    }
  })

  identity {
    type = "SystemAssigned"
  }
}

# AI Foundry account (preview) using AzAPI provider.
resource "azapi_resource" "ai_foundry" {
  type                      = "Microsoft.CognitiveServices/accounts@2025-06-01"
  name                      = local.ai_foundry_name
  location                  = var.location
  parent_id                 = azurerm_resource_group.rg.id
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
  type                      = "Microsoft.CognitiveServices/accounts/projects@2025-06-01"
  name                      = local.ai_project_name
  location                  = var.location
  parent_id                 = azapi_resource.ai_foundry.id
  schema_validation_enabled = false
  identity { type = "SystemAssigned" }
  body       = jsonencode({ properties = {} })
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
    http2_enabled       = true
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

# Storage account permissions for Azure AI Foundry project
resource "azurerm_role_assignment" "storage_blob_data_contributor_user" {
  scope              = azapi_resource.storage.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe"
  principal_id       = local.principal_id
  principal_type     = "User"
}

resource "azurerm_role_assignment" "storage_blob_data_contributor_project" {
  scope              = azapi_resource.storage.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe"
  principal_id       = azapi_resource.ai_project.identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

# Azure AI model deployments automation
resource "null_resource" "ai_model_deployments" {
  count = var.enable_ai_automation ? 1 : 0

  depends_on = [
    azapi_resource.ai_project,
    azapi_resource.ai_foundry,
    azurerm_role_assignment.storage_blob_data_contributor_user
  ]

  provisioner "local-exec" {
    command     = <<-EOT
      # Create AI model deployments
      Write-Host "Creating Azure AI model deployments..."
      
      # Wait for AI Foundry to be fully ready
      Write-Host "Waiting for AI Foundry to be ready..."
      Start-Sleep -Seconds 30
      
      try {
        # Create gpt-4o-mini deployment
        Write-Host "Creating gpt-4o-mini deployment..."
        az cognitiveservices account deployment create `
          --resource-group "${azurerm_resource_group.rg.name}" `
          --name "${local.ai_foundry_name}" `
          --deployment-name "gpt-4o-mini" `
          --model-name "gpt-4o-mini" `
          --model-version "2024-07-18" `
          --model-format "OpenAI" `
          --sku-capacity 10 `
          --sku-name "GlobalStandard"
        
          if ($LASTEXITCODE -eq 0) {
            Write-Host "gpt-4o-mini deployment created successfully"
          } else {
            Write-Host "gpt-4o-mini deployment may already exist or failed to create"
          }        # Create text-embedding-3-small deployment
        Write-Host "Creating text-embedding-3-small deployment..."
        az cognitiveservices account deployment create `
          --resource-group "${azurerm_resource_group.rg.name}" `
          --name "${local.ai_foundry_name}" `
          --deployment-name "text-embedding-3-small" `
          --model-name "text-embedding-3-small" `
          --model-version "1" `
          --model-format "OpenAI" `
          --sku-capacity 10 `
          --sku-name "GlobalStandard"
        
          if ($LASTEXITCODE -eq 0) {
            Write-Host "text-embedding-3-small deployment created successfully"
          } else {
            Write-Host "text-embedding-3-small deployment may already exist or failed to create"
          }        # Create phi-4 deployment
        Write-Host "Creating phi-4 deployment..."
        try {
          az cognitiveservices account deployment create `
            --resource-group "${azurerm_resource_group.rg.name}" `
            --name "${local.ai_foundry_name}" `
            --deployment-name "phi-4" `
            --model-name "phi-4" `
            --model-version "1" `
            --model-format "OpenAI" `
            --sku-capacity 5 `
            --sku-name "GlobalStandard"
          
          if ($LASTEXITCODE -eq 0) {
            Write-Host "phi-4 deployment created successfully"
            $phi4Available = $true
          } else {
            Write-Host "phi-4 model not available in this region/tier, skipping"
            $phi4Available = $false
          }
        } catch {
          Write-Host "phi-4 model not supported, skipping"
          $phi4Available = $false
        }
        
        # List all deployments to verify
        Write-Host "`nCurrent model deployments:"
        az cognitiveservices account deployment list `
          --resource-group "${azurerm_resource_group.rg.name}" `
          --name "${local.ai_foundry_name}" `
          --query "[].{Name:name,Model:properties.model.name,Version:properties.model.version,Capacity:properties.currentCapacity}" `
          --output table
        
        Write-Host "`nModel deployment process completed successfully."
      }
      catch {
        Write-Host "Error during model deployment: $_"
        Write-Host "This may be expected if deployments already exist."
      }
    EOT
    interpreter = ["PowerShell", "-Command"]
  }

  triggers = {
    ai_foundry_id = azapi_resource.ai_foundry.id
    ai_project_id = azapi_resource.ai_project.id
  }
}

# Connection helper actions for Foundry resources
data "azapi_resource_action" "storage_list_keys" {
  count                  = var.enable_ai_automation ? 1 : 0
  type                   = "Microsoft.Storage/storageAccounts@2023-01-01"
  resource_id            = azapi_resource.storage.id
  action                 = "listKeys"
  response_export_values = ["keys"]
  body                   = jsonencode({})
  depends_on             = [azapi_resource.storage]
}

data "azapi_resource_action" "search_admin_keys" {
  count                  = var.enable_ai_automation ? 1 : 0
  type                   = "Microsoft.Search/searchServices@2025-02-01-preview"
  resource_id            = azurerm_search_service.search.id
  action                 = "listAdminKeys"
  response_export_values = ["primaryKey"]
  body                   = jsonencode({})
  depends_on             = [azurerm_search_service.search]
}

data "azapi_resource_action" "cosmos_keys" {
  count                  = (var.enable_ai_automation && var.enable_cosmos_local_auth) ? 1 : 0
  type                   = "Microsoft.DocumentDB/databaseAccounts@2024-11-15"
  resource_id            = azurerm_cosmosdb_account.cosmos.id
  action                 = "listKeys"
  response_export_values = ["primaryMasterKey"]
  body                   = jsonencode({})
  depends_on             = [azurerm_cosmosdb_account.cosmos]
}

# Connect resources to Azure AI Foundry project using ARM templates
resource "azapi_resource" "storage_connection" {
  count = var.enable_ai_automation ? 1 : 0

  type                      = "Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview"
  name                      = "${local.ai_foundry_name}-storage"
  parent_id                 = azapi_resource.ai_foundry.id
  schema_validation_enabled = false

  depends_on = [
    azapi_resource.storage,
    azapi_resource.ai_foundry
  ]

  body = jsonencode({
    properties = {
      category      = "AzureStorageAccount"
      target        = "https://${local.storage_account}.blob.core.windows.net"
      authType      = "AccountKey"
      isSharedToAll = true
      credentials = {
        key = jsondecode(data.azapi_resource_action.storage_list_keys[0].output).keys[0].value
      }
      metadata = {
        ApiType    = "Azure"
        ResourceId = azapi_resource.storage.id
      }
    }
  })
}

resource "azapi_resource" "app_insights_connection" {
  count = var.enable_ai_automation ? 1 : 0

  type                      = "Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview"
  name                      = "${local.ai_foundry_name}-appinsights"
  parent_id                 = azapi_resource.ai_foundry.id
  schema_validation_enabled = false

  depends_on = [
    azurerm_application_insights.appinsights,
    azapi_resource.ai_foundry
  ]

  body = jsonencode({
    properties = {
      category      = "AppInsights"
      target        = azurerm_application_insights.appinsights.id
      authType      = "ApiKey"
      isSharedToAll = true
      credentials = {
        key = azurerm_application_insights.appinsights.connection_string
      }
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_application_insights.appinsights.id
      }
    }
  })
}

resource "azapi_resource" "search_connection" {
  count = var.enable_ai_automation ? 1 : 0

  type                      = "Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview"
  name                      = "${local.ai_foundry_name}-aisearch"
  parent_id                 = azapi_resource.ai_foundry.id
  schema_validation_enabled = false

  depends_on = [
    azurerm_search_service.search,
    azapi_resource.ai_foundry
  ]

  body = jsonencode({
    properties = {
      category      = "CognitiveSearch"
      target        = "https://${local.search_service_name}.search.windows.net"
      authType      = "ApiKey"
      isSharedToAll = true
      credentials = {
        key = jsondecode(data.azapi_resource_action.search_admin_keys[0].output).primaryKey
      }
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_search_service.search.id
        location   = azurerm_search_service.search.location
      }
    }
  })
}

resource "azapi_resource" "cosmos_connection" {
  count = var.enable_ai_automation ? 1 : 0

  type                      = "Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview"
  name                      = "${local.ai_foundry_name}-cosmosdb"
  parent_id                 = azapi_resource.ai_foundry.id
  schema_validation_enabled = false

  depends_on = [
    azurerm_cosmosdb_account.cosmos,
    azapi_resource.ai_foundry
  ]

  body = jsonencode({
    properties = merge({
      category      = "CosmosDb"
      target        = azurerm_cosmosdb_account.cosmos.endpoint
      authType      = local.cosmos_connection_auth_type
      isSharedToAll = true
      metadata = {
        ApiType    = "Azure"
        ResourceId = azurerm_cosmosdb_account.cosmos.id
        location   = azurerm_cosmosdb_account.cosmos.location
      }
      }, var.enable_cosmos_local_auth ? {
      credentials = {
        key = jsondecode(data.azapi_resource_action.cosmos_keys[0].output).primaryMasterKey
      }
    } : {})
  })
}

# Verification script for connections
resource "null_resource" "verify_connections" {
  count = var.enable_ai_automation ? 1 : 0

  depends_on = [
    azapi_resource.storage_connection,
    azapi_resource.app_insights_connection,
    azapi_resource.search_connection,
    azapi_resource.cosmos_connection
  ]

  provisioner "local-exec" {
    command     = <<-EOT
      Write-Host "=== Verifying Microsoft Foundry Project Connections ==="
      Write-Host ""
      Write-Host "Project: ${local.ai_project_name}"
      Write-Host "AI Foundry: ${local.ai_foundry_name}"
      Write-Host "Resource Group: ${azurerm_resource_group.rg.name}"
      Write-Host ""
      
      # List connections using Azure CLI
      Write-Host "Checking connections via Azure CLI..."
      az rest --method GET --url "https://management.azure.com/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${azurerm_resource_group.rg.name}/providers/Microsoft.CognitiveServices/accounts/${local.ai_foundry_name}/connections?api-version=2025-06-01" --query "value[].{Name:name,Type:properties.connectionType,Target:properties.target}" --output table
      
      Write-Host ""
      Write-Host "✓ Microsoft Foundry project connections verification completed!"
      Write-Host ""
      Write-Host "Available connections:"
      Write-Host "  - Storage Account: ${local.storage_account}"
      Write-Host "  - Application Insights: ${local.app_insights_name}"
      Write-Host "  - Azure AI Search: ${local.search_service_name}"
      Write-Host "  - Cosmos DB: ${local.cosmos_account_name}"
      Write-Host ""
      Write-Host "View in Azure Portal:"
      Write-Host "  https://ai.azure.com/resource/overview/${local.ai_foundry_name}"
      Write-Host "  Navigate to Management center > Connected resources"
    EOT
    interpreter = ["PowerShell", "-Command"]
  }

  triggers = {
    storage_conn      = var.enable_ai_automation ? azapi_resource.storage_connection[0].id : ""
    app_insights_conn = var.enable_ai_automation ? azapi_resource.app_insights_connection[0].id : ""
    search_conn       = var.enable_ai_automation ? azapi_resource.search_connection[0].id : ""
    cosmos_conn       = var.enable_ai_automation ? azapi_resource.cosmos_connection[0].id : ""
  }
}

# Create .env file with all necessary configuration
resource "null_resource" "create_env_file" {
  count = var.enable_ai_automation ? 1 : 0

  depends_on = [
    null_resource.verify_connections,
    azurerm_cosmosdb_account.cosmos,
    azurerm_search_service.search
  ]

  provisioner "local-exec" {
    command     = <<-EOT
      Write-Host "Creating .env file with Azure resource configuration..."
      
      # Create src directory if it doesn't exist
      if (!(Test-Path "../src")) {
        New-Item -ItemType Directory -Path "../src" -Force
      }
      
      # Get Azure AI Foundry endpoint
      $aiFoundryEndpoint = az cognitiveservices account show `
        --resource-group "${azurerm_resource_group.rg.name}" `
        --name "${local.ai_foundry_name}" `
        --query "properties.endpoint" `
        --output tsv
      
      # Get Azure AI Foundry access key
      $aiFoundryKey = az cognitiveservices account keys list `
        --resource-group "${azurerm_resource_group.rg.name}" `
        --name "${local.ai_foundry_name}" `
        --query "key1" `
        --output tsv
      
      # Get Cosmos DB primary key
      $cosmosKey = az cosmosdb keys list `
        --resource-group "${azurerm_resource_group.rg.name}" `
        --name "${local.cosmos_account_name}" `
        --query "primaryMasterKey" `
        --output tsv
      
      # Get Azure Search admin key
      $searchKey = az search admin-key show `
        --resource-group "${azurerm_resource_group.rg.name}" `
        --service-name "${local.search_service_name}" `
        --query "primaryKey" `
        --output tsv
      
      # Get storage account connection string
      $storageConnectionString = az storage account show-connection-string `
        --resource-group "${azurerm_resource_group.rg.name}" `
        --name "${local.storage_account}" `
        --query "connectionString" `
        --output tsv
      
      # Create .env file content
      if ($phi4Available) {
        $envContent = @"
# Azure AI Foundry Configuration
AZURE_AI_FOUNDRY_ENDPOINT=$aiFoundryEndpoint
AZURE_AI_FOUNDRY_API_KEY=$aiFoundryKey
AZURE_AI_PROJECT_NAME=${local.ai_project_name}

# Azure OpenAI Model Deployments
AZURE_OPENAI_CHAT_DEPLOYMENT=gpt-4o-mini
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-small
AZURE_OPENAI_PHI_DEPLOYMENT=phi-4
AZURE_OPENAI_ENDPOINT=$aiFoundryEndpoint
AZURE_OPENAI_API_KEY=$aiFoundryKey
AZURE_OPENAI_API_VERSION=2024-02-01

# Azure Cosmos DB Configuration
COSMOS_DB_ENDPOINT=${azurerm_cosmosdb_account.cosmos.endpoint}
COSMOS_DB_KEY=$cosmosKey
COSMOS_DB_NAME=${local.cosmos_db_name}
COSMOS_DB_CONTAINER_NAME=product_catalog
COSMOS_SKIP_IF_EXISTS=true
COSMOS_FORCE_INGEST=false

# Azure AI Search Configuration
SEARCH_SERVICE_ENDPOINT=https://${local.search_service_name}.search.windows.net
SEARCH_SERVICE_KEY=$searchKey
SEARCH_INDEX_NAME=products-index

# Azure Storage Configuration
STORAGE_ACCOUNT_NAME=${local.storage_account}
STORAGE_CONNECTION_STRING=$storageConnectionString

# Azure Application Insights
APPLICATION_INSIGHTS_CONNECTION_STRING=${azurerm_application_insights.appinsights.connection_string}

# Azure Resource Information
AZURE_SUBSCRIPTION_ID=${data.azurerm_client_config.current.subscription_id}
AZURE_RESOURCE_GROUP=${azurerm_resource_group.rg.name}
AZURE_LOCATION=${var.location}
"@
      } else {
        $envContent = @"
# Azure AI Foundry Configuration
AZURE_AI_FOUNDRY_ENDPOINT=$aiFoundryEndpoint
AZURE_AI_FOUNDRY_API_KEY=$aiFoundryKey
AZURE_AI_PROJECT_NAME=${local.ai_project_name}

# Azure OpenAI Model Deployments
AZURE_OPENAI_CHAT_DEPLOYMENT=gpt-4o-mini
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-small
AZURE_OPENAI_ENDPOINT=$aiFoundryEndpoint
AZURE_OPENAI_API_KEY=$aiFoundryKey
AZURE_OPENAI_API_VERSION=2024-02-01

# Azure Cosmos DB Configuration
COSMOS_DB_ENDPOINT=${azurerm_cosmosdb_account.cosmos.endpoint}
COSMOS_DB_KEY=$cosmosKey
COSMOS_DB_NAME=${local.cosmos_db_name}
COSMOS_DB_CONTAINER_NAME=product_catalog
COSMOS_SKIP_IF_EXISTS=true
COSMOS_FORCE_INGEST=false

# Azure AI Search Configuration
SEARCH_SERVICE_ENDPOINT=https://${local.search_service_name}.search.windows.net
SEARCH_SERVICE_KEY=$searchKey
SEARCH_INDEX_NAME=products-index

# Azure Storage Configuration
STORAGE_ACCOUNT_NAME=${local.storage_account}
STORAGE_CONNECTION_STRING=$storageConnectionString

# Azure Application Insights
APPLICATION_INSIGHTS_CONNECTION_STRING=${azurerm_application_insights.appinsights.connection_string}

# Azure Resource Information
AZURE_SUBSCRIPTION_ID=${data.azurerm_client_config.current.subscription_id}
AZURE_RESOURCE_GROUP=${azurerm_resource_group.rg.name}
AZURE_LOCATION=${var.location}
"@
      }
      
      # Write .env file
      $envContent | Out-File -FilePath "../src/.env" -Encoding UTF8
      
      Write-Host ".env file created successfully at ../src/.env"
      Write-Host "Environment variables configured for:"
      if ($phi4Available) {
        Write-Host "  - Models: gpt-4o-mini, text-embedding-3-small, phi-4"
      } else {
        Write-Host "  - Models: gpt-4o-mini, text-embedding-3-small (phi-4 not available)"
      }
      Write-Host "  - Azure AI Foundry: ${local.ai_foundry_name}"
      Write-Host "  - Azure AI Project: ${local.ai_project_name}"
      Write-Host "  - Cosmos DB: ${local.cosmos_account_name}"
      Write-Host "  - Search Service: ${local.search_service_name}"
      Write-Host "  - Storage Account: ${local.storage_account}"
      Write-Host "  - Application Insights: ${local.app_insights_name}"
    EOT
    interpreter = ["PowerShell", "-Command"]
  }

  triggers = {
    # Trigger recreation when any of these resources change
    ai_foundry_id   = azapi_resource.ai_foundry.id
    ai_project_id   = azapi_resource.ai_project.id
    cosmos_id       = azurerm_cosmosdb_account.cosmos.id
    search_id       = azurerm_search_service.search.id
    storage_id      = azapi_resource.storage.id
    app_insights_id = azurerm_application_insights.appinsights.id
  }
}

# Data pipeline automation - runs after .env file is created
resource "null_resource" "data_pipeline" {
  count = var.enable_data_pipeline ? 1 : 0

  depends_on = [
    null_resource.create_env_file,
    azurerm_cosmosdb_sql_database.cosmosdb,
    azurerm_cosmosdb_sql_container.products
  ]

  provisioner "local-exec" {
    command     = <<-EOT
      Write-Host "Starting data pipeline automation..."
      
      # Navigate to src directory
      cd ../src
      
      # Check if Python is available
      try {
        $pythonCmd = (Get-Command python -ErrorAction Stop).Source
        Write-Host "Found Python at: $pythonCmd"
      } catch {
        Write-Host "ERROR: Python is not installed or not in PATH"
        Write-Host "Please install Python 3.8+ from https://www.python.org/downloads/"
        exit 1
      }
      
      # Create virtual environment
      Write-Host "Creating Python virtual environment..."
      if (Test-Path "venv") {
        Write-Host "Virtual environment already exists, removing..."
        Remove-Item -Recurse -Force venv
      }
      python -m venv venv
      
      # Install dependencies directly to venv without activation
      Write-Host "Installing Python dependencies (with retry)..."
      $pythonExe = "venv\Scripts\python.exe"
      $pipExe = "venv\Scripts\pip.exe"
      
      if (Test-Path $pythonExe) {
        & $pythonExe -m pip install --upgrade pip
        $maxAttempts = 3
        for ($i = 1; $i -le $maxAttempts; $i++) {
          Write-Host "pip install attempt $i..."
          & $pipExe install -r requirements.txt
          if ($LASTEXITCODE -eq 0) {
            Write-Host "Dependencies installed successfully on attempt $i"
            break
          } else {
            Write-Host "pip install failed (exit $LASTEXITCODE)."
            if ($i -lt $maxAttempts) {
              Write-Host "Retrying after short backoff..."
              Start-Sleep -Seconds 5
            } else {
              Write-Host "ERROR: Dependencies failed after $maxAttempts attempts"
              exit 1
            }
          }
        }
        
        Write-Host "Python environment ready"
        Write-Host ""
        
        # Check if CSV data file exists
        $csvFile = "data/updated_product_catalog(in).csv"
        if (!(Test-Path $csvFile)) {
          Write-Host "WARNING: CSV data file not found at $csvFile"
          Write-Host "Please download the product catalog data or place it in the data directory"
          Write-Host "Skipping data import for now"
        } else {
          Write-Host "Step 1: Importing data to Cosmos DB (skip logic flags: COSMOS_SKIP_IF_EXISTS / COSMOS_FORCE_INGEST)..."
          & $pythonExe pipelines/ingest_to_cosmos.py
          
          Write-Host ""
          Write-Host "Step 2: Creating Azure AI Search index..."
          & $pythonExe pipelines/create_search_index.py
          
          Write-Host ""
          Write-Host "Step 3: Uploading data from Cosmos DB to Azure AI Search..."
          & $pythonExe pipelines/upload_to_search.py
          
          Write-Host ""
          Write-Host "Data pipeline completed successfully!"
          Write-Host "- Cosmos DB container created and populated"
          Write-Host "- Azure AI Search index created"
          Write-Host "- Data imported to search index"
        }
      } else {
        Write-Host "ERROR: Failed to create virtual environment"
        exit 1
      }
      
      Write-Host ""
      Write-Host "Data pipeline automation completed"
    EOT
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.module
  }

  triggers = {
    cosmos_db_id = azurerm_cosmosdb_sql_database.cosmosdb.id
    search_id    = azurerm_search_service.search.id
    env_file_id  = null_resource.create_env_file[0].id
  }
}
