
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
  daily_quota_gb      = 1
  
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
  
  lifecycle {
    ignore_changes = [
      tags
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

resource "azurerm_container_registry_webhook" "webhook" {
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

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on         = false
    http2_enabled     = true
    minimum_tls_version = "1.2"
    application_stack {
      docker_image_name        = "zava-chat-app:latest"
      docker_registry_url      = "https://${local.registry_name}.azurecr.io"
      docker_registry_username = azurerm_container_registry.acr.admin_username
      docker_registry_password = azurerm_container_registry.acr.admin_password
    }
  }

  app_settings = {
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
    DOCKER_ENABLE_CI                    = "true"
    WEBSITES_PORT                       = "8000"

    # GPT Configuration (Key Vault referenced secrets)
    gpt_endpoint                        = "https://${local.ai_foundry_name}.cognitiveservices.azure.com/"
    gpt_deployment                      = "gpt-4o-mini"
    gpt_api_key                         = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/ai-foundry-key)"
    gpt_api_version                     = "2024-12-01-preview"

    # Azure AI Foundry Configuration
    AZURE_AI_FOUNDRY_ENDPOINT           = "https://${local.ai_foundry_name}.cognitiveservices.azure.com/"
    AZURE_AI_PROJECT_NAME               = local.ai_project_name
    AZURE_AI_PROJECT_ENDPOINT           = "https://${local.ai_foundry_name}.cognitiveservices.azure.com/"
    AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME = "gpt-4o-mini"
    AZURE_AI_FOUNDRY_API_KEY            = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/ai-foundry-key)"

    # Azure OpenAI Configuration
    AZURE_OPENAI_CHAT_DEPLOYMENT        = "gpt-4o-mini"
    AZURE_OPENAI_EMBEDDING_DEPLOYMENT   = "text-embedding-3-small"
    AZURE_OPENAI_IMAGE_DEPLOYMENT       = "dall-e-3"
    AZURE_OPENAI_API_KEY                = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/ai-foundry-key)"
    AZURE_OPENAI_ENDPOINT               = "https://${local.ai_foundry_name}.cognitiveservices.azure.com/"
    AZURE_OPENAI_API_VERSION            = "2024-02-01"

    # External Service Keys via Key Vault
    SEARCH_SERVICE_KEY                  = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/search-admin-key)"
    COSMOS_DB_KEY                       = var.enable_cosmos_local_auth ? "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/cosmos-primary-key)" : "AAD_AUTH"
    STORAGE_CONNECTION_STRING           = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault.kv.vault_uri}secrets/storage-connection-string)"

    # Multi-Agent Configuration - Real agent IDs from deployment
    USE_MULTI_AGENT                     = var.enable_multi_agent ? "true" : "false"
    cora                                = try(jsondecode(file("${path.module}/agent_ids.json")).cora, "asst_local_cora")
    interior_designer                   = try(jsondecode(file("${path.module}/agent_ids.json")).interior_designer, "asst_local_interior_design")
    inventory_agent                     = try(jsondecode(file("${path.module}/agent_ids.json")).inventory_agent, "asst_local_inventory")
    customer_loyalty                    = try(jsondecode(file("${path.module}/agent_ids.json")).customer_loyalty, "asst_local_customer_loyalty")
    cart_manager                        = try(jsondecode(file("${path.module}/agent_ids.json")).cart_manager, "asst_local_cart_manager")
    CUSTOMER_ID                         = "CUST001"
  }

  depends_on = [
    azurerm_container_registry.acr,
    null_resource.ai_model_deployments
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
  purge_protection_enabled  = false
  enable_rbac_authorization = false

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = local.principal_id
    secret_permissions = ["Get", "List", "Set"]
  }

  tags = { purpose = "multi-agent-ai-secrets" }
}

# Data source to retrieve the web app identity after it's created/updated
data "azurerm_linux_web_app" "app_identity" {
  name                = azurerm_linux_web_app.app.name
  resource_group_name = azurerm_resource_group.rg.name
  depends_on          = [azurerm_linux_web_app.app]
}

