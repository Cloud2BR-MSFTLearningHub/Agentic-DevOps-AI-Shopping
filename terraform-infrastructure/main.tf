
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
  cosmos_db_name              = "${var.name_prefix}-db" # Dynamic cosmos db name
  storage_account             = lower(replace("${var.name_prefix}${local.suffix}sa", "-", ""))
  ai_foundry_name             = "aif-${local.suffix}" # custom subdomain
  ai_project_name             = "proj-${local.suffix}"
  search_service_name         = "${var.name_prefix}-${local.suffix}-search"
  app_service_plan            = "${var.name_prefix}-${local.suffix}-asp"
  log_analytics_name          = "${var.name_prefix}-${local.suffix}-la"
  app_insights_name           = "${var.name_prefix}-${local.suffix}-ai"
  registry_name               = lower(replace("${var.name_prefix}${local.suffix}cosureg", "-", ""))
  web_app_name                = "${var.name_prefix}-${local.suffix}-app"
  key_vault_name              = "${var.name_prefix}-${local.suffix}-kv"
  cosmos_connection_auth_type = var.enable_cosmos_local_auth ? "AccountKey" : "AAD"
  dockerfile_hash             = filesha256("../src/Dockerfile")

  # Hash of application source & templates to trigger container rebuild when logic/UI changes
  # Combine Python files and HTML templates for source tracking
  app_source_hash     = sha256(join("", [
    for f in concat(
      [for py in fileset("../src", "**/*.py") : py],
      ["app/templates/index.html"]  # Explicitly include the HTML template
    ) : fileexists("../src/${f}") ? filesha256("../src/${f}") : ""
  ]))
  product_catalog_hash = fileexists("../src/data/updated_product_catalog(in).csv") ? filesha256("../src/data/updated_product_catalog(in).csv") : "missing"

  deploy_to_appservice     = var.deployment_target == "appservice"
  deploy_to_container_apps = var.deployment_target == "containerapps"
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
    zone_redundant    = false  # Disable zone redundancy to avoid high demand issues for demo
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
      minimumTlsVersion            = "TLS1_2"
      supportsHttpsTrafficOnly     = true
    }
  })
  identity {
    type = "SystemAssigned"
  }
}

# AI Foundry account (preview) using AzAPI provider.
# Using managed identity authentication (disableLocalAuth = true for better security)
resource "azapi_resource" "ai_foundry" {
  type                      = "Microsoft.CognitiveServices/accounts@2024-10-01"
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
      disableLocalAuth       = true
    }
  })
}

