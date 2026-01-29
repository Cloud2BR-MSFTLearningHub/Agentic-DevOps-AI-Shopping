resource_group_name = "RG-AI-Retail-DemoX0"
location            = "eastus2"
name_prefix         = "zava"

# App Service Plan SKU (change if quota blocks this tier)
app_service_sku     = "P0v3"

# Deployment target (appservice|containerapps)
deployment_target   = "containerapps"

# Enable multi-agent architecture
enable_multi_agent = true

# user_principal_id is optional - defaults to current Azure CLI user (az login)
