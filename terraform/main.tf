terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
  required_version = ">= 1.6"
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  client_id       = var.client_id
  client_secret   = var.client_secret
  tenant_id       = var.tenant_id
}

# ─── Resource Group ───────────────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
}

# ─── Réseau ───────────────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

# Délai pour laisser Azure propager le VNet avant de créer le Subnet
resource "time_sleep" "wait_for_vnet" {
  depends_on      = [azurerm_virtual_network.main]
  create_duration = "60s"
}

resource "azurerm_subnet" "main" {
  name                 = "${var.prefix}-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
  depends_on           = [time_sleep.wait_for_vnet]
}

# ─── NSG ──────────────────────────────────────────────────────────────────────
# SSH et API Kubernetes ouverts uniquement depuis l'IP admin.
# Tout le trafic interne au subnet est autorisé (communication inter-nœuds k8s).

resource "azurerm_network_security_group" "main" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = [for ip in var.admin_ips : "${ip}/32"]
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-k8s-api"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6443"
    source_address_prefixes    = [for ip in var.admin_ips : "${ip}/32"]
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-internal"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}

# ─── IPs Publiques ────────────────────────────────────────────────────────────

resource "azurerm_public_ip" "master" {
  name                = "${var.prefix}-master-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_public_ip" "worker" {
  count               = var.worker_count
  name                = "${var.prefix}-worker-${count.index + 1}-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# ─── NICs ─────────────────────────────────────────────────────────────────────
# IPs privées statiques : master = 10.0.1.10, workers = 10.0.1.11, 10.0.1.12

resource "azurerm_network_interface" "master" {
  name                = "${var.prefix}-master-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.10"
    public_ip_address_id          = azurerm_public_ip.master.id
  }
}

resource "azurerm_network_interface" "worker" {
  count               = var.worker_count
  name                = "${var.prefix}-worker-${count.index + 1}-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.${count.index + 11}"
    public_ip_address_id          = azurerm_public_ip.worker[count.index].id
  }
}

# ─── VM Master ────────────────────────────────────────────────────────────────

resource "azurerm_linux_virtual_machine" "master" {
  name                  = "${var.prefix}-master"
  location              = azurerm_resource_group.main.location
  resource_group_name   = azurerm_resource_group.main.name
  size                  = var.master_vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.master.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "almalinux"
    offer     = "almalinux-x86_64"
    sku       = "9-gen2"
    version   = "latest"
  }

  tags = {
    role = "master"
  }
}

# ─── VMs Workers ──────────────────────────────────────────────────────────────

resource "azurerm_linux_virtual_machine" "worker" {
  count                 = var.worker_count
  name                  = "${var.prefix}-worker-${count.index + 1}"
  location              = azurerm_resource_group.main.location
  resource_group_name   = azurerm_resource_group.main.name
  size                  = var.worker_vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.worker[count.index].id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "almalinux"
    offer     = "almalinux-x86_64"
    sku       = "9-gen2"
    version   = "latest"
  }

  tags = {
    role = "worker"
  }
}
