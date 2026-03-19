variable "resource_group_name" {
  type        = string
  description = "Existing resource group name where resources will be deployed"
}

variable "location" {
  type        = string
  description = "Azure region for resources"
  default     = "eastus"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for all resource names (will append random suffix)"
  default     = "zava"
}

variable "user_principal_id" {
  type        = string
  description = "Object ID of the user/principal to grant Cosmos DB data contributor access. Defaults to current Azure CLI user."
  default     = null
}

variable "enable_cosmos_local_auth" {
  type        = bool
  description = "Whether to enable local auth on Cosmos DB account"
  default     = true
}

variable "enable_ai_automation" {
  type        = bool
  description = "Whether to run Azure AI Foundry automation steps (model deployments, connections, .env creation)"
  default     = true
}

variable "enable_data_pipeline" {
  type        = bool
  description = "Whether to run data pipeline automation (requires Python and data files)"
  default     = true
}

variable "enable_multi_agent" {
  type        = bool
  description = "Whether to deploy multi-agent architecture in Microsoft Foundry"
  default     = true
}

variable "enable_a2a_automation" {
  type        = bool
  description = "Whether to deploy the A2A automation framework with process management, testing, monitoring, and deployment automation"
  default     = true
}

variable "a2a_host" {
  type        = string
  description = "Host for the A2A automation system"
  default     = "0.0.0.0"
}

variable "a2a_port" {
  type        = number
  description = "Port for the A2A automation system"
  default     = 8001
}

variable "enable_monitoring_dashboards" {
  type        = bool
  description = "Whether to create monitoring dashboards and alerts for A2A system"
  default     = true
}

variable "enable_continuous_testing" {
  type        = bool
  description = "Whether to enable continuous testing automation for A2A system"
  default     = true
}

variable "automation_storage_path" {
  type        = string
  description = "Path for automation data storage"
  default     = "./automation_data"
}

variable "app_service_sku" {
  type        = string
  description = "App Service Plan SKU (e.g., B1, S1, P0v3). Must support Linux custom containers."
  default     = "S1"
}

variable "deployment_target" {
  type        = string
  description = "Deployment target: 'appservice' or 'containerapps'"
  default     = "containerapps"
}

variable "chat_model_deployment" {
  type        = string
  description = "Chat model deployment name for agents and chat (e.g., model-router or gpt-4o-mini)"
  default     = "gpt-4o-mini"
}

variable "enable_defender_for_cloud" {
  type        = bool
  description = "Whether to enable Microsoft Defender for Cloud plans at the subscription scope (may incur costs)."
  default     = true
}

variable "defender_for_cloud_tier" {
  type        = string
  description = "Defender for Cloud pricing tier. Use 'Standard' to enable paid plans; 'Free' to disable paid benefits while keeping the pricing resource declared."
  default     = "Standard"

  validation {
    condition     = contains(["Free", "Standard"], var.defender_for_cloud_tier)
    error_message = "defender_for_cloud_tier must be either 'Free' or 'Standard'."
  }
}

variable "defender_for_cloud_plans" {
  type = set(string)

  description = <<-EOT
  Defender for Cloud plans to enable via subscription pricing.
  NOTE: Plan names are provider/API dependent. If 'terraform apply' fails on a plan name, remove it from this set.
  EOT

  # Keep the default set conservative and aligned with resources in this repo.
  # - ContainerRegistry: ACR image scanning
  # - Containers: container workload protection
  # - AppServices: App Service protection
  # - StorageAccounts: storage threat protection
  # - KeyVaults: Key Vault threat protection
  default = [
    "ContainerRegistry",
    "Containers",
    "AppServices",
    "StorageAccounts",
    "KeyVaults",
  ]
}

variable "enable_defender_devops_security" {
  type        = bool
  description = "Whether to provision Defender for Cloud DevOps security connector scaffolding (GitHub/Azure DevOps). Authorization still requires an interactive consent step."
  default     = true
}

variable "enable_defender_devops_security_github" {
  type        = bool
  description = "Whether to provision the GitHub DevOps security connector (requires enable_defender_devops_security=true)."
  default     = true
}

variable "enable_defender_devops_security_ado" {
  type        = bool
  description = "Whether to provision the Azure DevOps DevOps security connector (requires enable_defender_devops_security=true)."
  default     = true
}

variable "defender_devops_auto_discovery" {
  type        = string
  description = "Auto-discovery mode for Defender DevOps security connectors. Use 'Enabled' for full discovery, or 'Disabled' with an explicit inventory list."
  default     = "Enabled"

  validation {
    condition     = contains(["Enabled", "Disabled", "NotApplicable"], var.defender_devops_auto_discovery)
    error_message = "defender_devops_auto_discovery must be one of: Enabled, Disabled, NotApplicable."
  }
}

variable "defender_devops_github_connector_name" {
  type        = string
  description = "Name for the GitHub DevOps security connector resource (max 20 chars recommended for portal parity)."
  default     = "github-connector"
}

variable "defender_devops_ado_connector_name" {
  type        = string
  description = "Name for the Azure DevOps DevOps security connector resource (max 20 chars recommended for portal parity)."
  default     = "ado-connector"
}

variable "defender_devops_github_inventory_list" {
  type        = set(string)
  description = "Optional top-level inventory list for GitHub when auto-discovery is Disabled. Values depend on connector API version and inventoryKind."
  default     = []
}

variable "defender_devops_ado_inventory_list" {
  type        = set(string)
  description = "Optional top-level inventory list for Azure DevOps when auto-discovery is Disabled."
  default     = []
}

variable "defender_devops_github_oauth_code" {
  type        = string
  description = "Optional one-time OAuth authorization code for GitHub connector devops config. Only used during create/update and not returned by GET. Leave null to authorize via Azure portal UI."
  default     = null
  sensitive   = true
}

variable "defender_devops_ado_oauth_code" {
  type        = string
  description = "Optional one-time OAuth authorization code for Azure DevOps connector devops config. Only used during create/update and not returned by GET. Leave null to authorize via Azure portal UI."
  default     = null
  sensitive   = true
}

