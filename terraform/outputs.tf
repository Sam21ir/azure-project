output "master_public_ip" {
  description = "IP publique du master K8s"
  value       = azurerm_public_ip.master.ip_address
}

output "master_private_ip" {
  description = "IP privée du master K8s"
  value       = azurerm_network_interface.master.private_ip_address
}

output "worker_public_ips" {
  description = "IPs publiques des workers"
  value       = azurerm_public_ip.worker[*].ip_address
}

output "worker_private_ips" {
  description = "IPs privées des workers"
  value       = azurerm_network_interface.worker[*].private_ip_address
}

output "ssh_master" {
  description = "Commande SSH pour se connecter au master"
  value       = "ssh -i ~/.ssh/id_rsa azureuser@${azurerm_public_ip.master.ip_address}"
}
