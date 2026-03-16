resource_group_name = "RG-AI-Retail-DemoX34"
location            = "eastus2"
name_prefix         = "zava"

# ---------------------------
# Deployment approach (pick one)
# ---------------------------
# Option A (default): Container Apps
deployment_target = "containerapps"

# Option B: App Service (Linux custom container)
# deployment_target = "appservice"
# app_service_sku   = "P0v3"  # change if quota blocks this tier

# Note: app_service_sku is only used when deployment_target = "appservice".

# Enable multi-agent architecture
enable_multi_agent = true

# --- Optional security hardening ---
# Microsoft Defender for Cloud (subscription-level).
# NOTE: In this repo, Defender is ENABLED BY DEFAULT via Terraform variable defaults and can incur costs.
# To opt out, explicitly set:
# enable_defender_for_cloud = false
#
# defender_for_cloud_tier   = "Standard"
# defender_for_cloud_plans  = ["ContainerRegistry", "Containers", "AppServices", "StorageAccounts", "KeyVaults"]

# Defender for Cloud DevOps security connectors (GHAS aggregation dashboard)
# This repo can provision the connector resources, but GitHub/ADO authorization requires an interactive consent step
# in the Azure portal unless you supply a one-time OAuth code.
# NOTE: In this repo, DevOps security connector provisioning is ENABLED BY DEFAULT via Terraform variable defaults.
# To opt out, explicitly set:
# enable_defender_devops_security = false
#
# By default, this repo provisions BOTH GitHub and Azure DevOps connector resources.
# You can turn off either side explicitly:
# enable_defender_devops_security_github = true
# enable_defender_devops_security_ado    = true
# defender_devops_github_connector_name = "github-connector"
# defender_devops_ado_connector_name    = "ado-connector"
# defender_devops_auto_discovery        = "Enabled"
# Optional one-time OAuth codes (sensitive). Leave unset for portal authorization.
# defender_devops_github_oauth_code = null
# defender_devops_ado_oauth_code    = null

# user_principal_id is optional - defaults to current Azure CLI user (az login)
