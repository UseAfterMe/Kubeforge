provider "proxmox" {
  endpoint = var.proxmox_api_url
  username = var.proxmox_username
  password = var.proxmox_password
  insecure = var.proxmox_insecure
}

moved {
  from = proxmox_download_file.ubuntu_cloud_image
  to   = proxmox_download_file.cloud_image
}

locals {
  control_plane_nodes = {
    for name, node in var.nodes : name => node if node.role == "controlplane"
  }

  worker_nodes = {
    for name, node in var.nodes : name => node if node.role == "worker"
  }

  uses_kube_vip = length(local.control_plane_nodes) > 1

  proxmox_hosts = toset(distinct([for _, node in var.nodes : node.host_node]))
  normalized_dns_domain = (
    var.dns_domain != null && trim(var.dns_domain, " .") != ""
    ? join(".", compact(split(".", lower(trim(var.dns_domain, " .")))))
    : null
  )
  node_dns_names = {
    for name, node in var.nodes :
    name => (
      try(node.dns_name, null) != null && trim(try(node.dns_name, ""), " .") != ""
      ? join(".", compact(split(".", lower(trim(try(node.dns_name, ""), " .")))))
      : null
    )
  }

  first_control_plane_name = sort(keys(local.control_plane_nodes))[0]
  first_control_plane_ip   = local.control_plane_nodes[local.first_control_plane_name].ip
  first_control_plane_dns  = local.node_dns_names[local.first_control_plane_name]
  control_plane_ips        = [for name in sort(keys(local.control_plane_nodes)) : local.control_plane_nodes[name].ip]
  worker_ips               = [for name in sort(keys(local.worker_nodes)) : local.worker_nodes[name].ip]
  all_k8s_ips              = concat(local.control_plane_ips, local.worker_ips)

  kubernetes_api_ip       = local.uses_kube_vip ? var.kube_vip_ip : local.first_control_plane_ip
  kubernetes_api_dns      = local.uses_kube_vip ? null : local.first_control_plane_dns
  kubernetes_api_endpoint = "https://${local.kubernetes_api_ip}:6443"
  kube_version_minor      = regex("^([0-9]+\\.[0-9]+)", var.kubernetes_version)[0]
  kube_package_version    = "${var.kubernetes_version}-1.1"
}

resource "tls_private_key" "cluster_ssh" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "cluster_ssh_private_key" {
  filename        = "${path.module}/out/ssh/id_cluster_ed25519"
  content         = tls_private_key.cluster_ssh.private_key_openssh
  file_permission = "0600"
}

resource "local_file" "cluster_ssh_public_key" {
  filename        = "${path.module}/out/ssh/id_cluster_ed25519.pub"
  content         = tls_private_key.cluster_ssh.public_key_openssh
  file_permission = "0644"
}

resource "proxmox_download_file" "cloud_image" {
  for_each = var.cloud_image_download_enabled ? local.proxmox_hosts : toset([])

  node_name           = each.key
  datastore_id        = var.image_datastore
  content_type        = "iso"
  file_name           = var.cloud_image_file_name
  url                 = var.cloud_image_url
  overwrite           = false
  overwrite_unmanaged = false
  verify              = !var.proxmox_insecure
}

