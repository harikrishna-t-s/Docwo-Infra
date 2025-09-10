variable "rg_name" {
  description = "Resource group name where the Load Balancer will be created"
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

variable "frontend_ports" {
  description = "List of frontend ports to expose on the load balancer"
  type        = list(number)
  default     = [80, 443]
}

variable "backend_port" {
  description = "Port on the backend to which traffic should be routed"
  type        = number
  default     = 80
}

variable "probe_port" {
  description = "Port for the health probe"
  type        = number
  default     = 80
}
