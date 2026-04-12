#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ipaddress
import json
import re
import sys
from pathlib import Path


HOSTNAME_RE = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")
DNS_RE = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$")


def normalize_dns_domain(value: str | None) -> str | None:
    if value is None:
        return None
    parts = [part for part in value.strip().lower().split(".") if part]
    return ".".join(parts) or None


def normalize_dns_name(value: str | None) -> str | None:
    if value is None:
        return None
    parts = [part for part in value.strip().lower().split(".") if part]
    return ".".join(parts) or None


def normalize_cloud_image_file_name(value: str | None) -> str | None:
    if value is None:
        return None
    file_name = value.strip()
    if file_name.lower().endswith(".qcow2"):
        return f"{file_name[:-6]}.img"
    return file_name or None


def normalize_metallb_pool(value: str) -> str:
    raw = value.strip()
    if "-" not in raw:
        ipaddress.ip_network(raw, strict=False)
        return raw

    start_raw, end_raw = [part.strip() for part in raw.split("-", 1)]
    start_ip = ipaddress.ip_address(start_raw)
    if start_ip.version != 4:
        raise ValueError("only IPv4 MetalLB ranges are supported")

    if "." in end_raw:
        end_ip = ipaddress.ip_address(end_raw)
    else:
        octets = start_raw.split(".")
        octets[-1] = end_raw
        end_ip = ipaddress.ip_address(".".join(octets))

    if end_ip.version != 4 or int(end_ip) < int(start_ip):
        raise ValueError(f"invalid MetalLB pool '{raw}'")

    return f"{start_ip}-{end_ip}"


def validate_hostname(value: str, label: str, errors: list[str]) -> None:
    if not HOSTNAME_RE.fullmatch(value):
        errors.append(f"{label} '{value}' is not a valid lowercase hostname label.")


def validate_ip(value: str, label: str, errors: list[str]) -> None:
    try:
        ipaddress.ip_address(value)
    except ValueError:
        errors.append(f"{label} '{value}' is not a valid IP address.")


def normalize_data(data: dict) -> dict:
    if "cloud_image_url" not in data and "ubuntu_image_url" in data:
        data["cloud_image_url"] = data.pop("ubuntu_image_url")
    if "cloud_image_file_name" not in data and "ubuntu_image_file_name" in data:
        data["cloud_image_file_name"] = data.pop("ubuntu_image_file_name")
    if "os_family" not in data:
        data["os_family"] = "ubuntu"
    if "os_version" not in data:
        data["os_version"] = "24.04"
    if "ssh_username" not in data:
        data["ssh_username"] = "rocky" if data.get("os_family") == "rocky" else "ubuntu"
    if "enable_rocky_cockpit" not in data:
        data["enable_rocky_cockpit"] = False
    if "proxmox_csi_chart_version" not in data:
        data["proxmox_csi_chart_version"] = "0.5.4"
    elif str(data.get("proxmox_csi_chart_version")) == "0.18.1":
        # Normalize the older broken default to the current chart version.
        data["proxmox_csi_chart_version"] = "0.5.4"
    for key in (
        "install_portainer",
        "portainer_chart_version",
        "install_rancher",
        "cert_manager_chart_version",
        "rancher_chart_version",
        "rancher_hostname",
        "install_prometheus_stack",
        "prometheus_stack_chart_version",
        "install_loki_stack",
        "loki_stack_chart_version",
        "loki_persistence_enabled",
        "loki_storage_class",
        "loki_storage_size_gb",
    ):
        data.pop(key, None)
    data["cloud_image_file_name"] = normalize_cloud_image_file_name(data.get("cloud_image_file_name"))

    data["dns_domain"] = normalize_dns_domain(data.get("dns_domain"))
    if "metallb_address_pools" in data and isinstance(data["metallb_address_pools"], list):
        data["metallb_address_pools"] = [normalize_metallb_pool(pool) for pool in data["metallb_address_pools"]]

    nodes = data.get("nodes", {})
    for name, node in nodes.items():
        node["dns_name"] = normalize_dns_name(node.get("dns_name"))
        node.pop("mac_address", None)
        validate_hostname(name, "Node name", [])

    haproxy_node = data.get("haproxy_node")
    if isinstance(haproxy_node, dict):
        haproxy_node["dns_name"] = normalize_dns_name(haproxy_node.get("dns_name"))
        haproxy_node.pop("mac_address", None)

    return data


