# Guide de déploiement — Cluster Kubernetes sur Azure

Déploiement d'un cluster Kubernetes (1 master + 2 workers) sur Microsoft Azure avec Terraform et Ansible.

---

## Architecture

```
Azure — West Europe
└── Resource Group : alm-iac-rg
    ├── VNet : 10.0.0.0/16
    │   └── Subnet : 10.0.1.0/24
    ├── NSG (SSH + API K8s restreints à vos IPs)
    ├── VM master  — Standard_D2as_v6 — 10.0.1.10
    ├── VM worker1 — Standard_F1as_v7 — 10.0.1.11
    └── VM worker2 — Standard_F1as_v7 — 10.0.1.12
```

---

## Prérequis

- Un abonnement Microsoft Azure actif
- WSL2 avec AlmaLinux 9 installé sur Windows
- Accès au portail Azure et à Azure Cloud Shell

---

## ÉTAPE 1 — Préparer Azure (depuis Cloud Shell)

Ouvrez **Azure Cloud Shell** (icône `>_` en haut du portail Azure).

### 1.1 Créer le Service Principal Terraform

```bash
az ad sp create-for-rbac \
  --name "sp-terraform-alm-iac" \
  --role Contributor \
  --scopes /subscriptions/<VOTRE_SUBSCRIPTION_ID>
```

Notez les valeurs retournées :
```json
{
  "appId":       "<CLIENT_ID>",
  "password":    "<CLIENT_SECRET>",
  "tenant":      "<TENANT_ID>"
}
```

### 1.2 Récupérer votre IP publique

```bash
curl -s https://api.ipify.org
```

### 1.3 Générer la clé SSH

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
cat ~/.ssh/id_rsa.pub
```

Notez la clé publique affichée (ligne commençant par `ssh-rsa ...`).

---

## ÉTAPE 2 — Installer les outils sur WSL (AlmaLinux 9)

Ouvrez votre terminal WSL AlmaLinux.

### 2.1 Azure CLI

```bash
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
```

Créez le fichier `/etc/yum.repos.d/azure-cli.repo` avec ce contenu exact :
```
[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
```

```bash
sudo dnf install -y --disablerepo=epel azure-cli
az login
```

### 2.2 Terraform

Créez le fichier `/etc/yum.repos.d/hashicorp.repo` avec ce contenu exact :
```
[hashicorp]
name=Hashicorp Stable
baseurl=https://rpm.releases.hashicorp.com/RHEL/9/x86_64/stable
enabled=1
gpgcheck=1
gpgkey=https://rpm.releases.hashicorp.com/gpg
```

```bash
sudo dnf install -y terraform
terraform --version
```

### 2.3 Ansible

```bash
sudo dnf install -y ansible
ansible --version
```

---

## ÉTAPE 3 — Terraform : Provisionner l'infrastructure

### 3.1 Structure des fichiers

```
azure-project/
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars
└── ansible/
    ├── site.yml
    ├── inventory/hosts.yml
    ├── group_vars/all.yml
    └── roles/
        ├── common/tasks/main.yml
        ├── k8s_common/tasks/main.yml
        ├── k8s_master/tasks/main.yml
        └── k8s_worker/tasks/main.yml
```

### 3.2 Contenu des fichiers Terraform

**`terraform/main.tf`**
```hcl
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

resource "azurerm_resource_group" "main" {
  name     = "${var.prefix}-rg"
  location = var.location
}

resource "azurerm_virtual_network" "main" {
  name                = "${var.prefix}-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

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

  tags = { role = "master" }
}

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

  tags = { role = "worker" }
}
```

**`terraform/variables.tf`**
```hcl
variable "subscription_id" { type = string }
variable "client_id"       { type = string }
variable "client_secret"   { type = string; sensitive = true }
variable "tenant_id"       { type = string }

variable "location"        { type = string; default = "westeurope" }
variable "prefix"          { type = string; default = "alm-iac" }
variable "admin_username"  { type = string; default = "azureuser" }
variable "ssh_public_key"  { type = string }

variable "admin_ips" {
  type        = list(string)
  description = "IPs autorisées (SSH + API K8s)"
}

variable "master_vm_size"  { type = string; default = "Standard_D2as_v6" }
variable "worker_vm_size"  { type = string; default = "Standard_F1as_v7" }
variable "worker_count"    { type = number; default = 2 }
variable "os_disk_size_gb" { type = number; default = 50 }
```

**`terraform/outputs.tf`**
```hcl
output "master_public_ip"  { value = azurerm_public_ip.master.ip_address }
output "master_private_ip" { value = azurerm_network_interface.master.private_ip_address }
output "worker_public_ips" { value = azurerm_public_ip.worker[*].ip_address }
output "worker_private_ips" { value = azurerm_network_interface.worker[*].private_ip_address }
output "ssh_master" {
  value = "ssh -i ~/.ssh/id_rsa azureuser@${azurerm_public_ip.master.ip_address}"
}
```

**`terraform/terraform.tfvars`** — Remplissez avec vos valeurs :
```hcl
subscription_id = "<VOTRE_SUBSCRIPTION_ID>"
client_id       = "<VOTRE_CLIENT_ID>"
client_secret   = "<VOTRE_CLIENT_SECRET>"
tenant_id       = "<VOTRE_TENANT_ID>"

