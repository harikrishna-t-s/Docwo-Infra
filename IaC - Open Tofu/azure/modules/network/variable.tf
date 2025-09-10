variable "rg_name" {
  description = "Resource group name where VNet will be created"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "env" {
  description = "Environment name (dev, test, prod)"
  type        = string
}

variable "vnet_cidr" {
  description = "CIDR block for the VNet"
  type        = string
}

variable "subnets" {
  description = "Map of subnets with name, CIDR, and type (public/private)"
  type = map(object({
    address_prefix = string
    type           = string 
  }))
}
