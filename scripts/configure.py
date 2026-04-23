#!/usr/bin/env python3
from __future__ import annotations

import argparse
import getpass
import ipaddress
import json
import os
import re
from pathlib import Path
import random
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

try:
    import readline  # noqa: F401
except ImportError:
    readline = None


DEFAULT_BOOTSTRAP_USERS = {
    "ubuntu": "ubuntu",
    "rocky": "rocky",
}

HOSTNAME_RE = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")

ANSI_RESET = "\033[0m"
ANSI_BOLD = "\033[1m"
ANSI_CYAN = "\033[36m"
ANSI_GREEN = "\033[32m"
ANSI_YELLOW = "\033[33m"
ANSI_MAGENTA = "\033[35m"
ANSI_DIM = "\033[2m"

DEFAULT_CHART_VERSIONS = {
    "cilium": "1.19.2",
    "traefik": "39.0.7",
    "proxmox-csi-plugin": "0.5.4",
}

OS_IMAGE_PRESETS = {
    "ubuntu": [
        {
            "label": "Ubuntu 25.04",
            "version": "25.04",
            "url": "https://cloud-images.ubuntu.com/plucky/current/plucky-server-cloudimg-amd64.img",
            "file_name": "plucky-server-cloudimg-amd64.img",
        },
        {
            "label": "Ubuntu 24.10",
            "version": "24.10",
            "url": "https://cloud-images.ubuntu.com/oracular/current/oracular-server-cloudimg-amd64.img",
            "file_name": "oracular-server-cloudimg-amd64.img",
        },
        {
            "label": "Ubuntu 24.04",
            "version": "24.04",
            "url": "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img",
            "file_name": "noble-server-cloudimg-amd64.img",
        },
    ],
    "rocky": [
        {
            "label": "Rocky 9 latest",
            "version": "9-latest",
            "url": "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2",
            "file_name": "Rocky-9-GenericCloud.latest.x86_64.img",
        },
        {
            "label": "Rocky 9.5",
            "version": "9.5",
            "url": "https://download.rockylinux.org/pub/rocky/9.5/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2",
            "file_name": "Rocky-9.5-GenericCloud.latest.x86_64.img",
        },
        {
            "label": "Rocky 9.4",
            "version": "9.4",
            "url": "https://download.rockylinux.org/pub/rocky/9.4/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2",
            "file_name": "Rocky-9.4-GenericCloud.latest.x86_64.img",
        },
    ],
}


def style_prompt_label(text: str) -> str:
    return colorize(text, f"{ANSI_CYAN}{ANSI_BOLD}")


def style_choice_label(choices: list[str], color_code: str = ANSI_MAGENTA) -> str:
    return colorize("/".join(choices), color_code)


def read_prompt(rendered: str, *, secret: bool = False) -> str:
    if secret:
        return getpass.getpass(rendered)
    sys.stdout.write(rendered)
    sys.stdout.flush()
    value = sys.stdin.readline()
    if value == "":
        raise EOFError
    return value.rstrip("\n")


def prompt(text: str, default: str | None = None, secret: bool = False) -> str:
    if supports_color():
        suffix = f" [{style_default_value(default)}]" if default not in (None, "") else ""
        rendered = f"{style_prompt_label(text)}{suffix}: "
    else:
        suffix = f" [{default}]" if default not in (None, "") else ""
        rendered = f"{text}{suffix}: "
    while True:
        value = read_prompt(rendered, secret=secret)
        value = value.strip()
        if value:
            return value
        if default is not None:
            return default


def prompt_optional_secret(text: str) -> str | None:
    rendered = f"{style_prompt_label(text) if supports_color() else text}: "
    value = read_prompt(rendered, secret=True).strip()
    return value or None


def prompt_choice(text: str, choices: list[str], default: str | None = None, choices_color: str = ANSI_MAGENTA) -> str:
    choice_set = set(choices)
    choices_label = style_choice_label(choices, choices_color) if supports_color() else "/".join(choices)
    prompt_text = f"{text} ({choices_label})"
    while True:
        value = prompt(prompt_text, default)
        if value in choice_set:
            return value
        print(colorize(f"Choose one of: {', '.join(choices)}", ANSI_YELLOW))


def prompt_storage(text: str, available_storages: list[str], default: str) -> str:
    if available_storages:
        return prompt_choice(text, available_storages, default, choices_color=ANSI_CYAN)
    return prompt(text, default)


def select_default(preferred: list[str], fallback: list[str], hard_default: str) -> str:
    for candidate in preferred:
        if candidate in fallback:
            return candidate
    if fallback:
        return fallback[0]
    return hard_default


def style_inline_values(values: list[str], color_code: str = ANSI_CYAN) -> str:
    if not values:
        return "none"
    if not supports_color():
        return ", ".join(values)
    separator = f"{ANSI_DIM}, {ANSI_RESET}"
    return separator.join(colorize(value, color_code) for value in values)


def prompt_optional_int(text: str, default: int | None = None) -> int | None:
    rendered_default = "" if default is None else str(default)
    while True:
        raw = prompt(text, rendered_default)
        if raw == "":
            return default
        try:
            return int(raw)
        except ValueError:
            print(colorize("Enter a whole number or leave it blank.", ANSI_YELLOW))


def prompt_optional_int_with_choices(text: str, default: int | None = None) -> int | None:
    rendered_default = "" if default is None else str(default)
    while True:
        raw = prompt(text, rendered_default)
        if raw == "":
            return default
        lowered = raw.lower()
        if lowered in {"none", "null"}:
            return None
        try:
            return int(raw)
        except ValueError:
            print(colorize("Enter a whole number, leave it blank, or type none.", ANSI_YELLOW))


def prompt_csv_ips(text: str, default: str) -> list[str]:
    while True:
        try:
            return [parse_ip(item.strip()) for item in prompt(text, default).split(",") if item.strip()]
        except ValueError as exc:
            print(colorize(f"Invalid IP list: {exc}", ANSI_YELLOW))


REPO_ROOT = Path(__file__).resolve().parent.parent
DEPLOYMENT_HISTORY_DIR = REPO_ROOT / "out" / "deployment-history"