admin_ips       = ["<VOTRE_IP_1>", "<VOTRE_IP_2>"]
ssh_public_key  = "<VOTRE_CLE_SSH_PUBLIQUE>"

location        = "westeurope"
master_vm_size  = "Standard_D2as_v6"
worker_vm_size  = "Standard_F1as_v7"
worker_count    = 2
os_disk_size_gb = 50
```

### 3.3 Déployer l'infrastructure

```bash
cd azure-project/terraform
terraform init
terraform plan
terraform apply
```

Tapez `yes` pour confirmer. Le déploiement prend environ **5 minutes**.

À la fin, notez les IPs affichées :
```
master_public_ip  = "X.X.X.X"
worker_public_ips = ["X.X.X.X", "X.X.X.X"]
ssh_master        = "ssh -i ~/.ssh/id_rsa azureuser@X.X.X.X"
```

---

## ÉTAPE 4 — Ansible : Installer Kubernetes

### 4.1 Copier la clé SSH privée depuis Cloud Shell

Dans **Cloud Shell** :
```bash
cat ~/.ssh/id_rsa
```

Dans votre **terminal WSL**, créez le fichier avec le contenu copié :
```bash
mkdir -p ~/.ssh
nano ~/.ssh/id_rsa   # collez le contenu, Ctrl+X, Y pour sauvegarder
chmod 600 ~/.ssh/id_rsa
```

### 4.2 Mettre à jour l'inventaire Ansible

Éditez `ansible/inventory/hosts.yml` avec les IPs de vos VMs :

```yaml
all:
  children:
    k8s_master:
      hosts:
        master:
          ansible_host: <IP_MASTER>
    k8s_workers:
      hosts:
        worker1:
          ansible_host: <IP_WORKER1>
        worker2:
          ansible_host: <IP_WORKER2>
  vars:
    ansible_user: azureuser
    ansible_ssh_private_key_file: ~/.ssh/id_rsa
    ansible_ssh_common_args: '-o StrictHostKeyChecking=no'
```

### 4.3 Contenu des fichiers Ansible

**`ansible/group_vars/all.yml`**
```yaml
kubernetes_version: "1.29"
pod_network_cidr: "10.244.0.0/16"
master_private_ip: "10.0.1.10"
```

**`ansible/site.yml`**
```yaml
---
- name: Préparation commune de tous les noeuds
  hosts: all
  become: true
  roles:
    - common
    - k8s_common

- name: Initialisation du master Kubernetes
  hosts: k8s_master
  become: true
  roles:
    - k8s_master

- name: Jonction des workers au cluster
  hosts: k8s_workers
  become: true
  roles:
    - k8s_worker
```

**`ansible/roles/common/tasks/main.yml`**
```yaml
---
- name: Mise à jour du système
  dnf:
    name: "*"
    state: latest
    update_cache: true

- name: Installation des paquets de base
  dnf:
    name: [curl, wget, vim, git, net-tools, bash-completion, iproute-tc]
    state: present

- name: Désactivation de firewalld
  systemd:
    name: firewalld
    state: stopped
    enabled: false
  ignore_errors: true

- name: Désactivation du swap (runtime)
  command: swapoff -a
  changed_when: false

- name: Désactivation du swap (permanent)
  replace:
    path: /etc/fstab
    regexp: '^([^#].*\sswap\s.*)$'
    replace: '# \1'

- name: Chargement des modules kernel
  modprobe:
    name: "{{ item }}"
    state: present
  loop: [overlay, br_netfilter]

- name: Persistance des modules kernel
  copy:
    dest: /etc/modules-load.d/k8s.conf
    content: "overlay\nbr_netfilter\n"

- name: Configuration sysctl pour Kubernetes
  sysctl:
    name: "{{ item.key }}"
    value: "{{ item.value }}"
    state: present
    reload: true
    sysctl_file: /etc/sysctl.d/k8s.conf
  loop:
    - { key: "net.bridge.bridge-nf-call-iptables",  value: "1" }
    - { key: "net.bridge.bridge-nf-call-ip6tables", value: "1" }
    - { key: "net.ipv4.ip_forward",                 value: "1" }

- name: Désactivation de SELinux (permissive)
  selinux:
    policy: targeted
    state: permissive
```

**`ansible/roles/k8s_common/tasks/main.yml`**
```yaml
---
- name: Ajout du repo Docker (pour containerd)
  get_url:
    url: https://download.docker.com/linux/centos/docker-ce.repo
    dest: /etc/yum.repos.d/docker-ce.repo