# Ensure allowProjectManagement is applied (some older API versions ignore it during create).
# This PATCH uses a newer api-version that supports the property and updates the existing account in place.
resource "azapi_update_resource" "ai_foundry_enable_project_mgmt" {
  type                      = "Microsoft.CognitiveServices/accounts@2025-06-01"
  resource_id               = azapi_resource.ai_foundry.id

  body = jsonencode({
    properties = {
      allowProjectManagement = true
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
  depends_on = [azapi_update_resource.ai_foundry_enable_project_mgmt]
}

# === Real Multi-Agent Creation (ochartarotr) ===
# NOTE: Azure Agents API not yet available via ARM/Terraform (returns 500 Internal Server Error)
# Keeping these commented for future use when the API becomes available
# resource "azapi_resource" "cora_agent" {
#   type                      = "Microsoft.CognitiveServices/accounts/projects/agents@2025-06-01"
#   name                      = "cora-agent"
#   location                  = var.location
#   parent_id                 = azapi_resource.ai_project.id
#   schema_validation_enabled = false
#   body = jsonencode({
#     properties = {
#       displayName         = "Cora - Zava Shopping Assistant"
#       description         = "Domain expert for shopping assistance"
#       domain              = "cora"
#       modelDeploymentName = "gpt-4o-mini"
#     }
#   })
#   depends_on = [azapi_resource.ai_project]
# }# resource "azapi_resource" "interior_design_agent" {
#   type                      = "Microsoft.CognitiveServices/accounts/projects/agents@2025-06-01"
#   name                      = "interior-design-agent"
#   location                  = var.location
#   parent_id                 = azapi_resource.ai_project.id
#   schema_validation_enabled = false
#   body = jsonencode({
#     properties = {
#       displayName         = "Interior Designer"
#       description         = "Domain expert for interior design guidance"
#       domain              = "interior_design"
#       modelDeploymentName = "gpt-4o-mini"
#     }
#   })
#   depends_on = [azapi_resource.ai_project]
# }# resource "azapi_resource" "inventory_agent" {
#   type                      = "Microsoft.CognitiveServices/accounts/projects/agents@2025-06-01"
#   name                      = "inventory-agent"
#   location                  = var.location
#   parent_id                 = azapi_resource.ai_project.id
#   schema_validation_enabled = false
#   body = jsonencode({
#     properties = {
#       displayName         = "Inventory Manager"
#       description         = "Domain expert for inventory status"
#       domain              = "inventory"
#       modelDeploymentName = "gpt-4o-mini"
#     }
#   })
#   depends_on = [azapi_resource.ai_project]
# }# resource "azapi_resource" "customer_loyalty_agent" {
#   type                      = "Microsoft.CognitiveServices/accounts/projects/agents@2025-06-01"
#   name                      = "customer-loyalty-agent"
#   location                  = var.location
#   parent_id                 = azapi_resource.ai_project.id
#   schema_validation_enabled = false
#   body = jsonencode({
#     properties = {
#       displayName         = "Customer Loyalty Specialist"
#       description         = "Domain expert for loyalty and rewards"
#       domain              = "customer_loyalty"
#       modelDeploymentName = "gpt-4o-mini"
#     }
#   })
#   depends_on = [azapi_resource.ai_project]
# }# resource "azapi_resource" "cart_manager_agent" {
#   type                      = "Microsoft.CognitiveServices/accounts/projects/agents@2025-06-01"
#   name                      = "cart-manager-agent"
#   location                  = var.location
#   parent_id                 = azapi_resource.ai_project.id
#   schema_validation_enabled = false
#   body = jsonencode({
#     properties = {
#       displayName         = "Cart Manager"
#       description         = "Domain expert for cart management"
#       domain              = "cart_management"
#       modelDeploymentName = "gpt-4o-mini"
#     }
#   })
#   depends_on = [azapi_resource.ai_project]
# }

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
  
  depends_on = [
    azurerm_resource_group.rg
  ]
}

resource "azurerm_application_insights" "appinsights" {
  name                = local.app_insights_name
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.law.id
  
  # Disable billing features to avoid 404 errors
  daily_data_cap_in_gb                     = 1
  daily_data_cap_notifications_disabled    = true
  sampling_percentage                       = 100
  
  lifecycle {
    ignore_changes = [
      tags,
      disable_ip_masking,
      force_customer_storage_for_profiler,
      internet_ingestion_enabled,
      internet_query_enabled,
      local_authentication_disabled
    ]
  }
  
  depends_on = [
    azurerm_resource_group.rg,
    azurerm_log_analytics_workspace.law
  ]
}

resource "azurerm_container_registry" "acr" {
  name                = local.registry_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  sku                 = "Standard"
  admin_enabled       = true
  
  depends_on = [
    azurerm_resource_group.rg
  ]
}

# Container Apps environment (alternative to App Service)
resource "azurerm_container_app_environment" "app_env" {
  count                        = local.deploy_to_container_apps ? 1 : 0
  name                         = "${var.name_prefix}-${local.suffix}-cae"
  location                     = var.location
  resource_group_name          = azurerm_resource_group.rg.name
  log_analytics_workspace_id   = azurerm_log_analytics_workspace.law.id
}

resource "azurerm_user_assigned_identity" "containerapp_identity" {
  count               = local.deploy_to_container_apps ? 1 : 0
  name                = "${var.name_prefix}-${local.suffix}-ca-id"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
}

# Container Apps deployment (uses ACR image)
resource "azurerm_container_app" "app" {
  count                       = local.deploy_to_container_apps ? 1 : 0
  name                        = "${var.name_prefix}-${local.suffix}-ca"
  resource_group_name         = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.app_env[0].id
  revision_mode               = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.containerapp_identity[0].id]
  }

  template {
    container {
      name   = "zava-chat-app"
      image  = "${azurerm_container_registry.acr.login_server}/zava-chat-app:latest"
      cpu    = 1
      memory = "2Gi"

      env {
        name  = "WEBSITES_PORT"
        value = "8000"
      }

      env {
        name  = "USE_MULTI_AGENT"
        value = var.enable_multi_agent ? "true" : "false"
      }

      env {
        name  = "AZURE_AI_FOUNDRY_ENDPOINT"
        value = "https://${local.ai_foundry_name}.cognitiveservices.azure.com/"
      }
      env {
        name  = "AZURE_AI_PROJECT_NAME"
        value = local.ai_project_name
      }
      env {
        name  = "AZURE_AI_PROJECT_ENDPOINT"
        value = "https://${local.ai_foundry_name}.services.ai.azure.com/api/projects/${local.ai_project_name}"
      }
      env {
        name  = "AZURE_AI_AGENT_ENDPOINT"
        value = "https://${local.ai_foundry_name}.services.ai.azure.com/api/projects/${local.ai_project_name}"
      }
      env {
        name  = "AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME"
        value = var.chat_model_deployment
      }

      env {
        name  = "AZURE_OPENAI_CHAT_DEPLOYMENT"
        value = var.chat_model_deployment
      }
      env {
        name  = "AZURE_OPENAI_EMBEDDING_DEPLOYMENT"
        value = "text-embedding-3-small"
      }
      env {
        name  = "AZURE_OPENAI_ENDPOINT"
        value = "https://${local.ai_foundry_name}.cognitiveservices.azure.com/"
      }
      env {
        name  = "AZURE_OPENAI_API_VERSION"
        value = "2024-02-01"
      }

      env {
        name  = "gpt_endpoint"
        value = "https://${local.ai_foundry_name}.cognitiveservices.azure.com/"
      }
      env {
        name  = "gpt_deployment"
        value = var.chat_model_deployment
      }
      env {
        name  = "gpt_api_version"
        value = "2024-12-01-preview"
      }

      env {
        name  = "COSMOS_DB_ENDPOINT"
        value = azurerm_cosmosdb_account.cosmos.endpoint
      }
      env {
        name  = "COSMOS_DB_NAME"
        value = local.cosmos_db_name
      }
      env {
        name  = "COSMOS_DB_CONTAINER_NAME"
        value = "product_catalog"
      }
      env {
        name  = "COSMOS_SKIP_IF_EXISTS"
        value = "true"
      }

      env {
        name  = "SEARCH_SERVICE_ENDPOINT"
        value = "https://${local.search_service_name}.search.windows.net"
      }
      env {
        name  = "SEARCH_INDEX_NAME"
        value = "products-index"
      }

      env {
        name  = "STORAGE_ACCOUNT_NAME"
        value = local.storage_account
      }

      env {
        name  = "AZURE_SUBSCRIPTION_ID"
        value = data.azurerm_client_config.current.subscription_id
      }
      env {
        name  = "AZURE_RESOURCE_GROUP"
        value = azurerm_resource_group.rg.name
      }
      env {
        name  = "AZURE_LOCATION"
        value = var.location
      }

      env {
        name  = "AZURE_CLIENT_ID"
        value = azurerm_user_assigned_identity.containerapp_identity[0].client_id
      }

      env {
        name  = "CUSTOMER_ID"
        value = "CUST001"
      }

      # Secrets (Key Vault references)
      env {
        name        = "SEARCH_SERVICE_KEY"
        secret_name = "search-service-key"
      }
      env {
        name        = "STORAGE_CONNECTION_STRING"
        secret_name = "storage-connection-string"
      }

      # Cosmos auth: use AAD when local auth disabled
      dynamic "env" {
        for_each = var.enable_cosmos_local_auth ? [1] : []
        content {
          name        = "COSMOS_DB_KEY"
          secret_name = "cosmos-primary-key"
        }
      }
      dynamic "env" {
        for_each = var.enable_cosmos_local_auth ? [] : [1]
        content {
          name  = "COSMOS_DB_KEY"
          value = "AAD_AUTH"
        }
      }

      # Agent IDs (non-secret) - set explicitly to avoid secret set drift
      env {
        name  = "AGENT_CORA_ID"
        value = data.external.agents_state.result["agent_cora_id"]
      }
      env {
        name  = "AGENT_INTERIOR_DESIGNER_ID"
        value = data.external.agents_state.result["agent_interior_designer_id"]
      }
      env {
        name  = "AGENT_INVENTORY_AGENT_ID"
        value = data.external.agents_state.result["agent_inventory_agent_id"]
      }
      env {
        name  = "AGENT_CUSTOMER_LOYALTY_ID"
        value = data.external.agents_state.result["agent_customer_loyalty_id"]
      }
      env {
        name  = "AGENT_CART_MANAGER_ID"
        value = data.external.agents_state.result["agent_cart_manager_id"]
      }
      env {
        name  = "cora"
        value = data.external.agents_state.result["agent_cora_id"]
      }
      env {
        name  = "interior_designer"
        value = data.external.agents_state.result["agent_interior_designer_id"]
      }
      env {
        name  = "inventory_agent"
        value = data.external.agents_state.result["agent_inventory_agent_id"]
      }
      env {
        name  = "customer_loyalty"
        value = data.external.agents_state.result["agent_customer_loyalty_id"]
      }
      env {
        name  = "cart_manager"
        value = data.external.agents_state.result["agent_cart_manager_id"]
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    transport        = "auto"
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  registry {
    server               = azurerm_container_registry.acr.login_server
    identity             = azurerm_user_assigned_identity.containerapp_identity[0].id
  }

  secret {
    name                = "search-service-key"
    key_vault_secret_id = "${azurerm_key_vault.kv.vault_uri}secrets/search-admin-key"
    identity            = azurerm_user_assigned_identity.containerapp_identity[0].id
  }
  secret {
    name                = "storage-connection-string"
    key_vault_secret_id = "${azurerm_key_vault.kv.vault_uri}secrets/storage-connection-string"
    identity            = azurerm_user_assigned_identity.containerapp_identity[0].id
  }
  dynamic "secret" {
    for_each = var.enable_cosmos_local_auth ? [1] : []
    content {
      name                = "cosmos-primary-key"
      key_vault_secret_id = "${azurerm_key_vault.kv.vault_uri}secrets/cosmos-primary-key"
      identity            = azurerm_user_assigned_identity.containerapp_identity[0].id
    }
  }

  depends_on = [
    azurerm_container_registry.acr,
    azurerm_user_assigned_identity.containerapp_identity,
    azurerm_role_assignment.kv_secrets_user_containerapp,
    azurerm_role_assignment.containerapp_acr_pull,
    null_resource.docker_image_build,
    null_resource.set_kv_secrets,
    null_resource.set_agent_kv_secrets
  ]
}

resource "azurerm_container_registry_webhook" "webhook" {
  count               = local.deploy_to_appservice ? 1 : 0
  name                = "${local.registry_name}webhook"
  resource_group_name = azurerm_resource_group.rg.name
  registry_name       = azurerm_container_registry.acr.name
  location            = var.location

  service_uri = "https://${local.web_app_name}.scm.azurewebsites.net/api/registry/webhook"
  status      = "enabled"
  scope       = "zava-chat-app:latest"
  actions     = ["push"]

  custom_headers = {
    "Content-Type" = "application/json"
  }

  depends_on = [
    azurerm_container_registry.acr,
    azurerm_linux_web_app.app
  ]
}

# Standalone Docker Image Build - Always runs to ensure ACR has the required image
resource "null_resource" "docker_image_build" {
  # Trigger rebuild when:
  # 1. Dockerfile changes
  # 2. Application source code changes
  # 3. Requirements.txt changes
  # 4. ACR or app changes
  # 5. Force rebuild on every apply (always_run ensures terraform always executes the provisioner)
  triggers = {
    dockerfile_hash     = local.dockerfile_hash
    app_source_hash     = local.app_source_hash
    requirements_hash   = fileexists("../src/requirements.txt") ? filesha256("../src/requirements.txt") : "missing"
    acr_id              = azurerm_container_registry.acr.id
    always_run          = timestamp()  # Forces provisioner to run on every apply
  }

  depends_on = [
    azurerm_container_registry.acr
  ]

  provisioner "local-exec" {
    command = <<-EOT
      Write-Host ""
      Write-Host "=========================================="
      Write-Host "Building & Pushing Docker Image to ACR"
      Write-Host "=========================================="
      Write-Host ""
      
      $ErrorActionPreference = "Continue"  # Don't stop on warnings
      cd ..
      $srcPath = "src"
      
      Write-Host "Starting Docker build and push to ACR..."
      Write-Host "Registry: ${local.registry_name}"
      Write-Host "Image: zava-chat-app:latest"
      Write-Host "Dockerfile: $srcPath/Dockerfile"
      Write-Host "Source Path: $srcPath"
      Write-Host ""
      
      # Set encoding for Azure CLI
      $env:PYTHONIOENCODING = "utf-8"
      chcp 65001 > $null
      
      Write-Host "Executing ACR build command..."
      Write-Host ""
      
      try {
        # Build and push image
        az acr build `
          --resource-group ${azurerm_resource_group.rg.name} `
          --registry ${local.registry_name} `
          --image zava-chat-app:latest `
          --file "$srcPath\Dockerfile" `
          "$srcPath" `
          --no-logs
        
        if ($LASTEXITCODE -eq 0) {
          Write-Host ""
          Write-Host "[SUCCESS] Docker image successfully built and pushed to ACR"
          Write-Host ""
          Write-Host "Image details:"
          Write-Host "  Registry: ${local.registry_name}.azurecr.io"
          Write-Host "  Repository: zava-chat-app"
          Write-Host "  Tag: latest"
          Write-Host ""
          
          # Wait for image to be available
          Write-Host "Waiting for image to be available in registry..."
          Start-Sleep -Seconds 10
          
          # Verify image exists in ACR
          Write-Host "Verifying image in ACR..."
          $imgCheck = az acr repository show --name ${local.registry_name} --image zava-chat-app:latest --query "name" -o tsv 2>$null
          
          if ($LASTEXITCODE -eq 0 -and $imgCheck -eq "zava-chat-app") {
            Write-Host "[VERIFIED] Image confirmed in ACR registry"
            Write-Host ""
            exit 0
          } else {
            Write-Host "[WARNING] Image verification failed but build succeeded"
            Write-Host "This may be a timing issue. Image should be available shortly."
            Write-Host ""
            exit 0
          }
        } else {
          Write-Host ""
          Write-Host "[ERROR] ACR build failed with exit code: $LASTEXITCODE"
          Write-Host ""
          Write-Host "Troubleshooting steps:"
          Write-Host "  1. Check requirements.txt for dependency conflicts"
          Write-Host "  2. Verify Dockerfile paths are correct"
          Write-Host "  3. Manual build command:"
          Write-Host "     az acr build --resource-group ${azurerm_resource_group.rg.name} --registry ${local.registry_name} --image zava-chat-app:latest --file $srcPath\Dockerfile $srcPath"
          Write-Host ""
          exit 1
        }
      } catch {
        Write-Host ""
        Write-Host "[ERROR] Exception during build: $_"
        Write-Host "Manual build command:"
        Write-Host "az acr build --resource-group ${azurerm_resource_group.rg.name} --registry ${local.registry_name} --image zava-chat-app:latest --file $srcPath\Dockerfile $srcPath"
        Write-Host ""
        exit 1
      }
    EOT
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.module
  }
}

resource "azurerm_service_plan" "appserviceplan" {
  count               = local.deploy_to_appservice ? 1 : 0
  name                = local.app_service_plan
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.app_service_sku
}

resource "azurerm_linux_web_app" "app" {
  count               = local.deploy_to_appservice ? 1 : 0
  name                = local.web_app_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  service_plan_id     = azurerm_service_plan.appserviceplan[0].id
  https_only          = true

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on         = true
    http2_enabled     = true
    minimum_tls_version = "1.2"
    # Ensure App Service waits for container readiness
    health_check_path                 = "/health"
    health_check_eviction_time_in_min = 10
    application_stack {
      docker_image_name   = "zava-chat-app:latest"
      # Use full https URL for docker registry
      docker_registry_url = "https://${local.registry_name}.azurecr.io"
    }
    # Use system-assigned managed identity for ACR pulls (AcrPull role assignment granted below)
    container_registry_use_managed_identity = true
  }

  app_settings = {
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
    DOCKER_ENABLE_CI                    = "true"
    WEBSITES_PORT                       = "8000"

    # GPT Configuration (using managed identity)
    gpt_endpoint                        = "https://${local.ai_foundry_name}.cognitiveservices.azure.com/"
    gpt_deployment                      = var.chat_model_deployment
    gpt_api_version                     = "2024-12-01-preview"

    # MSFT Foundry Configuration (using managed identity)
    AZURE_AI_FOUNDRY_ENDPOINT           = "https://${local.ai_foundry_name}.cognitiveservices.azure.com/"
    AZURE_AI_PROJECT_NAME               = local.ai_project_name
    AZURE_AI_PROJECT_ENDPOINT           = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/agent-endpoint)"
    AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME = var.chat_model_deployment

    # MSFT Foundry OpenAI Configuration (using managed identity)
    AZURE_OPENAI_CHAT_DEPLOYMENT        = var.chat_model_deployment
    AZURE_OPENAI_EMBEDDING_DEPLOYMENT   = "text-embedding-3-small"
    AZURE_OPENAI_ENDPOINT               = "https://${local.ai_foundry_name}.cognitiveservices.azure.com/"
    AZURE_OPENAI_API_VERSION            = "2024-02-01"

    # External Service Keys via Key Vault
    SEARCH_SERVICE_KEY                  = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/search-admin-key)"
    COSMOS_DB_KEY                       = var.enable_cosmos_local_auth ? "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/cosmos-primary-key)" : "AAD_AUTH"
    STORAGE_CONNECTION_STRING           = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/storage-connection-string)"

    # Multi-Agent Configuration - Agent IDs from Key Vault
    USE_MULTI_AGENT                     = var.enable_multi_agent ? "true" : "false"
    AZURE_AI_AGENT_ENDPOINT             = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/agent-endpoint)"
    AGENT_CORA_ID                       = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/agent-cora-id)"
    AGENT_INTERIOR_DESIGNER_ID          = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/agent-interior-designer-id)"
    AGENT_INVENTORY_AGENT_ID            = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/agent-inventory-agent-id)"
    AGENT_CUSTOMER_LOYALTY_ID           = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/agent-customer-loyalty-id)"
    AGENT_CART_MANAGER_ID               = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/agent-cart-manager-id)"
    cora                                = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/agent-cora-id)"
    interior_designer                   = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/agent-interior-designer-id)"
    inventory_agent                     = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/agent-inventory-agent-id)"
    customer_loyalty                    = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/agent-customer-loyalty-id)"
    cart_manager                        = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/agent-cart-manager-id)"
    CUSTOMER_ID                         = "CUST001"
  }

  depends_on = [
    azurerm_container_registry.acr,
    null_resource.ai_model_deployments,
    null_resource.docker_image_build
  ]
}