def load_history_snapshot(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def iter_history_snapshots(exclude_cluster_name: str | None = None) -> list[dict]:
    snapshots: list[dict] = []
    if not DEPLOYMENT_HISTORY_DIR.exists():
        return snapshots

    for snapshot_path in sorted(DEPLOYMENT_HISTORY_DIR.glob('*/last-applied.tfvars.json')):
        snapshot = load_history_snapshot(snapshot_path)
        if not isinstance(snapshot, dict):
            continue
        if exclude_cluster_name and str(snapshot.get("cluster_name", "")).strip() == exclude_cluster_name:
            continue
        snapshots.append(snapshot)
    return snapshots


def history_ipv4_usage(state: dict[str, object]) -> tuple[list[str], list[str]]:
    cluster_name = str(state.get("cluster_name", "")).strip() or None
    gateway = str(state.get("gateway", "")).strip()
    prefix = state.get("prefix")

    network = None
    if gateway and prefix not in (None, ""):
        try:
            network = ipaddress.ip_network(f"{gateway}/{int(prefix)}", strict=False)
        except ValueError:
            network = None

    cluster_ips: set[str] = set()
    load_balancer_ips: set[str] = set()

    def record_ip(target: set[str], raw: object) -> None:
        if not isinstance(raw, str) or not raw.strip():
            return
        try:
            ip_obj = ipaddress.ip_address(raw.strip())
        except ValueError:
            return
        if ip_obj.version != 4:
            return
        if network is not None and ip_obj not in network:
            return
        target.add(str(ip_obj))

    for snapshot in iter_history_snapshots(cluster_name):
        nodes = snapshot.get("nodes", {})
        if isinstance(nodes, dict):
            for node in nodes.values():
                if isinstance(node, dict):
                    record_ip(cluster_ips, node.get("ip"))

        record_ip(cluster_ips, snapshot.get("kube_vip_ip"))

        pools = snapshot.get("load_balancer_ip_pools", [])
        if isinstance(pools, list):
            for pool in pools:
                if not isinstance(pool, str) or not pool.strip():
                    continue
                try:
                    for ip_value in expand_ipv4_range(pool.strip()):
                        record_ip(load_balancer_ips, ip_value)
                except ValueError:
                    continue

    return sorted(cluster_ips, key=lambda value: int(ipaddress.ip_address(value))), sorted(load_balancer_ips, key=lambda value: int(ipaddress.ip_address(value)))


def next_recorded_ip(values: list[str]) -> str | None:
    if not values:
        return None
    return str(ipaddress.ip_address(values[-1]) + 1)


def suggest_range(start_ip: str, count: int) -> str:
    values = next_ips(start_ip, count)
    return compact_ipv4_range(values[0], values[-1])


def prompt_load_balancer_ip_pools(default: str) -> list[str]:
    default_pools = [item.strip() for item in default.split(",") if item.strip()]
    default_start_ip = "192.168.1.240"
    default_count = 10

    if len(default_pools) == 1:
        try:
            expanded = expand_ipv4_range(default_pools[0])
            if expanded:
                default_start_ip = expanded[0]
                default_count = len(expanded)
        except ValueError:
            pass

    start_ip = parse_ip(prompt("Cilium LoadBalancer starting IP", default_start_ip))
    count = prompt_int("Cilium LoadBalancer IP count", default_count, minimum=1)
    allocated_ips = next_ips(start_ip, count)
    return [compact_ipv4_range(allocated_ips[0], allocated_ips[-1])]


def expand_ipv4_range(raw: str) -> list[str]:
    value = raw.strip()
    if "-" not in value:
        return [parse_ip(value)]

    start_raw, end_raw = [part.strip() for part in value.split("-", 1)]
    start_ip = ipaddress.ip_address(start_raw)
    if start_ip.version != 4:
        raise ValueError("only IPv4 ranges are supported here")

    if "." in end_raw:
        end_ip = ipaddress.ip_address(end_raw)
    else:
        octets = start_raw.split(".")
        octets[-1] = end_raw
        end_ip = ipaddress.ip_address(".".join(octets))

    if end_ip.version != 4 or int(end_ip) < int(start_ip):
        raise ValueError("range end must be greater than or equal to the start")

    return [str(start_ip + offset) for offset in range(int(end_ip) - int(start_ip) + 1)]


def normalize_load_balancer_ip_pool(raw: str) -> str:
    value = raw.strip()
    if "-" not in value:
        ipaddress.ip_network(value, strict=False)
        return value

    start_raw, end_raw = [part.strip() for part in value.split("-", 1)]
    start_ip = ipaddress.ip_address(start_raw)
    if start_ip.version != 4:
        raise ValueError("only IPv4 ranges are supported here")

    if "." in end_raw:
        end_ip = ipaddress.ip_address(end_raw)
    else:
        octets = start_raw.split(".")
        octets[-1] = end_raw
        end_ip = ipaddress.ip_address(".".join(octets))

    if end_ip.version != 4 or int(end_ip) < int(start_ip):
        raise ValueError(f"invalid IP range '{value}'")

    return f"{start_ip}-{end_ip}"


def compact_ipv4_range(start_ip: str, end_ip: str) -> str:
    start = ipaddress.ip_address(start_ip)
    end = ipaddress.ip_address(end_ip)
    if start.version != 4 or end.version != 4:
        raise ValueError("only IPv4 ranges are supported here")
    if int(end) < int(start):
        raise ValueError("range end must be greater than or equal to the start")
    if start == end:
        return str(start)

    start_parts = str(start).split(".")
    end_parts = str(end).split(".")
    if start_parts[:-1] == end_parts[:-1]:
        return f"{start}-{end_parts[-1]}"
    return f"{start}-{end}"


def prompt_ip_range(text: str, default: str, required_count: int) -> list[str]:
    while True:
        try:
            ips = expand_ipv4_range(prompt(text, default))
        except ValueError as exc:
            print(colorize(f"Invalid IP range: {exc}", ANSI_YELLOW))
            continue
        if len(ips) < required_count:
            print(colorize(f"Range must include at least {required_count} IP(s).", ANSI_YELLOW))
            continue
        return ips


def normalize_chart_version_candidate(raw: str) -> str:
    value = raw.strip().strip('"').strip("'")
    match = re.search(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?", value)
    return match.group(0) if match else value


def fetch_chart_versions(index_url: str, chart_name: str, limit: int = 6) -> list[str]:
    try:
        text = fetch_text(index_url)
    except Exception:
        return []

    section_header = f"  {chart_name}:"
    lines = text.splitlines()
    start_index: int | None = None
    for index, line in enumerate(lines):
        if line.rstrip() == section_header:
            start_index = index + 1
            break

    if start_index is None:
        return []

    versions: list[str] = []
    for line in lines[start_index:]:
        if line.startswith("  ") and not line.startswith("    ") and line.strip().endswith(":"):
            break

        match = re.match(r"^ {6}version:\s*(.+?)\s*$", line)
        if not match:
            continue

        version = normalize_chart_version_candidate(match.group(1))
        if version not in versions:
            versions.append(version)
            if len(versions) >= limit:
                break

    return versions


def re_match_version_line(line: str) -> bool:
    stripped = line.lstrip()
    return stripped.startswith("version:")


def prompt_chart_version(name: str, default: str, index_url: str, chart_name: str) -> str:
    print(f"\nChecking {name} chart versions...")
    versions = fetch_chart_versions(index_url, chart_name)
    if versions:
        effective_default = default if default in versions else versions[0]
        for idx, version in enumerate(versions, start=1):
            marker = f" {colorize('(recommended)', ANSI_GREEN)}" if version == effective_default else ""
            print(f"  {idx}. {version}{marker}")
        print("  c. custom version")

        while True:
            choice = read_prompt(f"Select {name} chart version [{style_default_value(effective_default)}]: ").strip().lower()
            if not choice:
                return effective_default
            if choice == "c":
                return prompt(f"Custom {name} chart version", effective_default)
            if choice.isdigit():
                index = int(choice)
                if 1 <= index <= len(versions):
                    return versions[index - 1]
            print("Pick a listed number, press Enter for the default, or choose c for custom.")

    print(f"Unable to fetch {name} chart versions right now.")
    print(f"  1. {default} {colorize('(recommended)', ANSI_GREEN)}")
    print("  c. custom version")
    while True:
        choice = read_prompt(f"Select {name} chart version [{style_default_value(default)}]: ").strip().lower()
        if not choice or choice == "1":
            return default
        if choice == "c":
            return prompt(f"Custom {name} chart version", default)
        print("Pick 1 for the recommended version, or c for custom.")


def prompt_int(text: str, default: int, minimum: int = 0) -> int:
    while True:
        raw = prompt(text, str(default))
        try:
            value = int(raw)
        except ValueError:
            print("Enter a whole number.")
            continue
        if value < minimum:
            print(f"Enter a value >= {minimum}.")
            continue
        return value


def prompt_bool(text: str, default: bool) -> bool:
    default_label = "Y/n" if default else "y/N"
    while True:
        if supports_color():
            raw = read_prompt(f"{style_prompt_label(text)} [{style_default_value(default_label)}]: ").strip().lower()
        else:
            raw = read_prompt(f"{text} [{default_label}]: ").strip().lower()
        if not raw:
            return default
        if raw in {"y", "yes"}:
            return True
        if raw in {"n", "no"}:
            return False
        print(colorize("Enter yes or no.", ANSI_YELLOW))


def prompt_hostname_label(text: str, default: str) -> str:
    while True:
        value = prompt(text, default).strip().lower()
        if HOSTNAME_RE.fullmatch(value):
            return value
        print(colorize("Use a lowercase username like ubuntu, rocky, admin, or operator.", ANSI_YELLOW))


def supports_color() -> bool:
    return sys.stdout.isatty() and os.environ.get("TERM", "").lower() != "dumb"


def colorize(text: str, color_code: str) -> str:
    if not supports_color():
        return text
    return f"{color_code}{text}{ANSI_RESET}"


def style_default_value(value: str | None) -> str:
    if value in (None, ""):
        return ""
    return colorize(str(value), ANSI_YELLOW)


def freelens_is_installed() -> bool:
    if shutil_which("freelens"):
        return True
    if sys.platform == "darwin":
        return Path("/Applications/Freelens.app").exists() or Path.home().joinpath("Applications/Freelens.app").exists()
    return False


def shutil_which(command: str) -> str | None:
    return subprocess.run(
        ["sh", "-c", f"command -v {command}"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip() or None


def print_optional_freelens_hint() -> None:
    print("\nOptional kube manager:")
    if sys.platform == "darwin" and shutil_which("brew"):
        print("  Freelens is not installed. You can add it later with: brew install --cask freelens")
    else:
        print("  Freelens is not installed. You can add it later from: https://freelensapp.github.io/")


def print_optional_kubectx_hint() -> None:
    print("\nOptional multi-cluster helper:")
    if sys.platform == "darwin" and shutil_which("brew"):
        print("  kubectx is not installed. You can add it later with: brew install kubectx")
    else:
        print("  kubectx is not installed. You can add it later from: https://github.com/ahmetb/kubectx")


def normalize_proxmox_api_url(raw: str) -> str:
    value = raw.strip()
    if "://" not in value:
        value = f"https://{value}:8006"
    parsed = urllib.parse.urlparse(value)
    if not parsed.scheme or not parsed.netloc:
        raise ValueError("Provide a hostname or a full https:// URL.")
    base = f"{parsed.scheme}://{parsed.netloc}"
    if not base.endswith("/api2/json"):
        base = f"{base}/api2/json"
    return base


def parse_ip(value: str) -> str:
    return str(ipaddress.ip_address(value))


def cluster_network(gateway: str, prefix: int) -> ipaddress._BaseNetwork:
    return ipaddress.ip_network(f"{gateway}/{prefix}", strict=False)


def subnet_mismatch_messages(state: dict[str, object]) -> list[str]:
    gateway = state.get("gateway")
    prefix = state.get("prefix")
    if not isinstance(gateway, str) or not isinstance(prefix, int):
        return []

    try:
        network = cluster_network(gateway, prefix)
    except ValueError:
        return []

    messages: list[str] = []

    def check_ip(label: str, value: object) -> None:
        if not isinstance(value, str) or not value:
            return
        try:
            if ipaddress.ip_address(value) not in network:
                messages.append(f"{label} {value} is outside the configured gateway subnet {network}.")
        except ValueError:
            return

    for index, ip_value in enumerate(state.get("cp_ips", []) or [], start=1):
        check_ip(f"Control plane {index} IP", ip_value)
    for index, ip_value in enumerate(state.get("wk_ips", []) or [], start=1):
        check_ip(f"Worker {index} IP", ip_value)
    check_ip("kube-vip IP", state.get("kube_vip_ip"))

    for pool in state.get("load_balancer_ip_pools", []) or []:
        if not isinstance(pool, str) or not pool:
            continue
        raw = pool.strip()
        if "-" not in raw:
            try:
                if ipaddress.ip_network(raw, strict=False).network_address not in network:
                    messages.append(f"LoadBalancer IP pool {raw} does not align with the configured gateway subnet {network}.")
            except ValueError:
                continue
            continue

        start_raw, end_raw = [part.strip() for part in raw.split("-", 1)]
        try:
            start_ip = ipaddress.ip_address(start_raw)
            end_ip = ipaddress.ip_address(end_raw)
        except ValueError:
            continue
        if start_ip not in network or end_ip not in network:
            messages.append(f"LoadBalancer IP pool {raw} is outside the configured gateway subnet {network}.")

    return messages


def enforce_network_consistency(state: dict[str, object]) -> None:
    messages = subnet_mismatch_messages(state)
    if not messages:
        return

    print(f"\n{colorize('Network consistency check', ANSI_CYAN)}")
    for message in messages:
        print(f"  - {message}")
    if prompt_bool("Keep these mismatched network settings intentionally", False):
        state["allow_subnet_mismatch"] = True
        return
    raise ValueError("Planned node/network settings do not match the configured gateway subnet.")


def normalize_dns_domain(value: str | None) -> str | None:
    if value is None:
        return None
    normalized = value.strip().lower().strip(".")
    return normalized or None


def proxmox_cloud_image_file_name(value: str) -> str:
    file_name = value.strip()
    if file_name.lower().endswith(".qcow2"):
        return f"{file_name[:-6]}.img"
    return file_name


def password_hash(password: str) -> str:
    result = subprocess.run(
        ["openssl", "passwd", "-6", "-stdin"],
        input=f"{password}\n",
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


def choose_os_image() -> tuple[str, str, str, str]:
    family = prompt_choice("Guest OS family", ["ubuntu", "rocky"], "ubuntu")
    presets = OS_IMAGE_PRESETS[family]

    print(f"\nChecking curated {family.title()} image presets...")
    for idx, preset in enumerate(presets, start=1):
        marker = f" {colorize('(recommended)', ANSI_GREEN)}" if idx == 1 else ""
        print(f"  {idx}. {preset['label']}{marker}")
    print("  c. custom version")

    selected: dict[str, str] | None = None
    while selected is None:
        choice = read_prompt(f"Select {family.title()} version [{1}]: ").strip().lower()
        if not choice or choice == "1":
            selected = presets[0]
            break
        if choice == "c":
            version = prompt(f"Custom {family.title()} version label", presets[0]["version"])
            default_url = prompt("Cloud image URL", presets[0]["url"])
            parsed = urllib.parse.urlparse(default_url)
            default_file_name = proxmox_cloud_image_file_name(os.path.basename(parsed.path) or presets[0]["file_name"])
            file_name = proxmox_cloud_image_file_name(prompt("Downloaded cloud image file name", default_file_name))
            return family, version, default_url, file_name
        if choice.isdigit():
            index = int(choice)
            if 1 <= index <= len(presets):
                selected = presets[index - 1]
                break
        print("Pick a listed number, press Enter for the default, or choose c for custom.")

    image_url = prompt("Cloud image URL", selected["url"])
    image_file_name = proxmox_cloud_image_file_name(prompt("Downloaded cloud image file name", selected["file_name"]))
    return family, selected["version"], image_url, image_file_name


def bootstrap_user_for_os(os_family: str) -> str:
    return DEFAULT_BOOTSTRAP_USERS.get(os_family, "ubuntu")


def ensure_local_ssh_public_key(path: str | None = None) -> str:
    private_key_path = Path(path or "~/.ssh/id_ed25519").expanduser()
    public_key_path = private_key_path.with_name(private_key_path.name + ".pub")

    if not private_key_path.exists() or not public_key_path.exists():
        private_key_path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["ssh-keygen", "-t", "ed25519", "-f", str(private_key_path), "-N", ""],
            check=True,
        )

    return public_key_path.read_text(encoding="utf-8").strip()


def next_ips(start_ip: str, count: int) -> list[str]:
    start = ipaddress.ip_address(start_ip)
    return [str(start + offset) for offset in range(count)]


def next_available_vmids(used_vmids: set[int], count: int, start: int) -> list[int]:
    vmids: list[int] = []
    candidate = start
    while len(vmids) < count:
        if candidate not in used_vmids and candidate not in vmids:
            vmids.append(candidate)
        candidate += 1
    return vmids


def next_vmid_seed(used_vmids: set[int], minimum: int = 100) -> int:
    if not used_vmids:
        return minimum
    return max(minimum, max(used_vmids) + 1)


def ensure_unique_vmids(vmids: list[int]) -> None:
    seen: set[int] = set()
    duplicates: list[int] = []
    for vmid in vmids:
        if vmid in seen and vmid not in duplicates:
            duplicates.append(vmid)
        seen.add(vmid)
    if duplicates:
        joined = ", ".join(str(vmid) for vmid in sorted(duplicates))
        raise ValueError(f"Duplicate VM ID(s) planned: {joined}")


def prompt_ip_assignment(role_label: str, count: int, default_start_ip: str) -> list[str]:
    if count == 0:
        return []

    mode = prompt_choice(f"{role_label} IP assignment mode", ["range", "manual"], "range")
    if mode == "manual":
        default_ips = next_ips(default_start_ip, count)
        ips: list[str] = []
        for index in range(count):
            label = f"{role_label} node {index + 1} IP"
            ips.append(parse_ip(prompt(label, default_ips[index])))
        return ips

    start_ip = parse_ip(prompt(f"{role_label} starting IP", default_start_ip))
    return next_ips(start_ip, count)


def prompt_vmid_assignment(role_label: str, count: int, used_vmids: set[int], default_start_vmid: int) -> list[int]:
    if count == 0:
        return []

    mode = prompt_choice(f"{role_label} VM ID assignment mode", ["auto", "range", "manual"], "auto")
    if mode == "manual":
        vmids: list[int] = []
        for index in range(count):
            vmid = prompt_int(f"{role_label} node {index + 1} VM ID", default_start_vmid + index, minimum=100)
            vmids.append(vmid)
        return vmids
    if mode == "range":
        start_vmid = prompt_int(f"{role_label} starting VM ID", default_start_vmid, minimum=100)
        return list(range(start_vmid, start_vmid + count))
    return next_available_vmids(used_vmids, count, default_start_vmid)


def prompt_single_vmid(label: str, used_vmids: set[int], default_vmid: int) -> int:
    mode = prompt_choice(f"{label} VM ID assignment mode", ["auto", "manual"], "auto")
    if mode == "manual":
        return prompt_int(f"{label} VM ID", default_vmid, minimum=100)
    return next_available_vmids(used_vmids, 1, default_vmid)[0]


def control_plane_node_name(prefix: str, index: int, total: int) -> str:
    if total == 1:
        return f"{prefix}-cp"
    return f"{prefix}-cp{index}"


def worker_node_name(prefix: str, index: int, total: int) -> str:
    if total == 1:
        return f"{prefix}-wk"
    return f"{prefix}-wk{index}"


@dataclass
class ProxmoxClient:
    api_url: str
    username: str
    password: str
    insecure: bool

    def __post_init__(self) -> None:
        if self.insecure:
            self.ssl_context = ssl._create_unverified_context()
        else:
            self.ssl_context = ssl.create_default_context()
        self.cookie = None
        self.csrf_token = None

    def request(self, method: str, path: str, payload: dict[str, str] | None = None) -> dict:
        url = f"{self.api_url}{path}"
        data = None
        headers = {}

        if payload is not None:
            data = urllib.parse.urlencode(payload).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"

        if self.cookie:
            headers["Cookie"] = f"PVEAuthCookie={self.cookie}"
        if self.csrf_token and method != "GET":
            headers["CSRFPreventionToken"] = self.csrf_token

        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        with urllib.request.urlopen(request, context=self.ssl_context, timeout=20) as response:
            return json.loads(response.read().decode())

    def login(self) -> None:
        response = self.request(
            "POST",
            "/access/ticket",
            payload={"username": self.username, "password": self.password},
        )
        data = response["data"]
        self.cookie = data["ticket"]
        self.csrf_token = data["CSRFPreventionToken"]

    def get(self, path: str) -> dict:
        return self.request("GET", path)


def discover_kubernetes_versions() -> list[str]:
    versions = []
    stable = fetch_text("https://dl.k8s.io/release/stable.txt").lstrip("v")
    versions.append(stable)

    stable_minor = ".".join(stable.split(".")[:2])
    major, minor = stable_minor.split(".")
    for candidate_minor in range(int(minor), max(int(minor) - 6, 23), -1):
        candidate = f"{major}.{candidate_minor}"
        try:
            version = fetch_text(f"https://dl.k8s.io/release/stable-{candidate}.txt").lstrip("v")
        except Exception:
            continue
        if version not in versions:
            versions.append(version)
    return versions


def fetch_text(url: str) -> str:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "proxmox-kubeadm-deployer/1.0",
            "Accept": "text/plain, application/x-yaml, application/yaml, text/yaml, */*",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode().strip()


def choose_kubernetes_version() -> str:
    print("\nChecking Kubernetes releases from dl.k8s.io...")
    versions = discover_kubernetes_versions()
    for idx, version in enumerate(versions, start=1):
        marker = f" {colorize('(recommended)', ANSI_GREEN)}" if idx == 1 else ""
        print(f"  {idx}. {version}{marker}")
    print("  c. custom version")

    while True:
        choice = read_prompt(f"Select Kubernetes version [{style_default_value(versions[0])}]: ").strip().lower()
        if not choice:
            return versions[0]
        if choice == "c":
            return prompt("Custom Kubernetes version", versions[0])
        if choice.isdigit():
            index = int(choice)
            if 1 <= index <= len(versions):
                return versions[index - 1]
        print("Pick a listed number or c for custom.")


def summarize_nodes(nodes: dict[str, dict], kube_vip_ip: str | None) -> None:
    print(f"\n{style_prompt_label('Planned nodes')}:")
    name_width = max((len(name) for name in nodes), default=len("vip"))
    role_width = max((len(str(node["role"])) for node in nodes.values()), default=len("endpoint"))
    ip_width = max((len(str(node["ip"])) for node in nodes.values()), default=len(kube_vip_ip or ""))

    for name, node in nodes.items():
        role_color = ANSI_GREEN if node["role"] == "controlplane" else ANSI_CYAN
        role_label = colorize(f"{node['role']:<12}", role_color)
        node_name = colorize(f"{name:<{name_width}}", ANSI_MAGENTA)
        node_ip = colorize(f"{node['ip']:<{ip_width}}", ANSI_YELLOW)
        vmid = colorize(str(node["vm_id"]), ANSI_CYAN)
        host_node = colorize(str(node["host_node"]), ANSI_CYAN)
        print(f"  {node_name} {colorize(f'{node['role']:<{role_width}}', role_color)} {node_ip} vmid={vmid} host={host_node}")
    if kube_vip_ip:
        vip_name = colorize(f"{'vip':<{name_width}}", ANSI_MAGENTA)
        vip_role = colorize(f"{'endpoint':<{role_width}}", ANSI_GREEN)
        vip_ip = colorize(f"{kube_vip_ip:<{ip_width}}", ANSI_YELLOW)
        print(f"  {vip_name} {vip_role} {vip_ip}")


def ensure_available_vmids(used_vmids: set[int], vmids: list[int]) -> None:
    conflicts = sorted(vmid for vmid in vmids if vmid in used_vmids)
    if conflicts:
        joined = ", ".join(str(vmid) for vmid in conflicts)
        raise ValueError(f"VM ID(s) already in use: {joined}")


def is_contiguous_ips(ips: list[str]) -> bool:
    if len(ips) < 2:
        return True
    parsed = [ipaddress.ip_address(ip) for ip in ips]
    return all(int(parsed[index]) == int(parsed[0]) + index for index in range(len(parsed)))


def is_contiguous_vmids(vmids: list[int]) -> bool:
    if len(vmids) < 2:
        return True
    return all(vmids[index] == vmids[0] + index for index in range(len(vmids)))


def prompt_ip_assignment_with_existing(role_label: str, count: int, current_ips: list[str], default_start_ip: str) -> list[str]:
    if count == 0:
        return []
    if current_ips and len(current_ips) == count and not is_contiguous_ips(current_ips):
        mode_default = "manual"
    else:
        mode_default = "range"
    mode = prompt_choice(f"{role_label} IP assignment mode", ["range", "manual"], mode_default)
    if mode == "manual":
        default_ips = current_ips if current_ips and len(current_ips) == count else next_ips(default_start_ip, count)
        ips: list[str] = []
        for index in range(count):
            ips.append(parse_ip(prompt(f"{role_label} node {index + 1} IP", default_ips[index])))
        return ips

    range_default = current_ips[0] if current_ips else default_start_ip
    start_ip = parse_ip(prompt(f"{role_label} starting IP", range_default))
    return next_ips(start_ip, count)


def prompt_vmid_assignment_with_existing(
    role_label: str,
    count: int,
    used_vmids: set[int],
    current_vmids: list[int],
    default_start_vmid: int,
) -> list[int]:
    if count == 0:
        return []
    if current_vmids and len(current_vmids) == count:
        if is_contiguous_vmids(current_vmids):
            mode_default = "range"
        else:
            mode_default = "manual"
    else:
        mode_default = "auto"

    mode = prompt_choice(f"{role_label} VM ID assignment mode", ["auto", "range", "manual"], mode_default)
    if mode == "manual":
        vmids: list[int] = []
        manual_defaults = current_vmids if current_vmids and len(current_vmids) == count else list(range(default_start_vmid, default_start_vmid + count))
        for index in range(count):
            vmids.append(prompt_int(f"{role_label} node {index + 1} VM ID", manual_defaults[index], minimum=100))
        return vmids
    if mode == "range":
        range_default = current_vmids[0] if current_vmids else default_start_vmid
        start_vmid = prompt_int(f"{role_label} starting VM ID", range_default, minimum=100)
        return list(range(start_vmid, start_vmid + count))
    return next_available_vmids(used_vmids, count, default_start_vmid)


def prompt_single_vmid_with_existing(label: str, used_vmids: set[int], current_vmid: int | None, default_vmid: int) -> int:
    mode_default = "manual" if current_vmid is not None else "auto"
    mode = prompt_choice(f"{label} VM ID assignment mode", ["auto", "manual"], mode_default)
    if mode == "manual":
        return prompt_int(f"{label} VM ID", current_vmid if current_vmid is not None else default_vmid, minimum=100)
    return next_available_vmids(used_vmids, 1, default_vmid)[0]


def prompt_cluster_identity_section(state: dict[str, object], cluster_name_default: str) -> None:
    state["cluster_name"] = prompt("Cluster / hostname prefix", str(state.get("cluster_name", "lab-k8s")))
    dns_domain = prompt(
        "DNS suffix for auto-generated FQDNs, for example local or example.com (blank to skip)",
        str(state.get("dns_domain") or ""),
    )
    state["dns_domain"] = normalize_dns_domain(dns_domain)
    state["proxmox_region"] = prompt(
        "Proxmox region/cluster label for CSI topology",
        str(state.get("proxmox_region", cluster_name_default)),
    )


def prompt_platform_section(state: dict[str, object]) -> None:
    os_family, os_version, cloud_image_url, cloud_image_file_name = choose_os_image()
    state["os_family"] = os_family
    state["ssh_username"] = bootstrap_user_for_os(os_family)
    state["os_version"] = os_version
    state["cloud_image_url"] = cloud_image_url
    state["cloud_image_file_name"] = cloud_image_file_name
    state["kubernetes_version"] = choose_kubernetes_version()


def prompt_network_storage_section(
    state: dict[str, object],
    proxmox_nodes: list[str],
    storages_by_node: dict[str, list[dict]],
) -> None:
    default_host = str(state.get("host_node", proxmox_nodes[0]))
    host_node = prompt_choice("Target Proxmox node for the VMs", proxmox_nodes, default_host)
    state["host_node"] = host_node

    storage_entries = storages_by_node.get(host_node, [])
    available_storages = sorted({entry["storage"] for entry in storage_entries})
    vm_storage_candidates = sorted({
        entry["storage"]
        for entry in storage_entries
        if "images" in str(entry.get("content", "")).split(",")
    }) or available_storages
    image_storage_candidates = sorted({
        entry["storage"]
        for entry in storage_entries
        if "iso" in str(entry.get("content", "")).split(",")
    }) or available_storages
    snippet_storage_candidates = sorted({
        entry["storage"]
        for entry in storage_entries
        if "snippets" in str(entry.get("content", "")).split(",")
    }) or available_storages

    storage_summary = ", ".join(available_storages) if available_storages else "none returned by the API"
    vm_storage_summary = ", ".join(vm_storage_candidates) if vm_storage_candidates else "none returned by the API"
    image_storage_summary = ", ".join(image_storage_candidates) if image_storage_candidates else "none returned by the API"
    snippet_storage_summary = ", ".join(snippet_storage_candidates) if snippet_storage_candidates else "none returned by the API"

    print(f"\nAll datastores on {host_node}: {style_inline_values(available_storages, ANSI_CYAN)}")
    print(f"VM disk candidates: {style_inline_values(vm_storage_candidates, ANSI_CYAN)}")
    print(f"Cloud image candidates: {style_inline_values(image_storage_candidates, ANSI_CYAN)}")
    print(f"Snippet candidates: {style_inline_values(snippet_storage_candidates, ANSI_CYAN)}")

    state["bridge"] = prompt("Bridge", str(state.get("bridge", "vmbr0")))
    state["gateway"] = parse_ip(prompt("Gateway", str(state.get("gateway", "192.168.1.1"))))
    state["prefix"] = prompt_int("Subnet prefix length", int(state.get("prefix", 24)), minimum=1)
    state["dns_servers"] = prompt_csv_ips(
        "DNS servers (comma separated)",
        ",".join(state.get("dns_servers", ["1.1.1.1", "8.8.8.8"])),
    )

    storage_default = select_default(["mega-pool", "local-lvm"], vm_storage_candidates, "local-lvm")
    image_default = select_default(["local"], image_storage_candidates, "local")
    snippets_default = select_default(["local"], snippet_storage_candidates, "local")

    state["vm_datastore"] = prompt_storage("VM disk datastore", vm_storage_candidates, str(state.get("vm_datastore", storage_default)))
    state["image_datastore"] = prompt_storage("Cloud image datastore", image_storage_candidates, str(state.get("image_datastore", image_default)))
    state["cloudinit_datastore"] = prompt_storage(
        "Cloud-init datastore",
        vm_storage_candidates,
        str(state.get("cloudinit_datastore", state["vm_datastore"])),
    )
    state["snippets_datastore"] = prompt_storage(
        "Snippets datastore",
        snippet_storage_candidates,
        str(state.get("snippets_datastore", snippets_default)),
    )


def prompt_access_section(state: dict[str, object], ssh_username: str) -> None:
    default_bootstrap_user = bootstrap_user_for_os(str(state.get("os_family", "ubuntu")))
    use_default_bootstrap_user = prompt_bool(
        f"Use the default bootstrap username '{default_bootstrap_user}'",
        ssh_username == default_bootstrap_user,
    )
    if use_default_bootstrap_user:
        ssh_username = default_bootstrap_user
    else:
        custom_default = ssh_username if ssh_username else default_bootstrap_user
        ssh_username = prompt_hostname_label("Custom bootstrap username", custom_default)
    state["ssh_username"] = ssh_username

    state["install_qemu_guest_agent"] = prompt_bool(
        "Install and enable qemu-guest-agent inside the created VMs",
        bool(state.get("install_qemu_guest_agent", True)),
    )
    if state.get("os_family") == "rocky":
        state["enable_rocky_cockpit"] = prompt_bool(
            "Install and enable Cockpit web console on Rocky guests",
            bool(state.get("enable_rocky_cockpit", False)),
        )
    else:
        state["enable_rocky_cockpit"] = False
    install_operator_key_default = bool(state.get("operator_ssh_public_key", True))
    if prompt_bool(
        f"Install your local SSH public key on all created VMs for the bootstrap user '{ssh_username}'",
        install_operator_key_default,
    ):
        state["operator_ssh_public_key"] = ensure_local_ssh_public_key()
    else:
        state["operator_ssh_public_key"] = None

    has_password_default = bool(state.get("ssh_password_hash", True))
    if prompt_bool(
        f"Set an optional recovery password for the bootstrap user '{ssh_username}' (console + SSH)",
        has_password_default,
    ):
        while True:
            password_one = prompt_optional_secret(f"{ssh_username} recovery password")
            password_two = prompt_optional_secret(f"Confirm {ssh_username} recovery password")
            if not password_one:
                print("Password cannot be blank.")
                continue
            if password_one != password_two:
                print("Passwords did not match.")
                continue
            state["ssh_password_hash"] = password_hash(password_one)
            break
    else:
        state["ssh_password_hash"] = None


def prompt_topology_section(state: dict[str, object], used_vmids: set[int]) -> None:
    control_plane_count = prompt_int("Control plane count", int(state.get("control_plane_count", 1)), minimum=1)
    worker_count = prompt_int("Worker count", int(state.get("worker_count", 2)), minimum=0)
    state["control_plane_count"] = control_plane_count
    state["worker_count"] = worker_count

    use_shared_ip_range_default = bool(state.get("use_shared_ip_range", True))
    state["use_shared_ip_range"] = prompt_bool(
        "Use one IP range for control planes and workers",
        use_shared_ip_range_default,
    )

    current_cp_ips = list(state.get("cp_ips", []))
    current_wk_ips = list(state.get("wk_ips", []))
    current_kube_vip_ip = state.get("kube_vip_ip")
    kube_vip_needed = control_plane_count > 1
    recorded_cluster_ips, recorded_lb_ips = history_ipv4_usage(state)
    next_cluster_history_ip = next_recorded_ip(recorded_cluster_ips)
    next_lb_history_ip = next_recorded_ip(recorded_lb_ips)

    if state["use_shared_ip_range"]:
        if kube_vip_needed:
            kube_vip_default = str(current_kube_vip_ip or next_cluster_history_ip or "192.168.1.60")
            state["kube_vip_ip"] = parse_ip(prompt("kube-vip IP for Kubernetes API", kube_vip_default))
        else:
            state["kube_vip_ip"] = None

        required_count = control_plane_count + worker_count
        if current_cp_ips or current_wk_ips:
            existing_ips: list[str] = []
            existing_ips.extend(str(value) for value in current_cp_ips)
            existing_ips.extend(str(value) for value in current_wk_ips)
            if len(existing_ips) == required_count and is_contiguous_ips(existing_ips):
                shared_default = existing_ips[0]
            else:
                shared_default = str(ipaddress.ip_address(str(state["kube_vip_ip"])) + 1) if state.get("kube_vip_ip") else (next_cluster_history_ip or "192.168.1.60")
        else:
            shared_default = str(ipaddress.ip_address(str(state["kube_vip_ip"])) + 1) if state.get("kube_vip_ip") else (next_cluster_history_ip or "192.168.1.60")

        start_ip = parse_ip(prompt("Cluster node starting IP for control planes and workers", shared_default))
        allocated_ips = next_ips(start_ip, required_count)
        cursor = 0
        state["cp_ips"] = allocated_ips[cursor : cursor + control_plane_count]
        cursor += control_plane_count
        state["wk_ips"] = allocated_ips[cursor : cursor + worker_count]
    else:
        if kube_vip_needed:
            state["kube_vip_ip"] = parse_ip(prompt("kube-vip IP for Kubernetes API", str(current_kube_vip_ip or next_cluster_history_ip or "192.168.1.70")))
        else:
            state["kube_vip_ip"] = None

        if current_cp_ips and len(current_cp_ips) == control_plane_count:
            control_plane_default_start_ip = current_cp_ips[0]
        elif kube_vip_needed and state.get("kube_vip_ip"):
            control_plane_default_start_ip = str(ipaddress.ip_address(str(state["kube_vip_ip"])) + 1)
        else:
            control_plane_default_start_ip = next_cluster_history_ip or "192.168.1.80"

        state["cp_ips"] = prompt_ip_assignment_with_existing(
            "Control plane",
            control_plane_count,
            current_cp_ips,
            control_plane_default_start_ip,
        )

        if current_wk_ips and len(current_wk_ips) == worker_count:
            worker_default_start_ip = current_wk_ips[0]
        elif state["cp_ips"]:
            worker_default_start_ip = str(ipaddress.ip_address(state["cp_ips"][-1]) + 1)
        elif kube_vip_needed and state.get("kube_vip_ip"):
            worker_default_start_ip = str(ipaddress.ip_address(str(state["kube_vip_ip"])) + control_plane_count + 1)
        else:
            worker_default_start_ip = next_cluster_history_ip or "192.168.1.90"

        state["wk_ips"] = prompt_ip_assignment_with_existing(
            "Worker",
            worker_count,
            current_wk_ips,
            worker_default_start_ip,
        )

    current_lb_pools = list(state.get("load_balancer_ip_pools", []))
    if current_lb_pools:
        lb_default = ",".join(current_lb_pools)
    elif next_lb_history_ip:
        lb_default = suggest_range(next_lb_history_ip, 10)
    elif state["wk_ips"]:
        lb_default = suggest_range(str(ipaddress.ip_address(state["wk_ips"][-1]) + 1), 10)
    elif state["cp_ips"]:
        lb_default = suggest_range(str(ipaddress.ip_address(state["cp_ips"][-1]) + 1), 10)
    elif state.get("kube_vip_ip"):
        lb_default = suggest_range(str(ipaddress.ip_address(str(state["kube_vip_ip"])) + 1), 10)
    else:
        lb_default = "192.168.1.240-249"

    state["load_balancer_ip_pools"] = prompt_load_balancer_ip_pools(lb_default)
    state["cilium_load_balancer_pool_name"] = prompt_hostname_label(
        "Cilium LoadBalancer pool name",
        str(state.get("cilium_load_balancer_pool_name", "default")),
    )
    l2_default_name = str(state.get("cilium_l2_policy_name") or f"{state['cilium_load_balancer_pool_name']}-l2")
    if (
        l2_default_name in {"default", "default-l2"}
        or l2_default_name == f"{str(state.get('cilium_load_balancer_pool_name', 'default'))}-l2"
        or not HOSTNAME_RE.fullmatch(l2_default_name)
    ):
        l2_default_name = f"{state['cilium_load_balancer_pool_name']}-l2"
    state["cilium_l2_policy_name"] = prompt_hostname_label(
        "Cilium L2 announcement policy name",
        l2_default_name,
    )

    same_vlan_default = state.get("cp_vlan_id") == state.get("wk_vlan_id")
    state["use_shared_vlan_id"] = prompt_bool(
        "Use one VLAN ID for control planes and workers",
        bool(state.get("use_shared_vlan_id", same_vlan_default)),
    )
    if state["use_shared_vlan_id"]:
        shared_vlan = prompt_optional_int_with_choices(
            "Cluster VLAN ID (blank or none for untagged)",
            state.get("cp_vlan_id"),
        )
        state["cp_vlan_id"] = shared_vlan
        state["wk_vlan_id"] = shared_vlan
    else:
        state["cp_vlan_id"] = prompt_optional_int_with_choices(
            "Control plane VLAN ID (blank or none for untagged)",
            state.get("cp_vlan_id"),
        )
        state["wk_vlan_id"] = prompt_optional_int_with_choices(
            "Worker VLAN ID (blank or none for untagged)",
            state.get("wk_vlan_id"),
        )

    current_cp_vmids = list(state.get("cp_vmids", []))
    cp_default_vmid = next_vmid_seed(used_vmids)
    state["cp_vmids"] = prompt_vmid_assignment_with_existing("Control plane", control_plane_count, used_vmids, current_cp_vmids, cp_default_vmid)
    reserved_vmids = used_vmids | set(state["cp_vmids"])

    current_wk_vmids = list(state.get("wk_vmids", []))
    wk_default_vmid = next_vmid_seed(reserved_vmids)
    state["wk_vmids"] = prompt_vmid_assignment_with_existing("Worker", worker_count, reserved_vmids, current_wk_vmids, wk_default_vmid)


def prompt_resources_section(state: dict[str, object]) -> None:
    state["cp_cores"] = prompt_int("Control plane vCPUs", int(state.get("cp_cores", 4)), minimum=1)
    state["cp_memory_mb"] = prompt_int("Control plane memory (MB)", int(state.get("cp_memory_mb", 8192)), minimum=1024)
    state["cp_disk_gb"] = prompt_int("Control plane disk (GB)", int(state.get("cp_disk_gb", 80)), minimum=20)
    state["wk_cores"] = prompt_int("Worker vCPUs", int(state.get("wk_cores", 4)), minimum=1)
    state["wk_memory_mb"] = prompt_int("Worker memory (MB)", int(state.get("wk_memory_mb", 8192)), minimum=1024)
    state["wk_disk_gb"] = prompt_int("Worker disk (GB)", int(state.get("wk_disk_gb", 100)), minimum=20)


def prompt_charts_section(state: dict[str, object]) -> None:
    state["install_proxmox_csi"] = prompt_bool("Install Proxmox CSI", bool(state.get("install_proxmox_csi", True)))
    state["proxmox_csi_storage"] = prompt("Proxmox CSI storage target", str(state.get("proxmox_csi_storage", state["vm_datastore"])))
    state["cilium_chart_version"] = prompt_chart_version("Cilium", str(state.get("cilium_chart_version", DEFAULT_CHART_VERSIONS["cilium"])), "https://helm.cilium.io/index.yaml", "cilium")
    state["traefik_chart_version"] = prompt_chart_version("Traefik", str(state.get("traefik_chart_version", DEFAULT_CHART_VERSIONS["traefik"])), "https://traefik.github.io/charts/index.yaml", "traefik")
    state["proxmox_csi_chart_version"] = prompt_chart_version(
        "Proxmox CSI",
        str(state.get("proxmox_csi_chart_version", DEFAULT_CHART_VERSIONS["proxmox-csi-plugin"])),
        "https://helm-charts.sinextra.dev/index.yaml",
        "proxmox-csi-plugin",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Interactive cluster configuration generator")
    parser.add_argument("--output", default="terraform.tfvars.json", help="Path to write the generated tfvars JSON")
    args = parser.parse_args()

    print("Kubeadm Proxmox configurator\n")

    api_raw = prompt("Proxmox hostname, IP, or API URL", "pve.local")
    api_url = normalize_proxmox_api_url(api_raw)
    username = prompt("Proxmox username", "root@pam")
    password = prompt("Proxmox password", secret=True)
    insecure = prompt_bool("Skip Proxmox TLS verification", True)

    try:
        client = ProxmoxClient(api_url=api_url, username=username, password=password, insecure=insecure)
        client.login()
        nodes_response = client.get("/nodes")
        cluster_status = client.get("/cluster/status")
        vm_resources = client.get("/cluster/resources?type=vm")
    except (urllib.error.URLError, urllib.error.HTTPError, KeyError, TimeoutError, ValueError) as exc:
        print(f"\nUnable to talk to Proxmox: {exc}", file=sys.stderr)
        return 1

    proxmox_nodes = [entry["node"] for entry in nodes_response.get("data", [])]
    if not proxmox_nodes:
        print("No Proxmox nodes were returned by the API.", file=sys.stderr)
        return 1

    cluster_name_default = "homelab"
    for entry in cluster_status.get("data", []):
        if entry.get("type") == "cluster" and entry.get("name"):
            cluster_name_default = entry["name"]
            break

    storages_by_node: dict[str, list[dict]] = {}
    for node_name in proxmox_nodes:
        try:
            storage_data = client.get(f"/nodes/{node_name}/storage").get("data", [])
        except urllib.error.URLError:
            storage_data = []
        storages_by_node[node_name] = [entry for entry in storage_data if "storage" in entry]

    used_vmids = {
        int(entry["vmid"])
        for entry in vm_resources.get("data", [])
        if "vmid" in entry and str(entry.get("template", 0)) != "1"
    }

    print(f"Connected to Proxmox API: {api_url}")
    print(f"Available Proxmox nodes: {', '.join(proxmox_nodes)}")

    state: dict[str, object] = {"ssh_username": bootstrap_user_for_os("ubuntu")}

    prompt_cluster_identity_section(state, cluster_name_default)
    prompt_platform_section(state)
    prompt_network_storage_section(state, proxmox_nodes, storages_by_node)
    try:
        prompt_access_section(state, str(state["ssh_username"]))
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        print(f"Unable to prepare a local SSH key automatically: {exc}", file=sys.stderr)
        return 1
    prompt_topology_section(state, used_vmids)
    state["allow_subnet_mismatch"] = False
    try:
        enforce_network_consistency(state)
    except ValueError as exc:
        print(f"\n{exc}")
    prompt_resources_section(state)
    prompt_charts_section(state)

    while True:
        summarize_nodes(
            {
                **{
                    control_plane_node_name(str(state["cluster_name"]), index, int(state["control_plane_count"])): {
                        "role": "controlplane",
                        "ip": state["cp_ips"][index - 1],
                        "vm_id": state["cp_vmids"][index - 1],
                        "host_node": state["host_node"],
                    }
                    for index in range(1, int(state["control_plane_count"]) + 1)
                },
                **{
                    worker_node_name(str(state["cluster_name"]), index, int(state["worker_count"])): {
                        "role": "worker",
                        "ip": state["wk_ips"][index - 1],
                        "vm_id": state["wk_vmids"][index - 1],
                        "host_node": state["host_node"],
                    }
                    for index in range(1, int(state["worker_count"]) + 1)
                },
            },
            str(state.get("kube_vip_ip")) if int(state["control_plane_count"]) > 1 and state.get("kube_vip_ip") else None,
        )
        print("\nReview options:")
        print("  1. naming/platform")
        print("  2. network/storage")
        print("  3. access")
        print("  4. topology")
        print("  5. sizing")
        print("  6. charts/addons")
        print("  w. write config")
        choice = read_prompt("Choose a section to edit, or press w to write the config [w]: ").strip().lower()
        if not choice or choice == "w":
            if not bool(state.get("allow_subnet_mismatch", False)):
                try:
                    enforce_network_consistency(state)
                except ValueError as exc:
                    print(f"\n{exc}")
                    print("Review section 2 (network/storage) or 4 (topology), or confirm the mismatch intentionally.")
                    continue
            break
        if choice == "1":
            prompt_cluster_identity_section(state, cluster_name_default)
            prompt_platform_section(state)
        elif choice == "2":
            prompt_network_storage_section(state, proxmox_nodes, storages_by_node)
            state["allow_subnet_mismatch"] = False
            try:
                enforce_network_consistency(state)
            except ValueError as exc:
                print(f"\n{exc}")
        elif choice == "3":
            try:
                prompt_access_section(state, str(state["ssh_username"]))
            except (subprocess.CalledProcessError, FileNotFoundError) as exc:
                print(f"Unable to prepare a local SSH key automatically: {exc}", file=sys.stderr)
                return 1
        elif choice == "4":
            prompt_topology_section(state, used_vmids)
            state["allow_subnet_mismatch"] = False
            try:
                enforce_network_consistency(state)
            except ValueError as exc:
                print(f"\n{exc}")
        elif choice == "5":
            prompt_resources_section(state)
        elif choice == "6":
            prompt_charts_section(state)
        else:
            print("Choose 1-6, or w to write the config.")

    cluster_name = str(state["cluster_name"])
    dns_domain = state.get("dns_domain")
    proxmox_region = str(state["proxmox_region"])
    os_family = str(state["os_family"])
    os_version = str(state["os_version"])
    cloud_image_url = str(state["cloud_image_url"])
    cloud_image_file_name = str(state["cloud_image_file_name"])
    kubernetes_version = str(state["kubernetes_version"])
    host_node = str(state["host_node"])
    gateway = str(state["gateway"])
    prefix = int(state["prefix"])
    dns_servers = list(state["dns_servers"])
    bridge = str(state["bridge"])
    vm_datastore = str(state["vm_datastore"])
    image_datastore = str(state["image_datastore"])
    cloudinit_datastore = str(state["cloudinit_datastore"])
    snippets_datastore = str(state["snippets_datastore"])
    ssh_username = str(state["ssh_username"])
    install_qemu_guest_agent = bool(state["install_qemu_guest_agent"])
    enable_rocky_cockpit = bool(state.get("enable_rocky_cockpit", False))
    operator_ssh_public_key = state.get("operator_ssh_public_key")
    console_password_hash = state.get("ssh_password_hash")
    control_plane_count = int(state["control_plane_count"])
    worker_count = int(state["worker_count"])
    cp_ips = list(state["cp_ips"])
    wk_ips = list(state["wk_ips"])
    load_balancer_ip_pools = list(state["load_balancer_ip_pools"])
    cilium_load_balancer_pool_name = str(state.get("cilium_load_balancer_pool_name", "default"))
    cilium_l2_policy_name = str(state.get("cilium_l2_policy_name", "default"))
    cp_vmids = list(state["cp_vmids"])
    wk_vmids = list(state["wk_vmids"])
    cp_cores = int(state["cp_cores"])
    cp_memory_mb = int(state["cp_memory_mb"])
    cp_disk_gb = int(state["cp_disk_gb"])
    wk_cores = int(state["wk_cores"])
    wk_memory_mb = int(state["wk_memory_mb"])
    wk_disk_gb = int(state["wk_disk_gb"])
    install_proxmox_csi = bool(state["install_proxmox_csi"])
    proxmox_csi_storage = str(state["proxmox_csi_storage"])
    kube_vip_ip = state.get("kube_vip_ip")
    kube_vip_version = str(state.get("kube_vip_version", "v1.0.1"))
    cilium_chart_version = str(state["cilium_chart_version"])
    traefik_chart_version = str(state["traefik_chart_version"])
    proxmox_csi_chart_version = str(state["proxmox_csi_chart_version"])

    all_planned_vmids = cp_vmids + wk_vmids

    try:
        ensure_unique_vmids(all_planned_vmids)
        ensure_available_vmids(used_vmids, all_planned_vmids)
    except ValueError as exc:
        print(f"\n{exc}", file=sys.stderr)
        return 1

    nodes: dict[str, dict] = {}
    for index, (ip_addr, vmid) in enumerate(zip(cp_ips, cp_vmids), start=1):
        name = control_plane_node_name(cluster_name, index, control_plane_count)
        nodes[name] = {
            "host_node": host_node,
            "role": "controlplane",
            "vm_id": vmid,
            "ip": ip_addr,
            "dns_name": f"{name}.{dns_domain}" if dns_domain else None,
            "vlan_id": state.get("cp_vlan_id"),
            "cores": cp_cores,
            "memory_mb": cp_memory_mb,
            "disk_gb": cp_disk_gb,
        }

    for index, (ip_addr, vmid) in enumerate(zip(wk_ips, wk_vmids), start=1):
        name = worker_node_name(cluster_name, index, worker_count)
        nodes[name] = {
            "host_node": host_node,
            "role": "worker",
            "vm_id": vmid,
            "ip": ip_addr,
            "dns_name": f"{name}.{dns_domain}" if dns_domain else None,
            "vlan_id": state.get("wk_vlan_id"),
            "cores": wk_cores,
            "memory_mb": wk_memory_mb,
            "disk_gb": wk_disk_gb,
        }

    payload = {
        "proxmox_api_url": api_url,
        "proxmox_username": username,
        "proxmox_insecure": insecure,
        "cluster_name": cluster_name,
        "proxmox_region": proxmox_region,
        "os_family": os_family,
        "os_version": os_version,
        "cloud_image_url": cloud_image_url,
        "cloud_image_file_name": cloud_image_file_name,
        "kubernetes_version": kubernetes_version,
        "gateway": gateway,
        "prefix": prefix,
        "dns_servers": dns_servers,
        "dns_domain": dns_domain,
        "bridge": bridge,
        "vlan_id": None,
        "vm_datastore": vm_datastore,
        "image_datastore": image_datastore,
        "cloudinit_datastore": cloudinit_datastore,
        "snippets_datastore": snippets_datastore,
        "ssh_username": ssh_username,
        "operator_ssh_public_key": operator_ssh_public_key,
        "install_qemu_guest_agent": install_qemu_guest_agent,
        "enable_rocky_cockpit": enable_rocky_cockpit,
        "ssh_password_hash": console_password_hash,
        "pod_cidr": "10.244.0.0/16",
        "service_cidr": "10.96.0.0/12",
        "load_balancer_ip_pools": load_balancer_ip_pools,
        "cilium_load_balancer_pool_name": cilium_load_balancer_pool_name,
        "cilium_l2_policy_name": cilium_l2_policy_name,
        "kube_vip_ip": kube_vip_ip,
        "kube_vip_version": kube_vip_version,
        "cilium_chart_version": cilium_chart_version,
        "traefik_chart_version": traefik_chart_version,
        "install_proxmox_csi": install_proxmox_csi,
        "proxmox_csi_chart_version": proxmox_csi_chart_version,
        "proxmox_csi_storage": proxmox_csi_storage,
        "nodes": nodes,
    }

    os.makedirs(os.path.dirname(os.path.abspath(args.output)) or ".", exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")

    summarize_nodes(nodes, str(kube_vip_ip) if isinstance(kube_vip_ip, str) and kube_vip_ip else None)
    print(f"\nWrote {args.output}")
    if not freelens_is_installed():
        print_optional_freelens_hint()
    if not shutil_which("kubectx"):
        print_optional_kubectx_hint()
    print("Next steps:")
    print("  ./deploy.sh plan")
    print("  ./deploy.sh apply")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        raise SystemExit(130)