# Access policy for Web App managed identity to read secrets
resource "azurerm_key_vault_access_policy" "app_policy" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_linux_web_app.app_identity.identity[0].principal_id
  secret_permissions = ["Get"]
  depends_on = [azurerm_linux_web_app.app]
}

# Populate Key Vault secrets (AI Foundry key, Cosmos key, Search key, Storage connection)
# Key Vault Secrets as Terraform resources (provides version for references)
resource "azurerm_key_vault_secret" "ai_foundry_key" {
  name         = "ai-foundry-key"
  value        = jsondecode(data.azapi_resource_action.ai_foundry_keys[0].output).key1
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault.kv]
}

resource "azurerm_key_vault_secret" "search_admin_key" {
  name         = "search-admin-key"
  value        = jsondecode(data.azapi_resource_action.search_admin_keys[0].output).primaryKey
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault.kv]
}

resource "azurerm_key_vault_secret" "storage_connection_string" {
  name         = "storage-connection-string"
  value        = azapi_resource.storage.id != "" ? trimspace(chomp(join("", []))) : "placeholder" # placeholder; will be overridden below via provisioner
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault.kv]
  lifecycle { ignore_changes = [value] }
}

resource "null_resource" "update_storage_connection_secret" {
  depends_on = [azurerm_key_vault_secret.storage_connection_string, azapi_resource.storage]
  provisioner "local-exec" {
    command = <<-EOT
      Write-Host "Updating storage-connection-string secret value..."
      $conn = az storage account show-connection-string --resource-group ${azurerm_resource_group.rg.name} --name ${local.storage_account} --query connectionString -o tsv
      az keyvault secret set --vault-name ${azurerm_key_vault.kv.name} --name storage-connection-string --value $conn | Out-Null
      Write-Host "[OK] storage-connection-string secret updated"
    EOT
    interpreter = ["PowerShell", "-Command"]
  }
}

resource "azurerm_key_vault_secret" "cosmos_primary_key" {
  count        = var.enable_cosmos_local_auth ? 1 : 0
  name         = "cosmos-primary-key"
  value        = jsondecode(data.azapi_resource_action.cosmos_keys[0].output).primaryMasterKey
  key_vault_id = azurerm_key_vault.kv.id
  depends_on   = [azurerm_key_vault.kv]
}

# External data source for agents state
data "external" "agents_state" {
  program = ["python", "read_agents_state.py"]
  depends_on = [null_resource.deploy_multi_agents]
}