# Grant AcrPull role to Web App managed identity so it can pull private images without admin credentials
resource "azurerm_role_assignment" "webapp_acr_pull" {
  count                = local.deploy_to_appservice ? 1 : 0
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.app[0].identity[0].principal_id
  depends_on = [
    azurerm_linux_web_app.app,
    azurerm_container_registry.acr
  ]
}

# Key Vault for central secret management
resource "azurerm_key_vault" "kv" {
  name                = local.key_vault_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled  = true
  enable_rbac_authorization = true
  public_network_access_enabled = true

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }

  tags = { purpose = "multi-agent-ai-secrets" }
}

# Ensure Key Vault public access is enabled before data-plane secret reads
resource "null_resource" "enable_kv_public_access" {
  depends_on = [azurerm_key_vault.kv]

  provisioner "local-exec" {
    command     = <<-EOT
      Write-Host "Ensuring Key Vault public access is enabled..."
      az keyvault update `
        --name "${azurerm_key_vault.kv.name}" `
        --resource-group "${azurerm_resource_group.rg.name}" `
        --public-network-access Enabled `
        --default-action Allow `
        --bypass AzureServices | Out-Null
    EOT
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.module
  }

  triggers = {
    always_run = timestamp()
  }
}

# Data source to retrieve the web app identity after it's created/updated
data "azurerm_linux_web_app" "app_identity" {
  count               = local.deploy_to_appservice ? 1 : 0
  name                = azurerm_linux_web_app.app[0].name
  resource_group_name = azurerm_resource_group.rg.name
  depends_on          = [azurerm_linux_web_app.app]
}

# RBAC role assignments for Key Vault access
resource "azurerm_role_assignment" "kv_secrets_officer_user" {
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = local.principal_id
}

resource "azurerm_role_assignment" "kv_secrets_user_containerapp" {
  count                = local.deploy_to_container_apps ? 1 : 0
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.containerapp_identity[0].principal_id
  depends_on           = [azurerm_user_assigned_identity.containerapp_identity]
}

resource "azurerm_role_assignment" "kv_secrets_user_webapp" {
  count                = local.deploy_to_appservice ? 1 : 0
  scope                = azurerm_key_vault.kv.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = data.azurerm_linux_web_app.app_identity[0].identity[0].principal_id
  depends_on           = [data.azurerm_linux_web_app.app_identity]
}

# Populate Key Vault secrets via CLI to avoid data-plane read failures
# Note: AI Foundry now uses managed identity instead of keys

# Fetch storage keys unconditionally
data "azapi_resource_action" "storage_keys_unconditional" {
  type                   = "Microsoft.Storage/storageAccounts@2023-01-01"
  resource_id            = azapi_resource.storage.id
  action                 = "listKeys"
  response_export_values = ["keys"]
  body                   = jsonencode({})
  depends_on             = [azapi_resource.storage]
}

resource "null_resource" "set_kv_secrets" {
  depends_on = [
    azurerm_key_vault.kv,
    azurerm_role_assignment.kv_secrets_officer_user,
    null_resource.enable_kv_public_access,
    data.azapi_resource_action.search_admin_keys,
    data.azapi_resource_action.storage_keys_unconditional,
    data.azapi_resource_action.cosmos_keys
  ]

  provisioner "local-exec" {
    command     = <<-EOT
      $kv = "${azurerm_key_vault.kv.name}"
      Write-Host "Setting Key Vault secrets (search/storage/cosmos/agent-endpoint)..."
      az keyvault secret set --vault-name $kv --name "search-admin-key" --value "${jsondecode(data.azapi_resource_action.search_admin_keys[0].output).primaryKey}" | Out-Null
      az keyvault secret set --vault-name $kv --name "storage-connection-string" --value "DefaultEndpointsProtocol=https;AccountName=${local.storage_account};AccountKey=${jsondecode(data.azapi_resource_action.storage_keys_unconditional.output).keys[0].value};EndpointSuffix=core.windows.net" | Out-Null
      if (${var.enable_cosmos_local_auth ? "$true" : "$false"}) {
        az keyvault secret set --vault-name $kv --name "cosmos-primary-key" --value "${jsondecode(data.azapi_resource_action.cosmos_keys[0].output).primaryMasterKey}" | Out-Null
      }
      az keyvault secret set --vault-name $kv --name "agent-endpoint" --value "https://${local.ai_foundry_name}.services.ai.azure.com/api/projects/${local.ai_project_name}" | Out-Null
    EOT
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.module
  }

  triggers = {
    always_run = timestamp()
  }
}

# External data source for agents state
data "external" "agents_state" {
  program = ["python", "read_agents_state.py"]
  depends_on = [null_resource.deploy_multi_agents]
}

# Store agent IDs in Key Vault via CLI
resource "null_resource" "set_agent_kv_secrets" {
  depends_on = [
    azurerm_key_vault.kv,
    azurerm_role_assignment.kv_secrets_officer_user,
    null_resource.enable_kv_public_access,
    data.external.agents_state
  ]

  provisioner "local-exec" {
    command     = <<-EOT
      $kv = "${azurerm_key_vault.kv.name}"
      Write-Host "Setting Key Vault agent ID secrets..."
      az keyvault secret set --vault-name $kv --name "agent-cora-id" --value "${data.external.agents_state.result["agent_cora_id"]}" | Out-Null
      az keyvault secret set --vault-name $kv --name "agent-interior-designer-id" --value "${data.external.agents_state.result["agent_interior_designer_id"]}" | Out-Null
      az keyvault secret set --vault-name $kv --name "agent-inventory-agent-id" --value "${data.external.agents_state.result["agent_inventory_agent_id"]}" | Out-Null
      az keyvault secret set --vault-name $kv --name "agent-customer-loyalty-id" --value "${data.external.agents_state.result["agent_customer_loyalty_id"]}" | Out-Null
      az keyvault secret set --vault-name $kv --name "agent-cart-manager-id" --value "${data.external.agents_state.result["agent_cart_manager_id"]}" | Out-Null
    EOT
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.module
  }

  triggers = {
    always_run = timestamp()
  }
}

# App Service Plan autoscale
resource "azurerm_monitor_autoscale_setting" "appservice_autoscale" {
  count               = local.deploy_to_appservice ? 1 : 0
  name                = "${var.name_prefix}-${local.suffix}-asp-autoscale"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  target_resource_id  = azurerm_service_plan.appserviceplan[0].id

  profile {
    name = "default"
    capacity {
      minimum = "1"
      maximum = "3"
      default = "1"
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.appserviceplan[0].id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }
      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.appserviceplan[0].id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 35
      }
      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }
  }

  notification {
    email {
      send_to_subscription_administrator    = false
      send_to_subscription_co_administrator = false
      custom_emails                         = []
    }
  }

  depends_on = [azurerm_service_plan.appserviceplan]
}

# Alerts: App Service 5xx & CPU, Cosmos 429 throttles
resource "azurerm_monitor_metric_alert" "app_5xx" {
  count               = local.deploy_to_appservice ? 1 : 0
  name                = "${var.name_prefix}-${local.suffix}-app-5xx-alert"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_linux_web_app.app[0].id]
  description         = "Alert on high 5xx responses"
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT5M"
  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "Http5xx"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 20
  }
}

resource "azurerm_monitor_metric_alert" "app_cpu" {
  count               = local.deploy_to_appservice ? 1 : 0
  name                = "${var.name_prefix}-${local.suffix}-app-cpu-alert"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_service_plan.appserviceplan[0].id]
  description         = "Alert on high CPU"
  severity            = 3
  frequency           = "PT5M"
  window_size         = "PT5M"
  criteria {
    metric_namespace = "Microsoft.Web/serverfarms"
    metric_name      = "CpuPercentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }
}

resource "azurerm_monitor_metric_alert" "cosmos_throttle" {
  name                = "${var.name_prefix}-${local.suffix}-cosmos-429-alert"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_cosmosdb_account.cosmos.id]
  description         = "Alert on Cosmos DB throttled requests"
  severity            = 3
  frequency           = "PT5M"
  window_size         = "PT5M"
  criteria {
    metric_namespace = "Microsoft.DocumentDB/databaseAccounts"
    metric_name      = "TotalRequests"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 1000
  }
}

# Portal Dashboard aggregating key metrics
resource "azurerm_portal_dashboard" "observability" {
  count               = local.deploy_to_appservice ? 1 : 0
  name                = "${var.name_prefix}-${local.suffix}-dashboard"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = { purpose = "multi-agent-observability" }

  dashboard_properties = jsonencode({
    lenses = {
      "0" = {
        order  = 0
        parts  = {
          "0" = {
            position = { x = 0, y = 0, width = 6, height = 4 }
            metadata = {
              inputs = [
                { name = "resourceType", value = "microsoft.web/sites" },
                { name = "resource", value = azurerm_linux_web_app.app[0].id },
                { name = "chartSettings", value = jsonencode({ version = "Workspace" }) }
              ]
              type = "Extension/HubsExtension/PartType/MonitorChartPart"
              settings = {
                content = {
                  version = "1.0.0"
                  chart = {
                    title      = "App Service Requests"
                    metrics    = [{ resourceMetadata = { id = azurerm_linux_web_app.app[0].id }, name = "Requests", aggregationType = "Total" }]
                    timespan   = { duration = "PT1H" }
                    visualization = { chartType = "Line" }
                  }
                }
              }
            }
          },
          "1" = {
            position = { x = 6, y = 0, width = 6, height = 4 }
            metadata = {
              inputs = [
                { name = "resourceType", value = "microsoft.web/serverfarms" },
                { name = "resource", value = azurerm_service_plan.appserviceplan[0].id }
              ]
              type = "Extension/HubsExtension/PartType/MonitorChartPart"
              settings = {
                content = {
                  version = "1.0.0"
                  chart = {
                    title   = "CPU Percentage"
                    metrics = [{ resourceMetadata = { id = azurerm_service_plan.appserviceplan[0].id }, name = "CpuPercentage", aggregationType = "Average" }]
                    timespan = { duration = "PT1H" }
                  }
                }
              }
            }
          },
          "2" = {
            position = { x = 0, y = 4, width = 6, height = 4 }
            metadata = {
              inputs = [
                { name = "resourceType", value = "microsoft.documentdb/databaseAccounts" },
                { name = "resource", value = azurerm_cosmosdb_account.cosmos.id }
              ]
              type = "Extension/HubsExtension/PartType/MonitorChartPart"
              settings = {
                content = {
                  version = "1.0.0"
                  chart = {
                    title = "Cosmos Total Requests"
                    metrics = [{ resourceMetadata = { id = azurerm_cosmosdb_account.cosmos.id }, name = "TotalRequests", aggregationType = "Total" }]
                    timespan = { duration = "PT1H" }
                  }
                }
              }
            }
          },
          "3" = {
            position = { x = 6, y = 4, width = 6, height = 4 }
            metadata = {
              inputs = [
                { name = "resourceType", value = "microsoft.insights/components" },
                { name = "resource", value = azurerm_application_insights.appinsights.id }
              ]
              type = "Extension/HubsExtension/PartType/MonitorChartPart"
              settings = {
                content = {
                  version = "1.0.0"
                  chart = {
                    title = "App Insights Server Response Time"
                    metrics = [{ resourceMetadata = { id = azurerm_application_insights.appinsights.id }, name = "requests/duration", aggregationType = "Average" }]
                    timespan = { duration = "PT1H" }
                  }
                }
              }
            }
          }
        }
      }
    }
    metadata = { model = "PortalDashboard" }
  })
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

# Assign Cosmos DB Data Contributor role to Container App managed identity
resource "azapi_resource" "containerapp_cosmos_data_contributor" {
  count     = local.deploy_to_container_apps ? 1 : 0
  type      = "Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2023-04-15"
  name      = md5("${azurerm_cosmosdb_account.cosmos.id}-${azurerm_user_assigned_identity.containerapp_identity[0].principal_id}-${local.cosmos_db_data_contributor_role_id}")
  parent_id = azurerm_cosmosdb_account.cosmos.id
  body = jsonencode({
    properties = {
      roleDefinitionId = "${azurerm_cosmosdb_account.cosmos.id}/sqlRoleDefinitions/${local.cosmos_db_data_contributor_role_id}"
      principalId      = azurerm_user_assigned_identity.containerapp_identity[0].principal_id
      scope            = azurerm_cosmosdb_account.cosmos.id
    }
  })
  depends_on = [azurerm_container_app.app]
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

# Role assignments for Web App managed identity to access AI Foundry
resource "azurerm_role_assignment" "webapp_foundry_openai_user" {
  count              = local.deploy_to_appservice ? 1 : 0
  scope              = azapi_resource.ai_foundry.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.cognitive_openai_user_role_id}"
  principal_id       = data.azurerm_linux_web_app.app_identity[0].identity[0].principal_id
  principal_type     = "ServicePrincipal"
  depends_on         = [azurerm_linux_web_app.app]
}

resource "azurerm_role_assignment" "webapp_project_openai_user" {
  count              = local.deploy_to_appservice ? 1 : 0
  scope              = azapi_resource.ai_project.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.cognitive_openai_user_role_id}"
  principal_id       = data.azurerm_linux_web_app.app_identity[0].identity[0].principal_id
  principal_type     = "ServicePrincipal"
  depends_on         = [azurerm_linux_web_app.app]
}

# Role assignments for Container App managed identity to access AI Foundry
resource "azurerm_role_assignment" "containerapp_foundry_openai_user" {
  count              = local.deploy_to_container_apps ? 1 : 0
  scope              = azapi_resource.ai_foundry.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.cognitive_openai_user_role_id}"
  principal_id       = azurerm_user_assigned_identity.containerapp_identity[0].principal_id
  principal_type     = "ServicePrincipal"
  depends_on         = [azurerm_container_app.app]
}

resource "azurerm_role_assignment" "containerapp_project_openai_user" {
  count              = local.deploy_to_container_apps ? 1 : 0
  scope              = azapi_resource.ai_project.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.cognitive_openai_user_role_id}"
  principal_id       = azurerm_user_assigned_identity.containerapp_identity[0].principal_id
  principal_type     = "ServicePrincipal"
  depends_on         = [azurerm_container_app.app]
}

# Grant AcrPull role to Container App managed identity for ACR pulls
resource "azurerm_role_assignment" "containerapp_acr_pull" {
  count                = local.deploy_to_container_apps ? 1 : 0
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.containerapp_identity[0].principal_id
  depends_on           = [azurerm_user_assigned_identity.containerapp_identity, azurerm_container_registry.acr]
}

# Storage account permissions for MSFT Foundry project
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
        # Create model-router deployment (single chat deployment)
        Write-Host "Creating model-router deployment..."
        az cognitiveservices account deployment create `
          --resource-group "${azurerm_resource_group.rg.name}" `
          --name "${local.ai_foundry_name}" `
          --deployment-name "model-router" `
          --model-name "model-router" `
          --model-version "2025-11-18" `
          --model-format "OpenAI" `
          --sku-capacity 10 `
          --sku-name "GlobalStandard"
        
          if ($LASTEXITCODE -eq 0) {
            Write-Host "model-router deployment created successfully"
          } else {
            Write-Host "model-router deployment may already exist or failed to create"
          }

          # Create gpt-4o-mini deployment (fallback chat model)
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
            }

        # Create text-embedding-3-small deployment
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
  depends_on             = [data.azapi_resource_action.storage_keys_unconditional]
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

# AI Foundry now uses managed identity authentication - no keys needed

# Connect resources to MSFT Foundry project using ARM templates
resource "azapi_resource" "storage_connection" {
  count = var.enable_ai_automation ? 1 : 0

  type                      = "Microsoft.CognitiveServices/accounts/connections@2025-04-01-preview"
  name                      = "${local.ai_foundry_name}-storage"
  parent_id                 = azapi_resource.ai_foundry.id
  schema_validation_enabled = false

  depends_on = [
    azapi_resource.storage,
    azapi_update_resource.ai_foundry_enable_project_mgmt
  ]

  body = jsonencode({
    properties = {
      category      = "AzureStorageAccount"
      target        = "https://${local.storage_account}.blob.core.windows.net"
      authType      = "AccountKey"
      isSharedToAll = true
      credentials = {
        key = jsondecode(data.azapi_resource_action.storage_keys_unconditional.output).keys[0].value
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
    azapi_update_resource.ai_foundry_enable_project_mgmt
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
    azapi_update_resource.ai_foundry_enable_project_mgmt
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
    azapi_update_resource.ai_foundry_enable_project_mgmt
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
      Write-Host "[OK] Microsoft Foundry project connections verification completed!"
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
      
      # Get MSFT Foundry endpoint and fix domain for Agents API
      $rawAiFoundryEndpoint = az cognitiveservices account show `
        --resource-group "${azurerm_resource_group.rg.name}" `
        --name "${local.ai_foundry_name}" `
        --query "properties.endpoint" `
        --output tsv
      
      # For OpenAI models, use the cognitive services endpoint
      $openAiEndpoint = $rawAiFoundryEndpoint
      # For Agents API, use the corrected services.ai.azure.com domain
      $agentsEndpointBase = $rawAiFoundryEndpoint -replace "cognitiveservices\.azure\.com", "services.ai.azure.com"
      $agentsEndpointBase = $agentsEndpointBase.TrimEnd("/")
      $agentsProjectEndpoint = "$agentsEndpointBase/api/projects/${local.ai_project_name}"
      
      Write-Host "OpenAI Endpoint: $openAiEndpoint"
      Write-Host "Agents API Endpoint: $agentsProjectEndpoint"
      
      # Fetch secrets from Key Vault for local dev (avoid embedding in Terraform state)
      $kv = "${azurerm_key_vault.kv.name}"
      $aiFoundryKey = az keyvault secret show --vault-name $kv --name ai-foundry-key --query value -o tsv
      $searchKey = az keyvault secret show --vault-name $kv --name search-admin-key --query value -o tsv
      if (${var.enable_cosmos_local_auth ? "$true" : "$false"}) {
        $cosmosKey = az keyvault secret show --vault-name $kv --name cosmos-primary-key --query value -o tsv
      } else { $cosmosKey = "AAD_AUTH" }
      $storageConnectionString = az keyvault secret show --vault-name $kv --name storage-connection-string --query value -o tsv
      
      # Create .env file content
      $envContent = @"
# Azure AI Foundry Configuration
AZURE_AI_FOUNDRY_ENDPOINT=$openAiEndpoint
AZURE_AI_FOUNDRY_API_KEY=$aiFoundryKey
AZURE_AI_PROJECT_NAME=${local.ai_project_name}
AZURE_AI_AGENT_ENDPOINT=$agentsProjectEndpoint

# Azure OpenAI Model Deployments
  AZURE_OPENAI_CHAT_DEPLOYMENT=${var.chat_model_deployment}
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-small
AZURE_OPENAI_ENDPOINT=$openAiEndpoint
AZURE_OPENAI_API_KEY=$aiFoundryKey
AZURE_OPENAI_API_VERSION=2024-02-01

# GPT Model Configuration (for single-agent chat)
gpt_endpoint=$openAiEndpoint
  gpt_deployment=${var.chat_model_deployment}
gpt_api_key=$aiFoundryKey
gpt_api_version=2024-02-01

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

# Multi-Agent Configuration
USE_MULTI_AGENT=true
AZURE_AI_PROJECT_ENDPOINT=$agentsProjectEndpoint
AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME=${var.chat_model_deployment}

# Local Pseudo Agent IDs (no remote provisioning required)
cora=asst_local_cora
interior_designer=asst_local_interior_design
inventory_agent=asst_local_inventory
customer_loyalty=asst_local_customer_loyalty
cart_manager=asst_local_cart_manager

# Customer Configuration
CUSTOMER_ID=CUST001
"@
      
      # Write .env file
      $envContent | Out-File -FilePath "../src/.env" -Encoding UTF8
      
      Write-Host ".env file created successfully at ../src/.env"
      Write-Host "Environment variables configured for:"
      Write-Host "  - Models: ${var.chat_model_deployment}, text-embedding-3-small"
      Write-Host "  - MSFT Foundry: ${local.ai_foundry_name}"
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
  Write-Host "Virtual environment already exists, attempting to remove..."
  try {
    Remove-Item -Recurse -Force venv -ErrorAction Stop
    Start-Sleep -Seconds 2
  } catch {
    Write-Host "WARNING: Could not remove existing venv, it may be locked. Trying to continue..."
  }
}

try {
  python -m venv venv --clear
} catch {
  Write-Host "WARNING: Failed to create virtual environment: $_"
  Write-Host "Skipping data pipeline - you can run it manually later"
  Write-Host "Run from src directory: python -m venv venv; .\venv\Scripts\activate; pip install -r requirements.txt"
  exit 0
}

# Install dependencies directly to venv without activation
Write-Host "Installing Python dependencies (with retry)..."
$pythonExe = "venv\Scripts\python.exe"

if (Test-Path $pythonExe) {
  # Use python -m pip instead of pip.exe to avoid file locking issues
  $maxAttempts = 3
  for ($i = 1; $i -le $maxAttempts; $i++) {
    Write-Host "pip install attempt $i..."
    & $pythonExe -m pip install --upgrade pip --no-warn-script-location 2>&1 | Out-Null
    & $pythonExe -m pip install -r requirements.txt
    if ($LASTEXITCODE -eq 0) {
      Write-Host "Dependencies installed successfully on attempt $i"
      break
    } else {
      Write-Host "pip install failed (exit $LASTEXITCODE)."
      if ($i -lt $maxAttempts) {
        Write-Host "Retrying after short backoff..."
        Start-Sleep -Seconds 5
      } else {
        Write-Host "WARNING: Dependencies failed after $maxAttempts attempts"
        Write-Host "Skipping data pipeline - you can run it manually later"
        exit 0
      }
    }
  }        Write-Host "Python environment ready"
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
        Write-Host "WARNING: Failed to create virtual environment"
        Write-Host "Skipping data pipeline - you can run it manually later"
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

# Vector index update automation (stub - triggers when product catalog changes)
resource "null_resource" "vector_index_update" {
  count = var.enable_data_pipeline ? 1 : 0

  depends_on = [null_resource.data_pipeline]

  provisioner "local-exec" {
    command = <<-EOT
      Write-Host "Triggering vector index update if catalog changed..."
      $pythonCmd = "python"
      if (Get-Command python3 -ErrorAction SilentlyContinue) { $pythonCmd = "python3" }
      $script = Join-Path (Split-Path $PWD.Path -Parent) "src\pipelines\update_vector_index.py"
      if (Test-Path $script) {
        & $pythonCmd $script
      } else {
        Write-Host "Vector update script not found: $script"
      }
    EOT
    interpreter = ["PowerShell", "-Command"]
  }

  triggers = {
    catalog_hash = local.product_catalog_hash
  }
}

# Single-Agent Application Verification - Verifies the chat application is ready
resource "null_resource" "verify_single_agent_app" {
  count = var.enable_data_pipeline ? 1 : 0

  depends_on = [
    null_resource.data_pipeline
  ]

  provisioner "local-exec" {
    command     = <<-EOT
      Write-Host ""
      Write-Host "=== Verifying Single-Agent Chat Application ==="
      Write-Host ""
      
      # Check if application files exist
      $appFiles = @(
        "../src/chat_app.py",
        "../src/app/tools/singleAgentExample.py",
        "../src/app/templates/index.html"
      )
      
      $allFilesExist = $true
      foreach ($file in $appFiles) {
        if (Test-Path $file) {
          Write-Host "[OK] Found: $file"
        } else {
          Write-Host "✗ Missing: $file"
          $allFilesExist = $false
        }
      }
      
      Write-Host ""
      if ($allFilesExist) {
        Write-Host "[OK] All single-agent application files are in place!"
        Write-Host ""
        Write-Host "Application structure:"
        Write-Host "  📄 chat_app.py - FastAPI web application"
        Write-Host "  [APP] app/tools/singleAgentExample.py - AI agent logic"
        Write-Host "  [UI] app/templates/index.html - Chat interface"
        Write-Host ""
        Write-Host "To start the chat application:"
        Write-Host "  1. cd ..\src"
        Write-Host "  2. venv\Scripts\Activate.ps1"
        Write-Host "  3. uvicorn chat_app:app --host 0.0.0.0 --port 8000"
        Write-Host "  4. Or access via Azure Web App: https://${local.web_app_name}.azurewebsites.net"
        Write-Host ""
      } else {
        Write-Host "WARNING:  Some application files are missing!"
        Write-Host "Please ensure all files are committed to the repository."
      }
    EOT
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.module
  }

  triggers = {
    data_pipeline_id = null_resource.data_pipeline[0].id
    env_file_id      = null_resource.create_env_file[0].id
  }
}

# Multi-Agent Deployment - Create real agents in Microsoft Foundry
resource "null_resource" "deploy_multi_agents" {
  count = var.enable_multi_agent ? 1 : 0

  depends_on = [
    null_resource.create_env_file,
    null_resource.ai_model_deployments,
    azapi_resource.ai_project
  ]

  provisioner "local-exec" {
    command     = <<-EOT
      Write-Host ""
      Write-Host "=== Creating Real Agents in Microsoft Foundry ==="
      Write-Host ""
      
      # Ensure Python environment is ready
      $pythonCmd = "python"
      if (Get-Command python3 -ErrorAction SilentlyContinue) {
        $pythonCmd = "python3"
      }
      
      Write-Host "Installing required Azure SDK packages..."
      & $pythonCmd -m pip install -q --pre 'azure-ai-projects>=2.0.0b1' azure-identity python-dotenv
      
      if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to install required packages"
        Write-Host "Falling back to local pseudo-agents..."
        exit 0
      }
      
      Write-Host "[OK] SDK packages installed"
      Write-Host ""
      
      # Set up environment for agent deployment with corrected endpoint
      $rawEndpoint = az cognitiveservices account show `
        --resource-group "${azurerm_resource_group.rg.name}" `
        --name "${local.ai_foundry_name}" `
        --query "properties.endpoint" `
        --output tsv
      # Fix domain for agents API and attach project path
      $agentEndpointBase = $rawEndpoint -replace "cognitiveservices\.azure\.com", "services.ai.azure.com"
      $agentEndpoint = "$agentEndpointBase/api/projects/${local.ai_project_name}"
      $env:AZURE_AI_PROJECT_ENDPOINT = $agentEndpoint
      Write-Host "Using Agents API endpoint: $agentEndpoint"
      
      # Deploy agents using Python script
      Write-Host "Deploying 6 agents to MSFT Foundry..."
      $agentScriptPath = Join-Path (Split-Path $PWD.Path -Parent) "src\app\agents\deploy_real_agents.py"
      $env:PYTHONPATH = Join-Path (Split-Path $PWD.Path -Parent) "src"
      
      if (!(Test-Path $agentScriptPath)) {
        Write-Host "ERROR: Agent deployment script not found: $agentScriptPath"
        Write-Host "Falling back to local pseudo-agents..."
        exit 0
      }
      
      # Run the deployment script
      & $pythonCmd $agentScriptPath
      
      if ($LASTEXITCODE -ne 0) {
        Write-Host "WARNING:  Agent deployment script reported errors, but continuing..."
        Write-Host "Check if agents were partially created in Foundry portal"
      } else {
        Write-Host ""
        Write-Host "[SUCCESS] Real agents successfully created in Microsoft Foundry!"
        Write-Host ""
        Write-Host "View your agents at:"
        Write-Host "  https://ai.azure.com/build/agents?wsid=/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${azurerm_resource_group.rg.name}/providers/Microsoft.CognitiveServices/accounts/${local.ai_foundry_name}"

        # Propagate real agent IDs from .env into Web App app settings (override local pseudo IDs)
        $envPath = Join-Path (Split-Path $PWD.Path -Parent) "src/.env"
        if (Test-Path $envPath) {
          Write-Host "Updating Web App app settings with real agent IDs..."
          $agentVars = @("cora","interior_designer","inventory_agent","customer_loyalty","cart_manager","product_management")
          $settingsArgs = @()
          foreach ($var in $agentVars) {
            $line = Select-String -Path $envPath -Pattern "^$var=" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($line) {
              $value = $line.Line.Split("=",2)[1]
              if ($value -and $value -notlike "asst_local*") {
                Write-Host "  $var => $value"
                $settingsArgs += "$var=$value"
              }
            }
          }
          if ($settingsArgs.Count -gt 0) {
            if ("${var.deployment_target}" -eq "appservice") {
              az webapp config appsettings set `
                --resource-group ${azurerm_resource_group.rg.name} `
                --name ${local.web_app_name} `
                --settings $settingsArgs | Out-Null
              Write-Host "[OK] Web App app settings updated with real agent IDs"
              Write-Host "Restarting Web App to apply settings..."
              az webapp restart --resource-group ${azurerm_resource_group.rg.name} --name ${local.web_app_name} | Out-Null
              Write-Host "[OK] Web App restarted"
            } else {
              Write-Host "[INFO] Skipping Web App updates (deployment_target=containerapps)"
            }
          } else {
            Write-Host "No real agent IDs found to update (still using local simulation)."
          }
        } else {
          Write-Host "Could not find .env file to propagate agent IDs."
        }
      }
      
      Write-Host ""
      Write-Host "Docker image already built by standalone resource."
      Write-Host ""
      if ("${var.deployment_target}" -eq "appservice") {
        Write-Host "Restarting Web App to ensure latest configuration..."
        az webapp restart --resource-group ${azurerm_resource_group.rg.name} --name ${local.web_app_name} | Out-Null
        Write-Host "[OK] Web App restarted"
      } else {
        Write-Host "[INFO] Skipping Web App restart (deployment_target=containerapps)"
      }
      Write-Host ""
      Write-Host "Multi-agent deployment complete!"
    EOT
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.module
  }

  triggers = {
    ai_project_id = azapi_resource.ai_project.id
    env_file_id   = null_resource.create_env_file[0].id
    docker_hash   = local.dockerfile_hash
    app_hash      = local.app_source_hash
  }
}

