variable "proxmox_api_url" {
  description = "Proxmox API URL, e.g. https://pve.example.com:8006/api2/json"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox username, e.g. root@pam"
  type        = string
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
  sensitive   = true
  nullable    = true
  default     = null
}

variable "proxmox_insecure" {
  description = "Skip TLS verification for Proxmox API"
  type        = bool
  default     = true
}

variable "cluster_name" {
  description = "Cluster name"
  type        = string
}

variable "proxmox_region" {
  description = "Logical Proxmox region/cluster name used for CSI topology labels"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version without leading v, e.g. 1.34.1"
  type        = string
}

variable "gateway" {
  description = "Default IPv4 gateway"
  type        = string
}

variable "prefix" {
  description = "IPv4 CIDR prefix length"
  type        = number
  default     = 24
}

variable "dns_servers" {
  description = "DNS servers"
  type        = list(string)
}

variable "dns_domain" {
  description = "Optional DNS domain used to derive node FQDNs like cp01.example.internal"
  type        = string
  default     = null
  nullable    = true
}

variable "bridge" {
  description = "Proxmox bridge"
  type        = string
}

variable "vlan_id" {
  description = "Optional VLAN tag"
  type        = number
  default     = null
  nullable    = true
}

variable "vm_datastore" {
  description = "Datastore for VM disks"
  type        = string
}

variable "image_datastore" {
  description = "Datastore for downloaded cloud image"
  type        = string
}

variable "cloudinit_datastore" {
  description = "Datastore for cloud-init"
  type        = string
}

variable "snippets_datastore" {
  description = "Datastore that supports snippets"
  type        = string
}

variable "ssh_username" {
  description = "Bootstrap SSH username created via cloud-init"
  type        = string
  default     = "ubuntu"
}

variable "os_family" {
  description = "Guest operating system family, e.g. ubuntu or rocky"
  type        = string
  default     = "ubuntu"

  validation {
    condition     = contains(["ubuntu", "rocky"], lower(var.os_family))
    error_message = "os_family must be either ubuntu or rocky."
  }
}

variable "os_version" {
  description = "Guest operating system version label chosen during configuration"
  type        = string
  default     = "24.04"
}

variable "operator_ssh_public_key" {
  description = "Optional local operator SSH public key to install on every created VM for direct access"
  type        = string
  default     = null
  nullable    = true
}

variable "install_qemu_guest_agent" {
  description = "Install and enable qemu-guest-agent inside every created VM."
  type        = bool
  default     = true
}

variable "enable_rocky_cockpit" {
  description = "Install and enable Cockpit on Rocky Linux guests."
  type        = bool
  default     = false
}

variable "ssh_password_hash" {
  description = "Optional SHA-512 password hash for the bootstrap SSH user to allow console and SSH password login"
  type        = string
  default     = null
  nullable    = true
  sensitive   = true
}

variable "cloud_init_package_upgrade" {
  description = "Whether cloud-init should run package upgrades during first boot"
  type        = bool
  default     = true
}

variable "cloud_image_url" {
  description = "Cloud image URL for the selected operating system"
  type        = string
  default     = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "cloud_image_file_name" {
  description = "Local file name for the downloaded cloud image"
  type        = string
  default     = "noble-server-cloudimg-amd64.img"
}

variable "cloud_image_download_enabled" {
  description = "Whether OpenTofu should manage the Proxmox cloud image download. Kubeforge disables this at apply time when the image is already cached on Proxmox."
  type        = bool
  default     = true
}

variable "pod_cidr" {
  description = "Pod CIDR"
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  description = "Service CIDR"
  type        = string
  default     = "10.96.0.0/12"
}

variable "load_balancer_ip_pools" {
  description = "IP pools used by Cilium LB IPAM for LoadBalancer services"
  type        = list(string)
}

variable "cilium_load_balancer_pool_name" {
  description = "Name of the Cilium LoadBalancer IP pool"
  type        = string
  default     = "default"
}

variable "cilium_l2_policy_name" {
  description = "Name of the Cilium L2 announcement policy"
  type        = string
  default     = "default"
}

variable "cilium_chart_version" {
  description = "Cilium Helm chart version"
  type        = string
  default     = "1.19.2"
}

variable "traefik_chart_version" {
  description = "Traefik Helm chart version"
  type        = string
  default     = "39.0.7"
}

variable "kube_vip_ip" {
  description = "Virtual IP used by kube-vip for the Kubernetes API when more than one control plane is deployed"
  type        = string
  default     = null
  nullable    = true
}

variable "kube_vip_version" {
  description = "kube-vip container image tag"
  type        = string
  default     = "v1.0.1"
}

variable "install_proxmox_csi" {
  description = "Install the Proxmox CSI plugin"
  type        = bool
  default     = true
}

variable "proxmox_csi_chart_version" {
  description = "Proxmox CSI chart version"
  type        = string
  default     = "0.5.4"
}

variable "proxmox_csi_storage" {
  description = "Proxmox storage ID used by the CSI StorageClass"
  type        = string
}

variable "nodes" {
  description = "All Kubernetes VM nodes keyed by hostname"
  type = map(object({
    host_node   = string
    role        = string
    vm_id       = number
    ip          = string
    mac_address = optional(string)
    vlan_id     = optional(number)
    cores       = number
    memory_mb   = number
    disk_gb     = number
    dns_name    = optional(string)
  }))

  validation {
    condition     = alltrue([for _, node in var.nodes : contains(["controlplane", "worker"], node.role)])
    error_message = "Node role must be either controlplane or worker."
  }
}