def validate_data(data: dict) -> list[str]:
    errors: list[str] = []

    cluster_name = data.get("cluster_name")
    if not isinstance(cluster_name, str) or not HOSTNAME_RE.fullmatch(cluster_name):
        errors.append("cluster_name must be a lowercase DNS-safe prefix such as 'lab-k8s'.")

    dns_domain = data.get("dns_domain")
    if dns_domain is not None and not DNS_RE.fullmatch(dns_domain):
        errors.append(
            f"dns_domain '{dns_domain}' is not a valid DNS suffix. Use values like 'local' or 'example.internal'."
        )

    os_family = data.get("os_family")
    if os_family not in {"ubuntu", "rocky"}:
        errors.append("os_family must be either 'ubuntu' or 'rocky'.")

    if not isinstance(data.get("os_version"), str) or not data.get("os_version"):
        errors.append("os_version must be a non-empty string.")

    if not isinstance(data.get("cloud_image_url"), str) or not data.get("cloud_image_url"):
        errors.append("cloud_image_url must be set.")

    if not isinstance(data.get("cloud_image_file_name"), str) or not data.get("cloud_image_file_name"):
        errors.append("cloud_image_file_name must be set.")

    gateway = data.get("gateway")
    prefix = data.get("prefix")
    cluster_network = None
    if isinstance(gateway, str):
        validate_ip(gateway, "gateway", errors)
    else:
        errors.append("gateway must be a valid IP address string.")
    if not isinstance(prefix, int) or prefix < 1 or prefix > 32:
        errors.append("prefix must be an integer between 1 and 32.")
    if isinstance(gateway, str) and isinstance(prefix, int):
        try:
            cluster_network = ipaddress.ip_network(f"{gateway}/{prefix}", strict=False)
        except ValueError:
            errors.append(f"gateway/prefix combination '{gateway}/{prefix}' is invalid.")

    if not isinstance(data.get("enable_rocky_cockpit"), bool):
        errors.append("enable_rocky_cockpit must be true or false.")

    ssh_username = data.get("ssh_username")
    if not isinstance(ssh_username, str) or not HOSTNAME_RE.fullmatch(ssh_username):
        errors.append("ssh_username must be a lowercase DNS-safe username such as 'ubuntu', 'rocky', 'admin', or 'operator'.")

    seen_ips: set[str] = set()
    seen_vmids: set[int] = set()

    nodes = data.get("nodes", {})
    if not isinstance(nodes, dict) or not nodes:
        errors.append("At least one node must be defined in 'nodes'.")
        return errors

    control_plane_count = 0

    for name, node in nodes.items():
        validate_hostname(name, "Node name", errors)

        role = node.get("role")
        if role not in {"controlplane", "worker"}:
            errors.append(f"Node '{name}' has invalid role '{role}'.")
        if role == "controlplane":
            control_plane_count += 1

        ip_value = node.get("ip")
        if isinstance(ip_value, str):
            validate_ip(ip_value, f"Node '{name}' IP", errors)
            if ip_value in seen_ips:
                errors.append(f"Duplicate node IP detected: {ip_value}")
            seen_ips.add(ip_value)
            if cluster_network is not None:
                try:
                    if ipaddress.ip_address(ip_value) not in cluster_network:
                        errors.append(
                            f"Node '{name}' IP '{ip_value}' is outside the configured gateway subnet '{cluster_network}'."
                        )
                except ValueError:
                    pass
        else:
            errors.append(f"Node '{name}' is missing a valid IP.")

        vmid = node.get("vm_id")
        if not isinstance(vmid, int):
            errors.append(f"Node '{name}' must have an integer vm_id.")
        elif vmid in seen_vmids:
            errors.append(f"Duplicate VM ID detected: {vmid}")
        else:
            seen_vmids.add(vmid)

        dns_name = node.get("dns_name")
        if dns_name is not None and not DNS_RE.fullmatch(dns_name):
            errors.append(f"Node '{name}' has invalid dns_name '{dns_name}'.")

    haproxy_node = data.get("haproxy_node")
    if control_plane_count > 1 and not isinstance(haproxy_node, dict):
        errors.append("haproxy_node must be defined when deploying more than one control plane.")
    if isinstance(haproxy_node, dict):
        name = haproxy_node.get("name")
        if isinstance(name, str):
            validate_hostname(name, "HAProxy name", errors)
        else:
            errors.append("haproxy_node.name must be set.")

        ip_value = haproxy_node.get("ip")
        if isinstance(ip_value, str):
            validate_ip(ip_value, "HAProxy IP", errors)
            if ip_value in seen_ips:
                errors.append(f"Duplicate HAProxy IP detected: {ip_value}")
            if cluster_network is not None:
                try:
                    if ipaddress.ip_address(ip_value) not in cluster_network:
                        errors.append(
                            f"HAProxy IP '{ip_value}' is outside the configured gateway subnet '{cluster_network}'."
                        )
                except ValueError:
                    pass
        else:
            errors.append("haproxy_node.ip must be set.")

        vmid = haproxy_node.get("vm_id")
        if not isinstance(vmid, int):
            errors.append("haproxy_node.vm_id must be an integer.")
        elif vmid in seen_vmids:
            errors.append(f"Duplicate VM ID detected: {vmid}")
        else:
            seen_vmids.add(vmid)

        dns_name = haproxy_node.get("dns_name")
        if dns_name is not None and not DNS_RE.fullmatch(dns_name):
            errors.append(f"HAProxy dns_name '{dns_name}' is invalid.")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate and normalize terraform.tfvars.json for the Proxmox kubeadm deployer.")
    parser.add_argument("--file", default="terraform.tfvars.json")
    parser.add_argument("--fix", action="store_true")
    args = parser.parse_args()

    path = Path(args.file)
    if not path.exists():
        print(f"Missing {path}", file=sys.stderr)
        return 1

    data = json.loads(path.read_text(encoding="utf-8"))
    normalized = normalize_data(data)
    errors = validate_data(normalized)

    original_text = path.read_text(encoding="utf-8")
    normalized_text = json.dumps(normalized, indent=2) + "\n"

    if args.fix and normalized_text != original_text:
        path.write_text(normalized_text, encoding="utf-8")
        print(f"Normalized {path}")

    if errors:
        for error in errors:
            print(f"Config error: {error}", file=sys.stderr)
        return 1

    print(f"Validated {path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        raise SystemExit(130)
