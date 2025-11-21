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
