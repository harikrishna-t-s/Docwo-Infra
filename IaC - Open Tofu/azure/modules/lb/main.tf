# Public IP for LB frontend
resource "azurerm_public_ip" "lb_public_ip" {
  name                = "lb-public-ip-${var.env}"
  location            = var.location
  resource_group_name = var.rg_name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# Load Balancer
resource "azurerm_lb" "main" {
  name                = "lb-${var.env}"
  location            = var.location
  resource_group_name = var.rg_name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "PublicFrontEnd"
    public_ip_address_id = azurerm_public_ip.lb_public_ip.id
  }
}

# Backend Pool
resource "azurerm_lb_backend_address_pool" "backend_pool" {
  name            = "lb-backend-pool"
  loadbalancer_id = azurerm_lb.main.id
}

# Health Probe (check port 80)
resource "azurerm_lb_probe" "http_probe" {
  name                = "http-probe"
  resource_group_name = var.rg_name
  loadbalancer_id     = azurerm_lb.main.id
  protocol            = "Tcp"
  port                = 80
}

# Load Balancer Rule (HTTP)
resource "azurerm_lb_rule" "http_rule" {
  name                           = "http-rule"
  resource_group_name            = var.rg_name
  loadbalancer_id                = azurerm_lb.main.id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "PublicFrontEnd"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend_pool.id]
  probe_id                       = azurerm_lb_probe.http_probe.id
}