- name: Installation de containerd
  dnf:
    name: containerd.io
    state: present

- name: Création du répertoire de config containerd
  file:
    path: /etc/containerd
    state: directory

- name: Génération de la config containerd
  shell: containerd config default > /etc/containerd/config.toml

- name: Suppression de disabled_plugins
  lineinfile:
    path: /etc/containerd/config.toml
    regexp: '^\s*disabled_plugins\s*='
    state: absent

- name: Activation de SystemdCgroup
  replace:
    path: /etc/containerd/config.toml
    regexp: 'SystemdCgroup = false'
    replace: 'SystemdCgroup = true'

- name: Démarrage de containerd
  systemd:
    name: containerd
    state: restarted
    enabled: true
    daemon_reload: true

- name: Ajout du repo Kubernetes
  copy:
    dest: /etc/yum.repos.d/kubernetes.repo
    content: |
      [kubernetes]
      name=Kubernetes
      baseurl=https://pkgs.k8s.io/core:/stable:/v{{ kubernetes_version }}/rpm/
      enabled=1
      gpgcheck=1
      gpgkey=https://pkgs.k8s.io/core:/stable:/v{{ kubernetes_version }}/rpm/repodata/repomd.xml.key

- name: Installation de kubeadm, kubelet, kubectl
  dnf:
    name: [kubelet, kubeadm, kubectl]
    state: present
    disable_excludes: kubernetes

- name: Activation de kubelet
  systemd:
    name: kubelet
    enabled: true
    state: started
```

**`ansible/roles/k8s_master/tasks/main.yml`**
```yaml
---
- name: Vérification si le cluster est déjà initialisé
  stat:
    path: /etc/kubernetes/admin.conf
  register: kubeadm_init_done

- name: Initialisation du cluster
  command: >
    kubeadm init
    --pod-network-cidr={{ pod_network_cidr }}
    --apiserver-advertise-address={{ master_private_ip }}
  when: not kubeadm_init_done.stat.exists

- name: Création du répertoire .kube
  file:
    path: /home/azureuser/.kube
    state: directory
    owner: azureuser
    group: azureuser
    mode: '0755'

- name: Copie du kubeconfig
  copy:
    src: /etc/kubernetes/admin.conf
    dest: /home/azureuser/.kube/config
    remote_src: true
    owner: azureuser
    group: azureuser
    mode: '0600'

- name: Installation du CNI Flannel
  become_user: azureuser
  command: kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
  environment:
    KUBECONFIG: /home/azureuser/.kube/config

- name: Génération de la commande join
  command: kubeadm token create --print-join-command
  register: join_command_raw

- name: Sauvegarde de la commande join
  set_fact:
    k8s_join_command: "{{ join_command_raw.stdout }}"
```

**`ansible/roles/k8s_worker/tasks/main.yml`**
```yaml
---
- name: Vérification si le worker est déjà dans le cluster
  stat:
    path: /etc/kubernetes/kubelet.conf
  register: kubelet_conf

- name: Récupération de la commande join depuis le master
  set_fact:
    k8s_join_command: "{{ hostvars[groups['k8s_master'][0]]['k8s_join_command'] }}"

- name: Jonction du worker au cluster
  command: "{{ k8s_join_command }}"
  when: not kubelet_conf.stat.exists
```

### 4.4 Tester la connectivité

```bash
cd azure-project/ansible
ansible -i inventory/hosts.yml all -m ping
```

Les 3 nœuds doivent répondre `pong`.

### 4.5 Lancer le déploiement Kubernetes

```bash
ansible-playbook -i inventory/hosts.yml site.yml
```

Le déploiement prend environ **10-15 minutes**.

---

## ÉTAPE 5 — Vérification

### 5.1 Se connecter au master

```bash
ssh -i ~/.ssh/id_rsa azureuser@<IP_MASTER>
```

### 5.2 Vérifier l'état du cluster

```bash
kubectl get nodes -o wide
```

Résultat attendu :
```
NAME             STATUS   ROLES           AGE   VERSION
alm-iac-master   Ready    control-plane   5m    v1.29.x
alm-iac-worker-1 Ready    <none>          3m    v1.29.x
alm-iac-worker-2 Ready    <none>          3m    v1.29.x
```

### 5.3 Déployer une application de test

```bash
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl get svc nginx
```

---

## Supprimer l'infrastructure

Pour éviter des frais, supprimez toutes les ressources :

```bash
cd azure-project/terraform
terraform destroy
```

Tapez `yes` pour confirmer.

---

## Récapitulatif des coûts estimés

| Ressource | Taille | Coût/mois |
|-----------|--------|-----------|
| VM Master | Standard_D2as_v6 | ~80 $/mois |
| VM Worker × 2 | Standard_F1as_v7 | ~60 $/mois × 2 |
| IPs publiques × 3 | Standard | ~12 $/mois |
| **Total estimé** | | **~212 $/mois** |

> Pensez à faire `terraform destroy` après vos tests.