resource "proxmox_virtual_environment_file" "cloud_init_user_data" {
  for_each = var.nodes

  content_type = "snippets"
  datastore_id = var.snippets_datastore
  node_name    = each.value.host_node

  source_raw {
    data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
      hostname                 = each.key
      os_family                = var.os_family
      ssh_username             = var.ssh_username
      ssh_public_key           = trimspace(tls_private_key.cluster_ssh.public_key_openssh)
      operator_ssh_public_key  = var.operator_ssh_public_key != null ? trimspace(var.operator_ssh_public_key) : null
      ssh_password_hash        = var.ssh_password_hash
      package_upgrade          = var.cloud_init_package_upgrade
      install_qemu_guest_agent = var.install_qemu_guest_agent
      fqdn                     = local.node_dns_names[each.key]
    })
    file_name = "k8s-${each.key}-user-data.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  node_name       = each.value.host_node
  vm_id           = each.value.vm_id
  name            = each.key
  description     = title(each.value.role)
  tags            = compact(["k8s", each.value.role])
  on_boot         = true
  started         = true
  machine         = "q35"
  bios            = "seabios"
  boot_order      = ["virtio0"]
  hotplug         = "network,disk,usb,memory,cpu"
  stop_on_destroy = true

  agent {
    enabled = true
    timeout = "1m"
  }

  # The Proxmox provider documents that Debian 12 / Ubuntu cloud images
  # require a serial socket when the imported boot disk is resized.
  serial_device {
    device = "socket"
  }

  cpu {
    type  = "host"
    cores = each.value.cores
    numa  = true
  }

  memory {
    dedicated = each.value.memory_mb
  }

  network_device {
    bridge  = var.bridge
    vlan_id = try(each.value.vlan_id, var.vlan_id)
  }

  disk {
    datastore_id = var.vm_datastore
    interface    = "virtio0"
    file_id      = try(proxmox_download_file.cloud_image[each.value.host_node].id, "${var.image_datastore}:iso/${var.cloud_image_file_name}")
    # Raw is the safest common denominator across Proxmox storage backends.
    file_format = "raw"
    size        = each.value.disk_gb
    iothread    = true
    discard     = "on"
    ssd         = true
    cache       = "writethrough"
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id      = var.cloudinit_datastore
    user_data_file_id = proxmox_virtual_environment_file.cloud_init_user_data[each.key].id

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.prefix}"
        gateway = var.gateway
      }
    }
  }
}

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/out/inventory.yml"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/inventory.yml.tftpl", {
    ssh_username         = var.ssh_username
    ssh_private_key_path = local_sensitive_file.cluster_ssh_private_key.filename
    nodes                = var.nodes
    node_dns_names       = local.node_dns_names
    control_plane_names  = sort(keys(local.control_plane_nodes))
    worker_names         = sort(keys(local.worker_nodes))
    first_control_plane  = local.first_control_plane_name
  })
}

resource "local_sensitive_file" "ansible_vars" {
  filename        = "${path.module}/out/ansible-vars.yml"
  file_permission = "0600"
  content = templatefile("${path.module}/templates/ansible-vars.yml.tftpl", {
    cluster_name                   = var.cluster_name
    os_family                      = var.os_family
    os_version                     = var.os_version
    kubernetes_version             = var.kubernetes_version
    kube_version_minor             = local.kube_version_minor
    kube_package_version           = local.kube_package_version
    kubernetes_api_ip              = local.kubernetes_api_ip
    kubernetes_api_dns             = local.kubernetes_api_dns
    first_control_plane_name       = local.first_control_plane_name
    first_control_plane_ip         = local.first_control_plane_ip
    first_control_plane_dns        = local.first_control_plane_dns
    pod_cidr                       = var.pod_cidr
    service_cidr                   = var.service_cidr
    control_plane_count            = length(local.control_plane_nodes)
    kube_vip_ip                    = var.kube_vip_ip
    kube_vip_version               = var.kube_vip_version
    cilium_chart_version           = var.cilium_chart_version
    traefik_chart_version          = var.traefik_chart_version
    install_qemu_guest_agent       = var.install_qemu_guest_agent
    enable_rocky_cockpit           = var.enable_rocky_cockpit
    install_proxmox_csi            = var.install_proxmox_csi
    proxmox_csi_chart_version      = var.proxmox_csi_chart_version
    proxmox_csi_storage            = var.proxmox_csi_storage
    proxmox_region                 = var.proxmox_region
    proxmox_api_url                = var.proxmox_api_url
    proxmox_username               = var.proxmox_username
    proxmox_insecure               = var.proxmox_insecure
    dns_domain                     = local.normalized_dns_domain
    dns_servers                    = var.dns_servers
    load_balancer_ip_pools         = var.load_balancer_ip_pools
    cilium_load_balancer_pool_name = var.cilium_load_balancer_pool_name
    cilium_l2_policy_name          = var.cilium_l2_policy_name
  })
}
