provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-orbit-aks2-demo"
  location = "North Europe"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-spoke1"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "backend" {
  name                 = "backend-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "db" {
  name                 = "db-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "postgresqlDelegation"

    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action"
      ]
    }
  }
}

resource "azurerm_subnet" "gateway" {
  name                 = "gateway-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.3.0/24"]
}

resource "azurerm_network_security_group" "nsg_backend" {
  name                = "nsg-backend"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_security_group" "nsg_db" {
  name                = "nsg-db"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet_network_security_group_association" "backend" {
  subnet_id                 = azurerm_subnet.backend.id
  network_security_group_id = azurerm_network_security_group.nsg_backend.id
}

resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = azurerm_subnet.db.id
  network_security_group_id = azurerm_network_security_group.nsg_db.id
}

# NSG Rule to allow inbound traffic from Application Gateway to AKS nodes
resource "azurerm_network_security_rule" "allow_appgw_to_aks" {
  name                         = "allow-appgw-to-aks"
  priority                     = 100
  direction                    = "Inbound"
  access                       = "Allow"
  protocol                     = "*"
  source_address_prefix        = azurerm_subnet.gateway.address_prefixes[0]
  source_port_range            = "*"
  destination_port_ranges      = ["80", "443"]  # HTTP and HTTPS ports
  destination_address_prefix   = "*"
  network_security_group_name  = azurerm_network_security_group.nsg_backend.name
  resource_group_name          = azurerm_resource_group.rg.name
}

# NSG Rule to allow outbound traffic from AKS nodes to Application Gateway
resource "azurerm_network_security_rule" "allow_aks_to_appgw" {
  name                         = "allow-aks-to-appgw"
  priority                     = 200
  direction                    = "Outbound"
  access                       = "Allow"
  protocol                     = "*"
  destination_address_prefix   = azurerm_subnet.gateway.address_prefixes[0]  # Use the private IP of the App Gateway
  destination_port_ranges      = ["80", "443"]  # HTTP and HTTPS ports
  source_port_range            = "*"
  source_address_prefix        = "*"
  network_security_group_name  = azurerm_network_security_group.nsg_backend.name
  resource_group_name          = azurerm_resource_group.rg.name
}

resource "azurerm_network_security_rule" "allow_aks_to_db" {
  name                        = "allow_aks_to_db"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  source_address_prefix       = azurerm_subnet.backend.address_prefixes[0]
  destination_port_range      = "5432"
  destination_address_prefix  = "*"
  network_security_group_name = azurerm_network_security_group.nsg_db.name
  resource_group_name         = azurerm_resource_group.rg.name
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "orbit-aks-cluster"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "orbit-aks"

  default_node_pool {
    name            = "default"
    node_count      = 2
    vm_size         = "Standard_B2s"
    vnet_subnet_id  = azurerm_subnet.backend.id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    service_cidr      = "10.0.4.0/24"
    dns_service_ip    = "10.0.4.10"
  }
}

resource "azurerm_application_gateway" "appgateway" {
  name                = "appgateway"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = "gatewayIpConfig"
    subnet_id = azurerm_subnet.gateway.id
  }

  frontend_port {
    name = "frontendPort"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "frontendIpConfig"
    public_ip_address_id = azurerm_public_ip.appgw_pip.id
    private_ip_address = "10.0.3.10"
  }

  backend_address_pool {
    name = "defaultPool"
  }

  http_listener {
    name                           = "httpListener"
    frontend_ip_configuration_name = "frontendIpConfig"
    frontend_port_name             = "frontendPort"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "httpRule"
    rule_type                  = "Basic"
    priority                   =  9
    http_listener_name         = "httpListener"
    backend_address_pool_name  = "defaultPool"
    backend_http_settings_name = "defaultHttpSetting"
  }

  backend_http_settings {
    name                  = "defaultHttpSetting"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
  }
}

resource "azurerm_public_ip" "appgw_pip" {
  name                = "appgw-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_postgresql_flexible_server" "postgresql" {
  name                   = "orbit-demo-pgserver"
  location               = azurerm_resource_group.rg.location
  resource_group_name    = azurerm_resource_group.rg.name
  administrator_login    = "pgadmin"
  administrator_password = "P@ssword1234!"
  sku_name               = "GP_Standard_D4s_v3"
  version                = "13"
  storage_mb   = 32768
  storage_tier = "P30"
  delegated_subnet_id           = azurerm_subnet.db.id
  private_dns_zone_id           = azurerm_private_dns_zone.postgresql.id
  public_network_access_enabled = false
  zone = "1"
}

resource "azurerm_private_dns_zone" "postgresql" {
  name                = "orbit.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "vnetlink" {
  name                  = "${azurerm_virtual_network.vnet.name}-link"
  resource_group_name   = azurerm_resource_group.rg.name
  private_dns_zone_name = azurerm_private_dns_zone.postgresql.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_internal" {
  name             = "allow_internal"
  server_id        = azurerm_postgresql_flexible_server.postgresql.id
  start_ip_address = "10.0.1.1"
  end_ip_address   = "10.0.1.254"
}
