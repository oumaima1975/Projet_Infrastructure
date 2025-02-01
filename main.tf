#############################################################################
# 1) Configuration Terraform et Providers
#############################################################################
terraform {
  required_version = ">= 1.0.0"

  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
      # version = "0.7.6" # Adapter si besoin
    }
    template = {
      source  = "hashicorp/template"
      version = "~> 2.2"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.2"
    }
  }
}

# Provider pour l'hôte A (provider par défaut)
provider "libvirt" {
  uri = "qemu:///system"
}

# Provider pour l'hôte B (avec alias)
provider "libvirt" {
  alias = "host_b"
  uri   = "qemu+ssh://oumaima@192.168.54.214/system?keyfile=~/.ssh/id_rsa"
}

#############################################################################
# 2) Variables : CPU = 1, RAM = 1024
#############################################################################
variable "domain" {
  type    = string
  default = "example.com"
}

variable "memoryMB" {
  type    = number
  default = 2024
}

variable "cpu" {
  type    = number
  default = 1
}

#############################################################################
# 3) Définition des machines pour chaque hôte
#############################################################################
locals {
  # Sur l'hôte A
  machines_hostA = {
    master     = "192.168.124.10"
    worker1    = "192.168.124.11"
  }

  # Sur l'hôte B
  machines_hostB = {
    worker2 = "192.168.125.12"
  }

  # Gateways
  gateway_hostA = "192.168.124.1"
  gateway_hostB = "192.168.125.1"
}

#############################################################################
# 4) Volumes de base (un sur chaque hôte)
#############################################################################
resource "libvirt_volume" "base_image_hostA" {
  name   = "ubuntu-jammy-base"
  pool   = "default"
  source = "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
  format = "qcow2"
}

resource "libvirt_volume" "base_image_hostB" {
  provider = libvirt.host_b

  name   = "ubuntu-jammy-base"
  pool   = "default"
  source = "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img"
  format = "qcow2"
}

#############################################################################
# 5) Clonage des volumes OS pour chaque VM
#############################################################################
resource "libvirt_volume" "os_image_hostA" {
  for_each = local.machines_hostA

  # Hôte A => provider par défaut
  name           = "${each.key}-os_image.qcow2"
  pool           = "default"
  size           = 5 * 1024 * 1024 * 1024 # 5G
  base_volume_id = libvirt_volume.base_image_hostA.id
}

resource "libvirt_volume" "os_image_hostB" {
  provider = libvirt.host_b
  for_each = local.machines_hostB

  name           = "${each.key}-os_image.qcow2"
  pool           = "default"
  size           = 5 * 1024 * 1024 * 1024 # 5G
  base_volume_id = libvirt_volume.base_image_hostB.id
}

#############################################################################
# 6) Génération des fichiers Cloud-Init (user_data et network_config)
#############################################################################
# => cloud_init.cfg (user-data) et network_config_static.cfg sont chargés
#    depuis des fichiers séparés.

#################
# Pour l'hôte A #
#################
data "template_file" "user_data_hostA" {
  for_each = local.machines_hostA

  template = file("${path.module}/cloud_init.cfg")
  vars = {
    hostname   = each.key
    fqdn       = "${each.key}.${var.domain}"
    public_key = file("~/.ssh/id_rsa.pub")
  }
}

data "template_file" "network_config_hostA" {
  for_each = local.machines_hostA

  # On utilise la variable gateway_hostA pour la passerelle
  template = file("${path.module}/network_config_static.cfg")
  vars = {
    ip      = each.value
    gateway = local.gateway_hostA
  }
}

data "template_cloudinit_config" "cloudinit_rendered_hostA" {
  for_each = local.machines_hostA

  gzip          = false
  base64_encode = false

  part {
    filename     = "init.cfg"
    content_type = "text/cloud-config"
    content      = data.template_file.user_data_hostA[each.key].rendered
  }
}

resource "libvirt_cloudinit_disk" "commoninit_hostA" {
  for_each = local.machines_hostA

  name = "${each.key}-commoninit.iso"
  pool = "default"

  user_data      = data.template_cloudinit_config.cloudinit_rendered_hostA[each.key].rendered
  network_config = data.template_file.network_config_hostA[each.key].rendered
}

#################
# Pour l'hôte B #
#################
data "template_file" "user_data_hostB" {
  for_each = local.machines_hostB

  # IMPORTANT : on ne met plus provider = libvirt.host_b
  template = file("${path.module}/cloud_init.cfg")
  vars = {
    hostname   = each.key
    fqdn       = "${each.key}.${var.domain}"
    public_key = file("~/.ssh/id_rsa.pub")
  }
}

data "template_file" "network_config_hostB" {
  for_each = local.machines_hostB

  # IMPORTANT : on ne met plus provider = libvirt.host_b
  template = file("${path.module}/network_config_static.cfg")
  vars = {
    ip      = each.value
    gateway = local.gateway_hostB
  }
}

data "template_cloudinit_config" "cloudinit_rendered_hostB" {
  for_each = local.machines_hostB

  # IMPORTANT : on ne met plus provider = libvirt.host_b
  gzip          = false
  base64_encode = false

  part {
    filename     = "init.cfg"
    content_type = "text/cloud-config"
    content      = data.template_file.user_data_hostB[each.key].rendered
  }
}

resource "libvirt_cloudinit_disk" "commoninit_hostB" {
  provider = libvirt.host_b
  for_each = local.machines_hostB

  name = "${each.key}-commoninit.iso"
  pool = "default"

  # On utilise les data sources ci-dessus
  user_data      = data.template_cloudinit_config.cloudinit_rendered_hostB[each.key].rendered
  network_config = data.template_file.network_config_hostB[each.key].rendered
}

#############################################################################
# 7) Création des domaines (VM) sur chaque hôte
#############################################################################
# Hôte A
resource "libvirt_domain" "domain_ubuntu_hostA" {
  for_each = local.machines_hostA

  name   = each.key
  memory = var.memoryMB
  vcpu   = var.cpu

  disk {
    volume_id = libvirt_volume.os_image_hostA[each.key].id
  }

  # Adapter le network_name à votre réseau virtuel
  network_interface {
    network_name = "default3"
  }

  cloudinit = libvirt_cloudinit_disk.commoninit_hostA[each.key].id

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type         = "spice"
    listen_type  = "address"
    autoport     = true
  }
}

# Hôte B
resource "libvirt_domain" "domain_ubuntu_hostB" {
  provider = libvirt.host_b
  for_each = local.machines_hostB

  name   = each.key
  memory = var.memoryMB
  vcpu   = var.cpu

  disk {
    volume_id = libvirt_volume.os_image_hostB[each.key].id
  }

  network_interface {
    network_name = "default2"
  }

  cloudinit = libvirt_cloudinit_disk.commoninit_hostB[each.key].id

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type         = "spice"
    listen_type  = "address"
    autoport     = true
  }
}

#############################################################################
# 8) Outputs (exemple)
#############################################################################
output "ips_hostA" {
  description = "Adresses IP des VMs sur l'hôte A"
  value = {
    for name, domain in libvirt_domain.domain_ubuntu_hostA :
    name => domain.network_interface[0].addresses
  }
}

output "ips_hostB" {
  description = "Adresses IP des VMs sur l'hôte B"
  value = {
    for name, domain in libvirt_domain.domain_ubuntu_hostB :
    name => domain.network_interface[0].addresses
  }
}