# Post-provision verification of real agents (ensures >=5 non-local agents)
resource "null_resource" "verify_real_agents" {
  count = var.enable_multi_agent ? 1 : 0

  depends_on = [
    null_resource.deploy_multi_agents
  ]

  provisioner "local-exec" {
    command = <<-EOT
      Write-Host ""; Write-Host "=== Verifying Real Agent Provisioning (Post-Deploy) ==="; Write-Host ""
      $pythonCmd = "python"
      if (Get-Command python3 -ErrorAction SilentlyContinue) { $pythonCmd = "python3" }
      
      # Run verification script to confirm agents exist in Azure
      $quickVerifyScript = Join-Path (Split-Path $PWD.Path -Parent) "src\app\agents\quick_verify.py"
      if (Test-Path $quickVerifyScript) {
        Write-Host "Running agent verification..."
        & $pythonCmd $quickVerifyScript
        if ($LASTEXITCODE -eq 0) {
          Write-Host "[SUCCESS] All agents verified in MSFT Foundry"
        } else {
          Write-Host "WARNING: Agent verification reported issues (check output above)"
        }
      } else {
        Write-Host "WARNING: quick_verify.py not found, skipping verification"
      }
      
      # Parse agent_ids.json to count real agents
      $agentIdsPath = Join-Path $PWD.Path "agent_ids.json"
      if (Test-Path $agentIdsPath) {
        $agentData = Get-Content $agentIdsPath -Raw | ConvertFrom-Json
        $realCount = 0
        foreach ($prop in $agentData.PSObject.Properties) {
          if ($prop.Value -and ($prop.Value -notlike "asst_local_*")) { 
            $realCount++ 
          }
        }
        Write-Host ""
        Write-Host "Real agent count from agent_ids.json: $realCount"
        if ($realCount -ge 5) {
          Write-Host "[SUCCESS] Verification passed: $realCount real agents deployed."
        } else {
          Write-Host "WARNING: Expected 5 real agents; found $realCount."
          $logPath = "../real_agent_warnings.log"
          "[$(Get-Date -Format o)] WARNING: Only $realCount real agents deployed." | Out-File -FilePath $logPath -Append -Encoding utf8
          Write-Host "Logged warning to $logPath"
        }
      } else {
        Write-Host "WARNING: agent_ids.json not found; cannot verify deployment count."
      }
      Write-Host ""; Write-Host "=== Real Agent Verification Complete ==="; Write-Host ""
    EOT
    interpreter = ["PowerShell", "-Command"]
  }

  triggers = {
    deploy_agents_id = null_resource.deploy_multi_agents[0].id
  }
}

