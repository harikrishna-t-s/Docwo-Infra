# Virtual Network
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${var.env}"
  resource_group_name = var.rg_name
  location            = var.location
  address_space       = [var.vnet_cidr]
}

# Subnets
resource "azurerm_subnet" "subnets" {
  for_each             = var.subnets
  name                 = each.key
  resource_group_name  = var.rg_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [each.value.address_prefix]
}

# NSGs
resource "azurerm_network_security_group" "nsg" {
  for_each            = var.subnets
  name                = "nsg-${var.env}-${each.key}"
  location            = var.location
  resource_group_name = var.rg_name
}

# Example rules based on subnet type
resource "azurerm_network_security_rule" "allow_internet_in" {
  for_each = { for k, v in var.subnets : k => v if v.type == "public" }

  name                        = "Allow-HTTP-HTTPS-In"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_ranges     = ["80", "443"]
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.rg_name
  network_security_group_name = azurerm_network_security_group.nsg[each.key].name
}

resource "azurerm_network_security_rule" "deny_internet_in" {
  for_each = { for k, v in var.subnets : k => v if v.type == "private" }

  name                        = "Deny-Internet-In"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = var.rg_name
  network_security_group_name = azurerm_network_security_group.nsg[each.key].name
}

# Associate NSGs with Subnets
resource "azurerm_subnet_network_security_group_association" "nsg_assoc" {
  for_each                  = var.subnets
  subnet_id                 = azurerm_subnet.subnets[each.key].id
  network_security_group_id = azurerm_network_security_group.nsg[each.key].id
}
