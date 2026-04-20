variable "subscription_id" {
  type = string
}

variable "client_id" {
  type = string
}

variable "client_secret" {
  type      = string
  sensitive = true
}

variable "tenant_id" {
  type = string
}

variable "location" {
  type    = string
  default = "francecentral"
}

variable "prefix" {
  type    = string
  default = "alm-iac"
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "ssh_public_key" {
  type = string
}

variable "admin_ips" {
  type        = list(string)
  description = "IPs publiques autorisées à accéder au cluster (SSH + API k8s)"
}

variable "master_vm_size" {
  type    = string
  default = "Standard_D2as_v6"
}

variable "worker_vm_size" {
  type    = string
  default = "Standard_A1_v2"
}

variable "worker_count" {
  type    = number
  default = 2
}

variable "os_disk_size_gb" {
  type    = number
  default = 50
}
