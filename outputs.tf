output "inventory_path" {
  value = local_file.ansible_inventory.filename
}

output "ansible_vars_path" {
  value = local_sensitive_file.ansible_vars.filename
}

output "ssh_private_key_path" {
  value     = local_sensitive_file.cluster_ssh_private_key.filename
  sensitive = true
}

output "kubernetes_api_endpoint" {
  value = local.kubernetes_api_endpoint
}

output "kubeconfig_path" {
  value = "${path.module}/out/kubeconfig"
}

output "first_controlplane_ip" {
  value = local.first_control_plane_ip
}

output "controlplane_ips" {
  value = local.control_plane_ips
}

output "worker_ips" {
  value = local.worker_ips
}