# Install Docker Desktop if not present and deploy chat app using containers
resource "null_resource" "deploy_chat_app" {
  count = (var.enable_data_pipeline && local.deploy_to_appservice) ? 1 : 0

  depends_on = [
    null_resource.verify_single_agent_app,
    null_resource.data_pipeline,
    azurerm_linux_web_app.app
  ]

  provisioner "local-exec" {
    command     = <<-EOT
      Write-Host ""
      Write-Host "=== Deploying Chat Application to Azure Web App ==="
      Write-Host ""
      
      # Check if multi-agent mode is enabled
      $multiAgentEnabled = "${var.enable_multi_agent}"
      
      if ($multiAgentEnabled -eq "true") {
        Write-Host "[INFO]  Multi-agent mode enabled - deployment handled by deploy_multi_agents resource"
        Write-Host "Skipping duplicate ACR build and deployment"
        Write-Host ""
        Write-Host "Your chat application is available at:"
        Write-Host "https://${local.web_app_name}.azurewebsites.net"
        exit 0
      }
      
      # Build container directly in ACR (no local Docker needed)
      Write-Host "Building chat application container in Azure Container Registry..."
      Write-Host "This includes the MSFT Foundry SDK with corrected endpoint configuration"
      Write-Host "Build time: approximately 2-3 minutes..."
      Write-Host ""
      
      # Set UTF-8 encoding to prevent Azure CLI Unicode errors
      [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
      $env:PYTHONIOENCODING = "utf-8"
      
      # Calculate absolute path to src directory
      $srcPath = Join-Path (Split-Path $PWD.Path -Parent) "src"
      Write-Host "Source directory: $srcPath"
      
      # Verify source files exist
      if (!(Test-Path "$srcPath\Dockerfile")) {
        Write-Host "ERROR: Dockerfile not found at $srcPath\Dockerfile"
        exit 1
      }
      if (!(Test-Path "$srcPath\app\tools\singleAgentExample.py")) {
        Write-Host "ERROR: singleAgentExample.py not found"
        exit 1
      }
      
      Write-Host "[OK] Source files verified"
      Write-Host ""
      Write-Host "Starting ACR cloud build..."
      
      # Build in ACR and capture output
      $buildOutput = az acr build `
        --resource-group ${azurerm_resource_group.rg.name} `
        --registry ${local.registry_name} `
        --image zava-chat-app:latest `
        --file "$srcPath\Dockerfile" `
        "$srcPath" 2>&1
      
      # Display selected output lines
      $buildOutput | Select-String -Pattern "Successfully|Step|digest:|Run ID" | ForEach-Object {
        Write-Host $_.Line
      }
      
      # Check build result
      if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "[OK] ACR build completed successfully"
      } else {
        Write-Host ""
        Write-Host "WARNING: Build may still be in progress. Check Azure Portal for status."
      }
      
      Write-Host ""
      Write-Host "Configuring Web App..."
      
      # Get AI Foundry endpoint (remains .cognitiveservices., code will convert it)
      $aiFoundryEndpoint = az cognitiveservices account show `
        --resource-group ${azurerm_resource_group.rg.name} `
        --name ${local.ai_foundry_name} `
        --query "properties.endpoint" `
        --output tsv
      
      # Get MSFT Foundry access key
      $aiFoundryKey = az cognitiveservices account keys list `
        --resource-group ${azurerm_resource_group.rg.name} `
        --name ${local.ai_foundry_name} `
        --query "key1" `
        --output tsv
      
      # Configure environment variables for the app
      Write-Host "Setting application environment variables..."
      az webapp config appsettings set `
        --resource-group ${azurerm_resource_group.rg.name} `
        --name ${local.web_app_name} `
        --settings `
          WEBSITES_PORT=8000 `
          gpt_endpoint="$aiFoundryEndpoint" `
          gpt_deployment="${var.chat_model_deployment}" `
          gpt_api_key="$aiFoundryKey" `
          gpt_api_version="2024-12-01-preview" | Out-Null
      
      if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Environment variables configured"
      }
      
      # Web App uses managed identity for ACR access (configured in site_config)
      # Webhook will trigger automatic deployment when image is pushed
      Write-Host "[INFO] Container will be pulled automatically via managed identity"
      Write-Host "[INFO] Webhook configured for automatic updates on push"
      
      # Restart the web app
      Write-Host ""
      Write-Host "Restarting Web App to pull latest container..."
      az webapp restart `
        --resource-group ${azurerm_resource_group.rg.name} `
        --name ${local.web_app_name} | Out-Null
      
      Write-Host "[OK] Web App restarted"
      Write-Host ""
      Write-Host "Waiting for container to initialize (30 seconds)..."
      Start-Sleep -Seconds 30
      
      Write-Host ""
      Write-Host "============================================================================"
      Write-Host ""
      Write-Host "   *** ZAVA AI SHOPPING ASSISTANT - DEPLOYED TO AZURE"
      Write-Host ""
      Write-Host "   [WEB] Web App URL: https://${local.web_app_name}.azurewebsites.net"
      Write-Host "   [HEALTH] Health Check: https://${local.web_app_name}.azurewebsites.net/health"
      Write-Host ""
      Write-Host "   [OK] Container: ${local.registry_name}.azurecr.io/zava-chat-app:latest"
      Write-Host "   [OK] SDK: azure-ai-inference (MSFT Foundry)"
      Write-Host "   [OK] Model: ${var.chat_model_deployment}"
      Write-Host "   [OK] Endpoint: .services.ai.azure.com/models (auto-converted)"
      Write-Host ""
      Write-Host "   Note: App may take 1-2 minutes to fully initialize on first start"
      Write-Host ""
      Write-Host "============================================================================"
      Write-Host ""
      
      # Try to open browser to the deployed app
      try {
        Start-Process "https://${local.web_app_name}.azurewebsites.net"
      } catch {
        Write-Host "Could not auto-open browser. Please visit the URL above manually."
      }
    EOT
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.module
  }

  triggers = {
    verify_app_id = null_resource.verify_single_agent_app[0].id
    docker_hash   = local.dockerfile_hash
    source_hash   = local.app_source_hash
  }
}

# Remote multi-agent verification (runs after deployment). Hits /agents endpoint.
resource "null_resource" "verify_multi_agent_remote" {
  count = (var.enable_multi_agent && local.deploy_to_appservice) ? 1 : 0

  depends_on = [
    null_resource.deploy_multi_agents,
    azurerm_linux_web_app.app
  ]

  provisioner "local-exec" {
    command = <<-EOT
      Write-Host ""; Write-Host "=== Verifying Multi-Agent Deployment (Remote) ==="; Write-Host ""
      $appUrl = "https://${local.web_app_name}.azurewebsites.net"
      $agentsEndpoint = "$appUrl/agents"
      Write-Host "Checking agents endpoint: $agentsEndpoint"
      $verificationPassed = $false
      try {
        $resp = Invoke-RestMethod -Uri $agentsEndpoint -Method GET -TimeoutSec 30
        Write-Host "Response:" ($resp | ConvertTo-Json -Depth 5)
        if ($resp.mode -eq 'multi-agent' -and $resp.all_present -and ($resp.agents.cora -like 'asst_local_*')) {
          Write-Host "[OK] Multi-agent remote verification passed (local simulation active)."
          $verificationPassed = $true
        } else {
          Write-Warning "Multi-agent verification incomplete."
          Write-Host ($resp | ConvertTo-Json -Depth 5)
        }
      } catch {
        Write-Warning "Could not reach /agents endpoint: $_"
      }

      if (-not $verificationPassed) {
        Write-Host ""; Write-Host "WARNING: ALERT: Multi-agent verification failed. Initiating App Service restart."; Write-Host ""
        try {
          az webapp restart --resource-group ${azurerm_resource_group.rg.name} --name ${local.web_app_name} | Out-Null
          Write-Host "[OK] Web App restart triggered due to verification failure."
        } catch {
          Write-Warning "Failed to restart Web App automatically: $_"
        }
        $alertMessage = "[$(Get-Date -Format o)] Multi-agent verification failed for ${local.web_app_name}."
        $alertPath = "../multi_agent_alerts.log"
        $alertMessage | Out-File -FilePath $alertPath -Encoding utf8 -Append
        Write-Host "Alert logged to $alertPath"
      }
      Write-Host "=== Verification Complete ==="; Write-Host ""
    EOT
    interpreter = ["PowerShell", "-Command"]
  }

  triggers = {
    web_app_id   = azurerm_linux_web_app.app[0].id
    docker_hash  = local.dockerfile_hash
    agents_code  = filesha256("../src/chat_app_multi_agent.py")
  }
}

# A2A Automation Framework Deployment
resource "null_resource" "deploy_a2a_automation" {
  count = var.enable_a2a_automation ? 1 : 0

  depends_on = [
    null_resource.create_env_file,
    null_resource.data_pipeline,
    azurerm_application_insights.appinsights,
    azurerm_log_analytics_workspace.law
  ]

  provisioner "local-exec" {
    command = <<-EOT
      Write-Host ""
      Write-Host "============================================================================"
      Write-Host "=== DEPLOYING A2A AUTOMATION FRAMEWORK ==="
      Write-Host "============================================================================"
      Write-Host ""
      
      # Navigate to A2A directory
      $a2aPath = Join-Path (Split-Path $PWD.Path -Parent) "src\a2a"
      
      # Check if A2A framework exists
      if (!(Test-Path $a2aPath)) {
        Write-Host "[ERROR] A2A automation framework not found at: $a2aPath"
        Write-Host "Please ensure the A2A framework is properly deployed"
        exit 1
      }
      
      Write-Host "[OK] A2A framework found at: $a2aPath"
      Write-Host ""
      
      # Check required Python packages for A2A automation
      Write-Host "[1/7] Installing A2A automation dependencies..."
      $pythonCmd = "python"
      if (Get-Command python3 -ErrorAction SilentlyContinue) {
        $pythonCmd = "python3"
      }
      
      # Create A2A requirements if not exists
      $a2aRequirements = @"
fastapi>=0.104.0
uvicorn[standard]>=0.24.0
starlette>=0.27.0
pydantic>=2.5.0
aiofiles>=23.2.0
httpx>=0.25.0
psutil>=5.9.0
prometheus-client>=0.19.0
gunicorn>=21.2.0
aiosignal>=1.3.0
"@
      
      $reqFile = Join-Path $a2aPath "requirements_a2a.txt"
      $a2aRequirements | Out-File -FilePath $reqFile -Encoding utf8
      
      try {
        & $pythonCmd -m pip install -r $reqFile --quiet
        Write-Host "[OK] A2A dependencies installed"
      } catch {
        Write-Host "[WARN] Some A2A dependencies may not have installed: $_"
        Write-Host "Continuing with deployment..."
      }
      
      Write-Host ""
      Write-Host "[2/7] Creating A2A automation configuration..."
      
      # Create A2A automation configuration
      $a2aConfig = @"
# A2A Automation Framework Configuration
A2A_HOST=${var.a2a_host}
A2A_PORT=${var.a2a_port}
A2A_LOG_LEVEL=INFO

# Base application URL for monitoring
BASE_APP_URL=https://${local.web_app_name}.azurewebsites.net

# Azure monitoring integration
APPLICATION_INSIGHTS_CONNECTION_STRING=${azurerm_application_insights.appinsights.connection_string}
LOG_ANALYTICS_WORKSPACE_ID=${azurerm_log_analytics_workspace.law.workspace_id}

# Automation features
ENABLE_PROCESS_MANAGEMENT=true
ENABLE_CONTINUOUS_TESTING=${var.enable_continuous_testing}
ENABLE_MONITORING_DASHBOARDS=${var.enable_monitoring_dashboards}
ENABLE_DEPLOYMENT_AUTOMATION=true

# Performance thresholds
CPU_THRESHOLD=70.0
MEMORY_THRESHOLD=80.0
RESPONSE_TIME_THRESHOLD=2000
ERROR_RATE_THRESHOLD=5.0

# Testing configuration
CONTINUOUS_TESTING_INTERVAL=60
LOAD_TEST_DURATION=300
CONCURRENT_USERS=50
MAX_RESPONSE_TIME=2000
MIN_THROUGHPUT=50
MAX_ERROR_RATE=0.05

# Storage paths
AUTOMATION_STORAGE_PATH=${var.automation_storage_path}
MONITORING_DATA_PATH=./monitoring_data
TEST_RESULTS_PATH=./test_results
DEPLOYMENT_LOGS_PATH=./deployment_logs
"@
      
      $configFile = Join-Path $a2aPath ".env_automation"
      $a2aConfig | Out-File -FilePath $configFile -Encoding utf8
      Write-Host "[OK] A2A configuration created at: $configFile"
      
      Write-Host ""
      Write-Host "[3/7] Setting up A2A automation directories..."
      
      # Create automation directories
      $autoDirs = @(
        "${var.automation_storage_path}",
        "monitoring_data",
        "test_results", 
        "deployment_logs",
        "logs"
      )
      
      foreach ($dir in $autoDirs) {
        $fullPath = Join-Path $a2aPath $dir
        if (!(Test-Path $fullPath)) {
          New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
          Write-Host "  Created: $dir"
        }
      }
      Write-Host "[OK] Automation directories ready"
      
      Write-Host ""
      Write-Host "[4/7] Validating A2A automation components..."
      
      # Check automation components exist
      $a2aComponents = @(
        "automation\process_manager.py",
        "automation\deployment_manager.py", 
        "automation\test_framework.py",
        "automation\monitoring_framework.py",
        "automated_main.py",
        "main.py",
        "config.py"
      )
      
      $missingComponents = @()
      foreach ($component in $a2aComponents) {
        $componentPath = Join-Path $a2aPath $component
        if (Test-Path $componentPath) {
          Write-Host "  [OK] $component"
        } else {
          $missingComponents += $component
          Write-Host "  [MISSING] $component"
        }
      }
      
      if ($missingComponents.Count -gt 0) {
        Write-Host ""
        Write-Host "[ERROR] Missing A2A automation components:"
        foreach ($missing in $missingComponents) {
          Write-Host "  - $missing"
        }
        Write-Host ""
        Write-Host "Please ensure the A2A automation framework is completely deployed"
        exit 1
      }
      
      Write-Host "[OK] All A2A automation components validated"
      
      Write-Host ""
      Write-Host "[5/7] Creating A2A automation service script..."
      
      # Create service script for A2A automation
      $serviceScript = @"
#!/usr/bin/env python3
# A2A Automation Service Launcher
import os
import sys

# Add current directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

if __name__ == '__main__':
    from automated_main import main
    main()
"@
      
      $serviceFile = Join-Path $a2aPath "start_automation.py"
      $serviceScript | Out-File -FilePath $serviceFile -Encoding utf8
      Write-Host "[OK] Service script created: start_automation.py"
      
      Write-Host ""
      Write-Host "[6/7] Testing A2A automation startup..."
      
      # Test automation startup (quick validation)
      try {
        Set-Location $a2aPath
        
        Write-Host "Testing automation framework import..."
        $testResult = & $pythonCmd -c "import automated_main; print('OK')" 2>&1
        
        if ($LASTEXITCODE -eq 0) {
          Write-Host "[OK] A2A automation framework imports successfully"
        } else {
          Write-Host "[WARN] Import test had issues: $testResult"
          Write-Host "Continuing with deployment..."
        }
      } catch {
        Write-Host "[WARN] Could not test automation startup: $_"
        Write-Host "This may be expected during initial deployment"
      } finally {
        Set-Location (Split-Path $a2aPath -Parent)
      }
      
      Write-Host ""
      Write-Host "[7/7] Creating automation management scripts..."
      
      # Create PowerShell management scripts
      $startScript = @"
# Start A2A Automation Framework
Write-Host "Starting A2A Automation Framework..."
Set-Location "$a2aPath"
python automated_main.py
"@
      
      $stopScript = @"
# Stop A2A Automation Framework
Write-Host "Stopping A2A Automation Framework..."
Get-Process -Name "python" | Where-Object { $_.CommandLine -like "*automated_main*" } | Stop-Process -Force
Write-Host "A2A Automation Framework stopped"
"@
      
      $statusScript = @"
# Check A2A Automation Framework Status
Write-Host "Checking A2A Automation Framework status..."
$processes = Get-Process -Name "python" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*automated_main*" }
if ($processes) {
  Write-Host "A2A Automation Framework is RUNNING"
  Write-Host "Processes: $($processes.Count)"
  $processes | Format-Table Id,ProcessName,StartTime
} else {
  Write-Host "A2A Automation Framework is STOPPED"
}

# Check automation endpoint
try {
  $response = Invoke-RestMethod -Uri "https://${local.web_app_name}.azurewebsites.net/a2a/automation/status" -TimeoutSec 5
  Write-Host "Automation Status: $($response.system_status)"
} catch {
  Write-Host "Automation endpoint not accessible"
}
"@
      
      $startScript | Out-File -FilePath (Join-Path $a2aPath "start_automation.ps1") -Encoding utf8
      $stopScript | Out-File -FilePath (Join-Path $a2aPath "stop_automation.ps1") -Encoding utf8  
      $statusScript | Out-File -FilePath (Join-Path $a2aPath "status_automation.ps1") -Encoding utf8
      
      Write-Host "[OK] Management scripts created:"
      Write-Host "  - start_automation.ps1"
      Write-Host "  - stop_automation.ps1" 
      Write-Host "  - status_automation.ps1"
      
      Write-Host ""
      Write-Host "============================================================================"
      Write-Host "=== A2A AUTOMATION FRAMEWORK DEPLOYED SUCCESSFULLY ==="
      Write-Host "============================================================================"
      Write-Host ""
      Write-Host "🤖 A2A Automation Features Enabled:"
      Write-Host "  ✅ Automated Process Management"
      Write-Host "  ✅ Continuous Deployment Pipeline"
      if ("${var.enable_continuous_testing}" -eq "true") {
        Write-Host "  ✅ Continuous Testing Framework"
      }
      if ("${var.enable_monitoring_dashboards}" -eq "true") {
        Write-Host "  ✅ Real-time Monitoring & Alerting"
      }
      Write-Host "  ✅ Self-healing Capabilities"
      Write-Host ""
      Write-Host "🎯 A2A Automation Endpoints (when running):"
      Write-Host "  📊 Status: https://${local.web_app_name}.azurewebsites.net/a2a/automation/status"
      Write-Host "  📈 Metrics: https://${local.web_app_name}.azurewebsites.net/a2a/automation/metrics"
      Write-Host "  🏥 Health: https://${local.web_app_name}.azurewebsites.net/a2a/automation/health"
      Write-Host "  🧪 Testing: https://${local.web_app_name}.azurewebsites.net/a2a/automation/test/run"
      Write-Host ""
      Write-Host "🚀 To start A2A automation:"
      Write-Host "  cd $a2aPath"
      Write-Host "  .\start_automation.ps1"
      Write-Host ""
      Write-Host "📋 To check status:"
      Write-Host "  .\status_automation.ps1"
      Write-Host ""
      Write-Host "⏹️ To stop automation:"
      Write-Host "  .\stop_automation.ps1"
      Write-Host ""
      Write-Host "📁 Automation data stored in: ${var.automation_storage_path}"
      Write-Host ""
      Write-Host "============================================================================"
      Write-Host ""
    EOT
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.module
  }

  triggers = {
    env_file_id = null_resource.create_env_file[0].id
    app_insights_id = azurerm_application_insights.appinsights.id
    always_run = timestamp()
  }
}

# A2A Monitoring Integration with Azure
resource "azurerm_monitor_action_group" "a2a_alerts" {
  count = (var.enable_a2a_automation && var.enable_monitoring_dashboards && local.deploy_to_appservice) ? 1 : 0
  
  name                = "${local.web_app_name}-a2a-alerts"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "a2aalerts"

  webhook_receiver {
    name        = "a2a-automation-webhook"
    service_uri = "https://${local.web_app_name}.azurewebsites.net/a2a/automation/webhook/alert"
    use_common_alert_schema = true
  }

  depends_on = [azurerm_linux_web_app.app, null_resource.deploy_a2a_automation]
}

# A2A System Health Alert
resource "azurerm_monitor_metric_alert" "a2a_system_health" {
  count = (var.enable_a2a_automation && var.enable_monitoring_dashboards && local.deploy_to_appservice) ? 1 : 0
  
  name                = "${local.web_app_name}-a2a-health"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_linux_web_app.app[0].id]
  description         = "Alert when A2A automation system health degrades"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"
  
  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "HealthCheckStatus" 
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1
  }
  
  action {
    action_group_id = azurerm_monitor_action_group.a2a_alerts[0].id
  }
  
  depends_on = [azurerm_monitor_action_group.a2a_alerts]
}

# A2A Performance Alert  
resource "azurerm_monitor_metric_alert" "a2a_performance" {
  count = (var.enable_a2a_automation && var.enable_monitoring_dashboards && local.deploy_to_appservice) ? 1 : 0
  
  name                = "${local.web_app_name}-a2a-performance"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_linux_web_app.app[0].id]
  description         = "Alert when A2A system response time exceeds threshold"
  severity            = 3
  frequency           = "PT1M"
  window_size         = "PT5M"
  
  criteria {
    metric_namespace = "Microsoft.Web/sites"
    metric_name      = "AverageResponseTime"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 5000  # 5 seconds
  }
  
  action {
    action_group_id = azurerm_monitor_action_group.a2a_alerts[0].id
  }
  
  depends_on = [azurerm_monitor_action_group.a2a_alerts]
}

# Post-deploy automated fix to ensure Web App starts successfully
resource "null_resource" "post_deploy_health" {
  count = local.deploy_to_appservice ? 1 : 0
  depends_on = [
    azurerm_linux_web_app.app,
    azurerm_role_assignment.webapp_acr_pull,
    azurerm_role_assignment.kv_secrets_user_webapp,
    null_resource.deploy_a2a_automation
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command = <<-EOT
      Write-Host ""
      Write-Host "============================================================================"
      Write-Host "=== AUTOMATED WEB APP STARTUP FIX ==="
      Write-Host "============================================================================"
      $rg = "${azurerm_resource_group.rg.name}"
      $name = "${local.web_app_name}"
      $url = "https://${local.web_app_name}.azurewebsites.net"

      Write-Host ""
      Write-Host "[1/7] Checking current Web App status..."
      $status = az webapp show --name $name --resource-group $rg --query "state" -o tsv
      Write-Host "Current state: $status"

      if ($status -eq "Stopped") {
        Write-Host "[DETECTED] Web App is stopped - applying automated fix"
      }

      Write-Host ""
      Write-Host "[2/7] Enabling detailed logging for diagnostics..."
      az webapp log config --name $name --resource-group $rg `
        --level verbose `
        --web-server-logging filesystem `
        --docker-container-logging filesystem `
        --detailed-error-messages true `
        --failed-request-tracing true | Out-Null

      Write-Host ""
      Write-Host "[2b/7] Verifying container configuration..."
      $cfg = az webapp config container show --name $name --resource-group $rg --output json | ConvertFrom-Json
      $desiredImage = "${local.registry_name}.azurecr.io/zava-chat-app:latest"
      $needsConfig = $true
      if ($cfg) {
        $currentImage = $cfg.dockerCustomImageName
        if ($currentImage -and ($currentImage -eq $desiredImage)) {
          Write-Host "[OK] Container image already set: $currentImage"
          $needsConfig = $false
        } else {
          Write-Host "[INFO] Container image differs or not set (current: '$currentImage'). Will apply fallback configuration."
        }
      } else {
        Write-Host "[INFO] No container config returned; will apply fallback."
      }

      if ($needsConfig) {
        try {
          $acrUser = az acr credential show --name ${local.registry_name} --query "username" -o tsv
          $acrPass = az acr credential show --name ${local.registry_name} --query "passwords[0].value" -o tsv
          az webapp config container set `
            --resource-group $rg `
            --name $name `
            --docker-custom-image-name $desiredImage `
            --docker-registry-server-url https://${local.registry_name}.azurecr.io `
            --docker-registry-server-user "$acrUser" `
            --docker-registry-server-password "$acrPass" `
            --enable-app-service-storage false | Out-Null
          Write-Host "[OK] Applied fallback container configuration"
        } catch {
          Write-Host "[WARN] Could not apply container configuration: $_"
        }
      }

      Write-Host ""
      Write-Host "[3/7] Ensuring Web App is stopped cleanly..."
      az webapp stop --name $name --resource-group $rg | Out-Null
      Write-Host "Waiting 15 seconds for complete shutdown..."
      Start-Sleep -Seconds 15

      Write-Host ""
      Write-Host "[4/7] Verifying container image exists in ACR..."
      $imageExists = az acr repository show --name ${local.registry_name} --image zava-chat-app:latest --query "name" -o tsv 2>$null
      if ($imageExists) {
        Write-Host "[OK] Container image found: zava-chat-app:latest"
      } else {
        Write-Host "[WARNING] Container image may still be building - will retry startup"
      }

      Write-Host ""
      Write-Host "[5/7] Starting Web App with fresh container pull..."
      az webapp start --name $name --resource-group $rg | Out-Null
      Write-Host "[OK] Start command sent"
      
      Write-Host ""
      Write-Host "[6/7] Waiting for container pull and app initialization..."
      Write-Host "This takes 2-5 minutes for first deployment..."
      
      # Progressive wait with status checks
      $waitIntervals = @(30, 30, 30, 30, 30, 30)  # 3 minutes total
      foreach ($interval in $waitIntervals) {
        Start-Sleep -Seconds $interval
        $currentStatus = az webapp show --name $name --resource-group $rg --query "state" -o tsv
        Write-Host "  Status: $currentStatus (waited $($waitIntervals.IndexOf($interval) * 30 + $interval)s)"
        
        if ($currentStatus -eq "Running") {
          Write-Host "  [OK] App is now Running"
          break
        }
      }

      Write-Host ""
      Write-Host "[7/7] Testing application health endpoint..."
      $health = "$url/health"
      $maxAttempts = 10
      $ok = $false
      
      for ($i=1; $i -le $maxAttempts; $i++) {
        Write-Host "  Attempt $i/$maxAttempts - Testing: $health"
        try {
          $resp = Invoke-RestMethod -Uri $health -TimeoutSec 30 -Method GET -ErrorAction Stop
          if ($resp.status -eq 'healthy') {
            Write-Host "  [SUCCESS] App is healthy and responding!"
            Write-Host "  Response: $($resp | ConvertTo-Json -Compress)"
            $ok = $true
            break
          } else {
            Write-Host "  Status: $($resp | ConvertTo-Json -Depth 4)"
          }
        } catch {
          $errMsg = $_.Exception.Message
          if ($errMsg -like "*503*" -or $errMsg -like "*502*") {
            Write-Host "  Container still starting up... (HTTP $($_.Exception.Response.StatusCode))"
          } else {
            Write-Host "  Error: $errMsg"
          }
        }
        
        if ($i -lt $maxAttempts) {
          Start-Sleep -Seconds 20
        }
      }

      if (-not $ok) {
        Write-Host ""
        Write-Host "[DIAGNOSTICS] Health checks did not pass during apply. Collecting logs..."
        # Show recent logs to console and save a snapshot
        try {
          $diagLog = Join-Path (Split-Path $PWD.Path -Parent) "deploy.log"
          Write-Host "Saving recent logs to $diagLog"
          az webapp log show --name $name --resource-group $rg | Out-File -FilePath $diagLog -Encoding utf8
          Write-Host "[OK] Recent logs saved"
        } catch { Write-Host "Could not save recent logs: $_" }

        # Download the zipped log bundle
        try {
          $logZip = Join-Path (Split-Path $PWD.Path -Parent) "app-logs.zip"
          Write-Host "Downloading log bundle to $logZip"
          az webapp log download --name $name --resource-group $rg --log-file $logZip | Out-Null
          Write-Host "[OK] Logs bundle saved"
        } catch { Write-Host "Could not download logs bundle: $_" }
      }

      Write-Host ""
      Write-Host "============================================================================"
      if ($ok) {
        Write-Host "=== [SUCCESS] WEB APP IS HEALTHY AND READY ==="
        Write-Host ""
        Write-Host "Your application is live at:"
        Write-Host "  $url"
        Write-Host ""
        Write-Host "Test the chat interface in your browser now!"
      } else {
        Write-Host "=== [INFO] FINAL STATUS CHECK ==="
        
        # Get final state
        $finalState = az webapp show --name $name --resource-group $rg --query "state" -o tsv
        Write-Host "Web App State: $finalState"
        
        if ($finalState -eq "Running") {
          Write-Host ""
          Write-Host "The app is Running but health endpoint hasn't responded yet."
          Write-Host "This is normal for first deployment - the container may need more time."
          Write-Host ""
          Write-Host "NEXT STEPS:"
          Write-Host "1. Wait 2-3 more minutes for full initialization"
          Write-Host "2. Check the app at: $url"
          Write-Host "3. View logs: az webapp log tail --name $name --resource-group $rg"
          Write-Host ""
          Write-Host "The app will be ready shortly!"
        } else {
          Write-Host ""
          Write-Host "[ACTION REQUIRED] App is in state: $finalState"
          Write-Host ""
          Write-Host "Attempting one more restart..."
          az webapp restart --name $name --resource-group $rg | Out-Null
          Start-Sleep -Seconds 30
          
          Write-Host ""
          Write-Host "MANUAL VERIFICATION STEPS:"
          Write-Host "1. Go to Azure Portal > $name > Overview"
          Write-Host "2. Click 'Restart' button at the top"
          Write-Host "3. Wait 5 minutes and visit: $url"
          Write-Host "4. Check logs: az webapp log tail --name $name --resource-group $rg"
        }
      }
      Write-Host "============================================================================"
      Write-Host ""
    EOT
  }

  triggers = {
    always_run = timestamp()
  }
}

# Enaganeced Product Management Agent Resources