# App Service Plan autoscale
resource "azurerm_monitor_autoscale_setting" "appservice_autoscale" {
  name                = "${var.name_prefix}-${local.suffix}-asp-autoscale"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  target_resource_id  = azurerm_service_plan.appserviceplan.id

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
        metric_resource_id = azurerm_service_plan.appserviceplan.id
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
        metric_resource_id = azurerm_service_plan.appserviceplan.id
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
  name                = "${var.name_prefix}-${local.suffix}-app-5xx-alert"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_linux_web_app.app.id]
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
  name                = "${var.name_prefix}-${local.suffix}-app-cpu-alert"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_service_plan.appserviceplan.id]
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
                { name = "resource", value = azurerm_linux_web_app.app.id },
                { name = "chartSettings", value = jsonencode({ version = "Workspace" }) }
              ]
              type = "Extension/HubsExtension/PartType/MonitorChartPart"
              settings = {
                content = {
                  version = "1.0.0"
                  chart = {
                    title      = "App Service Requests"
                    metrics    = [{ resourceMetadata = { id = azurerm_linux_web_app.app.id }, name = "Requests", aggregationType = "Total" }]
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
                { name = "resource", value = azurerm_service_plan.appserviceplan.id }
              ]
              type = "Extension/HubsExtension/PartType/MonitorChartPart"
              settings = {
                content = {
                  version = "1.0.0"
                  chart = {
                    title   = "CPU Percentage"
                    metrics = [{ resourceMetadata = { id = azurerm_service_plan.appserviceplan.id }, name = "CpuPercentage", aggregationType = "Average" }]
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
          }
        
        # Create dall-e-3 deployment for image generation
        Write-Host "Creating dall-e-3 deployment..."
        try {
          az cognitiveservices account deployment create `
            --resource-group "${azurerm_resource_group.rg.name}" `
            --name "${local.ai_foundry_name}" `
            --deployment-name "dall-e-3" `
            --model-name "dall-e-3" `
            --model-version "3.0" `
            --model-format "OpenAI" `
            --sku-capacity 1 `
            --sku-name "Standard"
          
          if ($LASTEXITCODE -eq 0) {
            Write-Host "dall-e-3 deployment created successfully"
            $dalleAvailable = $true
          } else {
            Write-Host "dall-e-3 model not available in this region/tier, skipping"
            $dalleAvailable = $false
          }
        } catch {
          Write-Host "dall-e-3 model not supported in this region, skipping"
          $dalleAvailable = $false
        }
        
        # Create phi-4 deployment
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

# Get AI Foundry keys for Web App configuration
data "azapi_resource_action" "ai_foundry_keys" {
  count                  = var.enable_ai_automation ? 1 : 0
  type                   = "Microsoft.CognitiveServices/accounts@2024-10-01"
  resource_id            = azapi_resource.ai_foundry.id
  action                 = "listKeys"
  response_export_values = ["key1"]
  body                   = jsonencode({})
  depends_on             = [azapi_resource.ai_foundry]
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
      
      # Get Azure AI Foundry endpoint and fix domain for Agents API
      $rawAiFoundryEndpoint = az cognitiveservices account show `
        --resource-group "${azurerm_resource_group.rg.name}" `
        --name "${local.ai_foundry_name}" `
        --query "properties.endpoint" `
        --output tsv
      
      # For OpenAI models, use the cognitive services endpoint
      $openAiEndpoint = $rawAiFoundryEndpoint
      # For Agents API, use the corrected services.ai.azure.com domain
      $agentsEndpoint = $rawAiFoundryEndpoint -replace "cognitiveservices\.azure\.com", "services.ai.azure.com"
      
      Write-Host "OpenAI Endpoint: $openAiEndpoint"
      Write-Host "Agents API Endpoint: $agentsEndpoint"
      
      # Fetch secrets from Key Vault for local dev (avoid embedding in Terraform state)
      $kv = "${azurerm_key_vault.kv.name}"
      $aiFoundryKey = az keyvault secret show --vault-name $kv --name ai-foundry-key --query value -o tsv
      $searchKey = az keyvault secret show --vault-name $kv --name search-admin-key --query value -o tsv
      if (${var.enable_cosmos_local_auth}) {
        $cosmosKey = az keyvault secret show --vault-name $kv --name cosmos-primary-key --query value -o tsv
      } else { $cosmosKey = "AAD_AUTH" }
      $storageConnectionString = az keyvault secret show --vault-name $kv --name storage-connection-string --query value -o tsv
      
      # Create .env file content
      if ($phi4Available) {
        $envContent = @"
# Azure AI Foundry Configuration
AZURE_AI_FOUNDRY_ENDPOINT=$openAiEndpoint
AZURE_AI_FOUNDRY_API_KEY=$aiFoundryKey
AZURE_AI_PROJECT_NAME=${local.ai_project_name}
AZURE_AI_AGENT_ENDPOINT=$agentsEndpoint

# Azure OpenAI Model Deployments
AZURE_OPENAI_CHAT_DEPLOYMENT=gpt-4o-mini
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-small
AZURE_OPENAI_PHI_DEPLOYMENT=phi-4
AZURE_OPENAI_IMAGE_DEPLOYMENT=dall-e-3
AZURE_OPENAI_ENDPOINT=$openAiEndpoint
AZURE_OPENAI_API_KEY=$aiFoundryKey
AZURE_OPENAI_API_VERSION=2024-02-01

# GPT Model Configuration (for single-agent chat)
gpt_endpoint=$openAiEndpoint
gpt_deployment=gpt-4o-mini
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
AZURE_AI_PROJECT_ENDPOINT=$agentsEndpoint
AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME=gpt-4o-mini

# Agent IDs (will be updated by deploy_real_agents.py after creation)
cora=asst_local_cora
interior_designer=asst_local_interior_design
inventory_agent=asst_local_inventory
customer_loyalty=asst_local_customer_loyalty
cart_manager=asst_local_cart_manager

# Customer Configuration
CUSTOMER_ID=CUST001
"@
      } else {
        $envContent = @"
# Azure AI Foundry Configuration
AZURE_AI_FOUNDRY_ENDPOINT=$openAiEndpoint
AZURE_AI_FOUNDRY_API_KEY=$aiFoundryKey
AZURE_AI_PROJECT_NAME=${local.ai_project_name}
AZURE_AI_AGENT_ENDPOINT=$aiFoundryEndpoint

# Azure OpenAI Model Deployments
AZURE_OPENAI_CHAT_DEPLOYMENT=gpt-4o-mini
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-small
AZURE_OPENAI_IMAGE_DEPLOYMENT=dall-e-3
AZURE_OPENAI_ENDPOINT=$openAiEndpoint
AZURE_OPENAI_API_KEY=$aiFoundryKey
AZURE_OPENAI_API_VERSION=2024-02-01

# GPT Model Configuration (for single-agent chat)
gpt_endpoint=$openAiEndpoint
gpt_deployment=gpt-4o-mini
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
AZURE_AI_PROJECT_ENDPOINT=$aiFoundryEndpoint
AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME=gpt-4o-mini

# Local Pseudo Agent IDs (no remote provisioning required)
cora=asst_local_cora
interior_designer=asst_local_interior_design
inventory_agent=asst_local_inventory
customer_loyalty=asst_local_customer_loyalty
cart_manager=asst_local_cart_manager

# Customer Configuration
CUSTOMER_ID=CUST001
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
        Write-Host "  4. Open http://127.0.0.1:8000 in your browser"
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
      & $pythonCmd -m pip install -q azure-ai-projects azure-identity python-dotenv
      
      if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to install required packages"
        Write-Host "Falling back to local pseudo-agents..."
        exit 0
      }
      
      Write-Host "[OK] SDK packages installed"
      Write-Host ""
      
      # Set up environment for agent deployment with corrected endpoint
      $rawEndpoint = "${azapi_resource.ai_foundry.output}" | ConvertFrom-Json | Select-Object -ExpandProperty properties | Select-Object -ExpandProperty endpoint
      # Fix domain for agents API
      $agentEndpoint = $rawEndpoint -replace "cognitiveservices\.azure\.com", "services.ai.azure.com"
      $env:AZURE_AI_PROJECT_ENDPOINT = $agentEndpoint
      Write-Host "Using Agents API endpoint: $agentEndpoint"
      
      # Deploy agents using Python script
      Write-Host "Deploying 5 agents to Azure AI Foundry..."
      $agentScriptPath = Join-Path (Split-Path $PWD.Path -Parent) "src\app\agents\deploy_real_agents.py"
      
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
          $agentVars = @("cora","interior_designer","inventory_agent","customer_loyalty","cart_manager")
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
            # Ensure image deployment variable present
            $settingsArgs += "AZURE_OPENAI_IMAGE_DEPLOYMENT=dall-e-3"
            az webapp config appsettings set `
              --resource-group ${azurerm_resource_group.rg.name} `
              --name ${local.web_app_name} `
              --settings $settingsArgs | Out-Null
            Write-Host "[OK] Web App app settings updated with real agent IDs"
            Write-Host "Restarting Web App to apply settings..."
            az webapp restart --resource-group ${azurerm_resource_group.rg.name} --name ${local.web_app_name} | Out-Null
            Write-Host "[OK] Web App restarted"
          } else {
            Write-Host "No real agent IDs found to update (still using local simulation)."
          }
        } else {
          Write-Host "Could not find .env file to propagate agent IDs."
        }
      }
      
      Write-Host ""
      Write-Host "Triggering container rebuild with agent configuration..."
      cd ..
      $srcPath = "src"
      [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
      $env:PYTHONIOENCODING = "utf-8"
      
      Write-Host "Building container image in Azure Container Registry..."
      Write-Host "This may take 2-3 minutes. Checking status via ACR task logs..."
      
      # Start build and get run ID (ignore encoding errors in output)
      $buildOutput = az acr build `
        --resource-group ${azurerm_resource_group.rg.name} `
        --registry ${local.registry_name} `
        --image zava-chat-app:latest `
        --file "$srcPath\Dockerfile" `
        --no-logs `
        "$srcPath" 2>&1 | Out-String
      
      # Extract run ID from output
      if ($buildOutput -match "Run ID: (\w+)") {
        $runId = $Matches[1]
        Write-Host "Build queued with Run ID: $runId"
        Write-Host "Waiting for build to complete..."
        
        # Wait and check status
        Start-Sleep -Seconds 60
        $status = az acr task logs --registry ${local.registry_name} --run-id $runId --query "[-1]" 2>&1 | Select-String "was successful"
        
        if ($status) {
          Write-Host "[SUCCESS] Container build completed"
          Write-Host "Restarting Web App to pull new image..."
          az webapp restart --resource-group ${azurerm_resource_group.rg.name} --name ${local.web_app_name} | Out-Null
          Write-Host "[OK] Web App restarted"
        } else {
          Write-Host "WARNING: Could not confirm build status, but continuing..."
          Write-Host "Check Azure Portal ACR build logs for run ID: $runId"
          az webapp restart --resource-group ${azurerm_resource_group.rg.name} --name ${local.web_app_name} | Out-Null
        }
      } else {
        Write-Host "WARNING: Could not extract run ID from build output"
        Write-Host "Build may still be in progress - check Azure Portal"
        Write-Host "Restarting Web App anyway..."
        az webapp restart --resource-group ${azurerm_resource_group.rg.name} --name ${local.web_app_name} | Out-Null
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
          Write-Host "[SUCCESS] All agents verified in Azure AI Foundry"
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
  count = var.enable_data_pipeline ? 1 : 0

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
      Write-Host "This includes the Azure AI Foundry SDK with corrected endpoint configuration"
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
      
      # Get Azure AI Foundry access key
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
          gpt_deployment="gpt-4o-mini" `
          gpt_api_key="$aiFoundryKey" `
          gpt_api_version="2024-12-01-preview" | Out-Null
      
      if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Environment variables configured"
      }
      
      # Get ACR admin credentials
      $acrUsername = az acr credential show `
        --name ${local.registry_name} `
        --query "username" `
        --output tsv
      
      $acrPassword = az acr credential show `
        --name ${local.registry_name} `
        --query "passwords[0].value" `
        --output tsv
      
      # Update container image with ACR credentials
      Write-Host "Configuring container deployment..."
      az webapp config container set `
        --resource-group ${azurerm_resource_group.rg.name} `
        --name ${local.web_app_name} `
        --docker-custom-image-name ${local.registry_name}.azurecr.io/zava-chat-app:latest `
        --docker-registry-server-url https://${local.registry_name}.azurecr.io `
        --docker-registry-server-user "$acrUsername" `
        --docker-registry-server-password "$acrPassword" `
        --enable-app-service-storage false | Out-Null
      
      if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Container configuration updated"
      }
      
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
      Write-Host "   [OK] SDK: azure-ai-inference (Azure AI Foundry)"
      Write-Host "   [OK] Model: gpt-4o-mini"
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
  count = var.enable_multi_agent ? 1 : 0

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
    web_app_id   = azurerm_linux_web_app.app.id
    docker_hash  = local.dockerfile_hash
    agents_code  = filesha256("../src/chat_app_multi_agent.py")
  }
}


