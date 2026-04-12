#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_MONITOR_PID=""
ACTIVE_CHILD_PID=""
UPGRADE_SHOULD_RUN="false"

stop_bootstrap_background_monitor() {
  if [[ -n "${BOOTSTRAP_MONITOR_PID}" ]]; then
    kill "${BOOTSTRAP_MONITOR_PID}" >/dev/null 2>&1 || true
    wait "${BOOTSTRAP_MONITOR_PID}" 2>/dev/null || true
    BOOTSTRAP_MONITOR_PID=""
  fi
}

handle_interrupt() {
  echo
  if [[ -n "${ACTIVE_CHILD_PID}" ]]; then
    kill "${ACTIVE_CHILD_PID}" >/dev/null 2>&1 || true
    wait "${ACTIVE_CHILD_PID}" 2>/dev/null || true
    ACTIVE_CHILD_PID=""
  fi
  stop_bootstrap_background_monitor
  echo "Interrupted."
  echo "No further deployment actions will be taken."
  exit 130
}

trap handle_interrupt INT TERM

ACTION="${1:-apply}"
shift || true

TFVARS_FILE="${TFVARS_FILE:-terraform.tfvars.json}"
OUT_DIR="${OUT_DIR:-out}"
DEPLOYMENT_HISTORY_DIR="${OUT_DIR}/deployment-history"
INVENTORY_PATH="${OUT_DIR}/inventory.yml"
ANSIBLE_VARS_PATH="${OUT_DIR}/ansible-vars.yml"
KUBECONFIG_PATH="${OUT_DIR}/kubeconfig"
PROXMOX_SSH_KEY_PATH="${PROXMOX_SSH_KEY_PATH:-${HOME}/.ssh/id_ed25519}"
PROXMOX_KEYCHAIN_SERVICE="${PROXMOX_KEYCHAIN_SERVICE:-proxmox-kubeadm-deployer}"
BOOTSTRAP_SSH_TIMEOUT_SECS="${BOOTSTRAP_SSH_TIMEOUT_SECS:-90}"
BOOTSTRAP_SSH_SLEEP_SECS="${BOOTSTRAP_SSH_SLEEP_SECS:-3}"
BOOTSTRAP_SSH_INITIAL_GRACE_SECS="${BOOTSTRAP_SSH_INITIAL_GRACE_SECS:-10}"
BOOTSTRAP_SSH_CONNECT_TIMEOUT_SECS="${BOOTSTRAP_SSH_CONNECT_TIMEOUT_SECS:-3}"
BOOTSTRAP_AUTO_REPLACE_UNREACHABLE="${BOOTSTRAP_AUTO_REPLACE_UNREACHABLE:-false}"
BOOTSTRAP_AUTO_REPLACE_MAX_ATTEMPTS="${BOOTSTRAP_AUTO_REPLACE_MAX_ATTEMPTS:-1}"
ANSIBLE_VERBOSITY="${ANSIBLE_VERBOSITY:-}"
SKIP_BOOTSTRAP_SSH_PREFLIGHT="${SKIP_BOOTSTRAP_SSH_PREFLIGHT:-false}"
BOOTSTRAP_BACKGROUND_MONITOR="${BOOTSTRAP_BACKGROUND_MONITOR:-true}"
BOOTSTRAP_BACKGROUND_MONITOR_INTERVAL_SECS="${BOOTSTRAP_BACKGROUND_MONITOR_INTERVAL_SECS:-20}"

PENDING_SSH_HOSTS=()

COLOR_RESET=""
COLOR_CYAN=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_DIM=""

init_colors() {
  if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_CYAN=$'\033[36m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_DIM=$'\033[2m'
  fi
}

init_colors

platform_id() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s\n' "macos"
    return
  fi

  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID_LIKE:-}" == *debian* || "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" ]]; then
      printf '%s\n' "apt"
      return
    fi
    if [[ "${ID_LIKE:-}" == *rhel* || "${ID_LIKE:-}" == *fedora* || "${ID:-}" == "rocky" || "${ID:-}" == "rhel" || "${ID:-}" == "fedora" ]]; then
      printf '%s\n' "dnf"
      return
    fi
  fi

  printf '%s\n' "unknown"
}

print_optional_tool_suggestions() {
  echo
  echo "Optional tools you might want:"
  echo

  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "- Freelens:"
    echo "  brew install --cask freelens"
  else
    echo "- Freelens:"
    echo "  https://freelensapp.github.io/"
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "- kubectx:"
    echo "  brew install kubectx"
  else
    echo "- kubectx:"
    echo "  https://github.com/ahmetb/kubectx"
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "- k9s:"
    echo "  brew install k9s"
  else
    echo "- k9s:"
    echo "  https://k9scli.io/"
  fi

  echo "- pvecsictl:"
  echo "  Used to move local Proxmox CSI volumes between Proxmox nodes."
  echo "  Prerequisite: Go"
  echo "  https://github.com/sergelogvinov/proxmox-csi-plugin"
}

prompt_yes_no() {
  local question="$1"
  local default="${2:-false}"
  local label="y/N"
  if [[ "${default}" == "true" ]]; then
    label="Y/n"
  fi

  while true; do
    local reply
    read -r -p "${question} [${label}]: " reply
    reply="${reply,,}"
    if [[ -z "${reply}" ]]; then
      [[ "${default}" == "true" ]]
      return
    fi
    case "${reply}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
    esac
    echo "Enter yes or no."
  done
}

install_hint() {
  local command_name="$1"
  local platform
  platform="$(platform_id)"

  case "${platform}:${command_name}" in
    macos:tofu)
      printf '%s\n' "Install it with: brew install opentofu"
      ;;
    macos:freelens)
      printf '%s\n' "Install it with: brew install --cask freelens"
      ;;
    macos:ansible-playbook|macos:ansible-inventory)
      printf '%s\n' "Install it with: brew install ansible"
      ;;
    macos:kubectl)
      printf '%s\n' "Install it with: brew install kubectl"
      ;;
    macos:kubectx)
      printf '%s\n' "Install it with: brew install kubectx"
      ;;
    macos:k9s)
      printf '%s\n' "Install it with: brew install k9s"
      ;;
    macos:pvecsictl)
      printf '%s\n' "Install it with Go: GOBIN=\"${HOME}/.local/bin\" go install github.com/sergelogvinov/proxmox-csi-plugin/cmd/pvecsictl@latest"
      ;;
    macos:jq)
      printf '%s\n' "Install it with: brew install jq"
      ;;
    macos:ssh-copy-id)
      printf '%s\n' "Install it with: brew install ssh-copy-id"
      ;;
    macos:python3)
      printf '%s\n' "Install it with: brew install python"
      ;;
    apt:tofu)
      printf '%s\n' "Install OpenTofu (`tofu`) using the official OpenTofu apt repository."
      ;;
    apt:freelens)
      printf '%s\n' "Optional: install Freelens using the official DEB package, or use Flatpak/Snap: https://freelensapp.github.io/"
      ;;
    apt:ansible-playbook|apt:ansible-inventory)
      printf '%s\n' "Install it with: sudo apt install -y ansible"
      ;;
    apt:kubectl)
      printf '%s\n' "Install it with: sudo apt install -y kubectl"
      ;;
    apt:kubectx)
      printf '%s\n' "Optional: install it with: sudo apt install -y kubectx"
      ;;
    apt:k9s)
      printf '%s\n' "Optional: install k9s from your preferred package source or https://k9scli.io/"
      ;;
    apt:pvecsictl)
      printf '%s\n' "Optional: install it with Go: GOBIN=\"${HOME}/.local/bin\" go install github.com/sergelogvinov/proxmox-csi-plugin/cmd/pvecsictl@latest"
      ;;
    apt:jq)
      printf '%s\n' "Install it with: sudo apt install -y jq"
      ;;
    apt:ssh-copy-id|apt:ssh|apt:ssh-keygen)
      printf '%s\n' "Install it with: sudo apt install -y openssh-client"
      ;;
    apt:python3)
      printf '%s\n' "Install it with: sudo apt install -y python3"
      ;;
    dnf:tofu)
      printf '%s\n' "Install OpenTofu (`tofu`) using the official OpenTofu dnf repository."
      ;;
    dnf:freelens)
      printf '%s\n' "Optional: install Freelens using the official RPM package, or use Flatpak/Snap: https://freelensapp.github.io/"
      ;;
    dnf:ansible-playbook|dnf:ansible-inventory)
      printf '%s\n' "Install it with: sudo dnf install -y ansible"
      ;;
    dnf:kubectl)
      printf '%s\n' "Install it with: sudo dnf install -y kubectl"
      ;;
    dnf:kubectx)
      printf '%s\n' "Optional: install kubectx from your preferred package source or https://github.com/ahmetb/kubectx"
      ;;
    dnf:k9s)
      printf '%s\n' "Optional: install k9s from your preferred package source or https://k9scli.io/"
      ;;
    dnf:pvecsictl)
      printf '%s\n' "Optional: install it with Go: GOBIN=\"${HOME}/.local/bin\" go install github.com/sergelogvinov/proxmox-csi-plugin/cmd/pvecsictl@latest"
      ;;
    dnf:jq)
      printf '%s\n' "Install it with: sudo dnf install -y jq"
      ;;
    dnf:ssh-copy-id|dnf:ssh|dnf:ssh-keygen)
      printf '%s\n' "Install it with: sudo dnf install -y openssh-clients"
      ;;
    dnf:python3)
      printf '%s\n' "Install it with: sudo dnf install -y python3"
      ;;
  esac
}

install_required_command() {
  local command_name="$1"
  local platform
  platform="$(platform_id)"

  case "${platform}:${command_name}" in
    macos:tofu)
      brew install opentofu
      ;;
    macos:ansible-playbook|macos:ansible-inventory)
      brew install ansible
      ;;
    macos:kubectl)
      brew install kubectl
      ;;
    macos:jq)
      brew install jq
      ;;
    macos:ssh-copy-id)
      brew install ssh-copy-id
      ;;
    macos:python3)
      brew install python
      ;;
    apt:ansible-playbook|apt:ansible-inventory)
      sudo apt install -y ansible
      ;;
    apt:jq)
      sudo apt install -y jq
      ;;
    apt:ssh-copy-id|apt:ssh|apt:ssh-keygen)
      sudo apt install -y openssh-client
      ;;
    apt:python3)
      sudo apt install -y python3
      ;;
    dnf:ansible-playbook|dnf:ansible-inventory)
      sudo dnf install -y ansible
      ;;
    dnf:jq)
      sudo dnf install -y jq
      ;;
    dnf:ssh-copy-id|dnf:ssh|dnf:ssh-keygen)
      sudo dnf install -y openssh-clients
      ;;
    dnf:python3)
      sudo dnf install -y python3
      ;;
    *)
      return 1
      ;;
  esac
}

prompt_install_required_command() {
  local command_name="$1"

  if [[ ! -t 0 ]]; then
    return 1
  fi

  if ! prompt_yes_no "Install missing required command '${command_name}' now?" true; then
    return 1
  fi

  if install_required_command "${command_name}"; then
    return 0
  fi

  return 1
}

need() {
  if command -v "$1" >/dev/null 2>&1; then
    return 0
  fi

  echo "Missing required command: $1" >&2
  local hint
  hint="$(install_hint "$1" || true)"

  if prompt_install_required_command "$1"; then
    if command -v "$1" >/dev/null 2>&1; then
      return 0
    fi
    echo "Tried to install '$1', but it is still unavailable in PATH." >&2
  fi

  if [[ -n "${hint}" ]]; then
    echo "${hint}" >&2
  fi
  exit 1
}

ssh_probe_options() {
  cat <<EOF
-o BatchMode=yes
-o StrictHostKeyChecking=no
-o UserKnownHostsFile=/dev/null
-o GlobalKnownHostsFile=/dev/null
-o ConnectTimeout=${BOOTSTRAP_SSH_CONNECT_TIMEOUT_SECS}
-o ConnectionAttempts=1
EOF
}

ensure_dirs() {
  mkdir -p "${OUT_DIR}/ssh" "${DEPLOYMENT_HISTORY_DIR}"
}

sanitize_workspace_name() {
  local raw="${1:-default}"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "${raw}" | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')"
  if [[ -z "${raw}" ]]; then
    raw="default"
  fi
  printf '%s\n' "${raw}"
}

ensure_tfvars() {
  if [[ ! -f "${TFVARS_FILE}" ]]; then
    echo "Missing ${TFVARS_FILE}."
    echo "Run ./deploy.sh configure first."
    exit 1
  fi
}

ensure_rendered_outputs_current() {
  local workspace snapshot_path

  if [[ ! -f "${INVENTORY_PATH}" || ! -f "${ANSIBLE_VARS_PATH}" ]]; then
    echo "Missing generated inventory or ansible vars."
    echo "Run ./deploy.sh apply first so Terraform can render them."
    exit 1
  fi

  workspace="$(current_workspace_name)"
  snapshot_path="$(workspace_last_applied_tfvars_path "${workspace}")"

  if [[ ! -f "${snapshot_path}" ]]; then
    echo "Missing last applied deployment snapshot for workspace ${workspace}."
    echo "Run ./deploy.sh apply first so Terraform can render fresh outputs."
    exit 1
  fi

  if ! cmp -s "${TFVARS_FILE}" "${snapshot_path}"; then
    echo "Current ${TFVARS_FILE} does not match the last applied deployment snapshot for workspace ${workspace}."
    echo "Run ./deploy.sh apply to refresh the rendered outputs before bootstrap."
    exit 1
  fi
}

validate_tfvars() {
  need python3
  ensure_tfvars
  python3 scripts/validate_config.py --file "${TFVARS_FILE}" --fix
}

read_tfvar() {
  python3 - "$TFVARS_FILE" "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
value = data
for part in sys.argv[2].split("."):
    value = value.get(part) if isinstance(value, dict) else None
print("" if value is None else value)
PY
}

read_tfvar_from_file() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
value = data
for part in sys.argv[2].split("."):
    value = value.get(part) if isinstance(value, dict) else None
print("" if value is None else value)
PY
}

current_workspace_name() {
  local cluster_name
  cluster_name="$(read_tfvar cluster_name)"
  sanitize_workspace_name "${cluster_name}"
}

workspace_history_dir() {
  local workspace="$1"
  printf '%s/%s\n' "${DEPLOYMENT_HISTORY_DIR}" "${workspace}"
}

workspace_history_ssh_dir() {
  local workspace="$1"
  printf '%s/ssh\n' "$(workspace_history_dir "${workspace}")"
}

workspace_last_applied_tfvars_path() {
  local workspace="$1"
  printf '%s/last-applied.tfvars.json\n' "$(workspace_history_dir "${workspace}")"
}

snapshot_workspace_ssh_key() {
  local workspace="$1"
  local ssh_history_dir

  ssh_history_dir="$(workspace_history_ssh_dir "${workspace}")"
  mkdir -p "${ssh_history_dir}"

  if [[ -f "${OUT_DIR}/ssh/id_cluster_ed25519" ]]; then
    cp "${OUT_DIR}/ssh/id_cluster_ed25519" "${ssh_history_dir}/id_cluster_ed25519"
    chmod 600 "${ssh_history_dir}/id_cluster_ed25519"
  fi

  if [[ -f "${OUT_DIR}/ssh/id_cluster_ed25519.pub" ]]; then
    cp "${OUT_DIR}/ssh/id_cluster_ed25519.pub" "${ssh_history_dir}/id_cluster_ed25519.pub"
    chmod 644 "${ssh_history_dir}/id_cluster_ed25519.pub"
  fi
}

restore_shared_cluster_ssh_key_from_history() {
  local exclude_workspace="${1:-}"
  local workspace ssh_history_dir

  while IFS= read -r workspace; do
    [[ -z "${workspace}" ]] && continue
    [[ -n "${exclude_workspace}" && "${workspace}" == "${exclude_workspace}" ]] && continue
    ssh_history_dir="$(workspace_history_ssh_dir "${workspace}")"
    if [[ -f "${ssh_history_dir}/id_cluster_ed25519" && -f "${ssh_history_dir}/id_cluster_ed25519.pub" ]]; then
      mkdir -p "${OUT_DIR}/ssh"
      cp "${ssh_history_dir}/id_cluster_ed25519" "${OUT_DIR}/ssh/id_cluster_ed25519"
      cp "${ssh_history_dir}/id_cluster_ed25519.pub" "${OUT_DIR}/ssh/id_cluster_ed25519.pub"
      chmod 600 "${OUT_DIR}/ssh/id_cluster_ed25519"
      chmod 644 "${OUT_DIR}/ssh/id_cluster_ed25519.pub"
      return 0
    fi
  done < <(list_recorded_workspaces)

  return 1
}

list_recorded_workspaces() {
  if [[ ! -d "${DEPLOYMENT_HISTORY_DIR}" ]]; then
    return 0
  fi
  local workspace_dir workspace snapshot_path
  while IFS= read -r workspace_dir; do
    [[ -z "${workspace_dir}" ]] && continue
    workspace="$(basename "${workspace_dir}")"
    snapshot_path="$(workspace_last_applied_tfvars_path "${workspace}")"
    if [[ -f "${snapshot_path}" ]] && workspace_has_state_resources "${workspace}"; then
      printf '%s\n' "${workspace}"
    fi
  done < <(find "${DEPLOYMENT_HISTORY_DIR}" -mindepth 1 -maxdepth 1 -type d | sort)
}

workspace_has_state_resources() {
  local workspace="$1"
  local original_workspace

  original_workspace="$(tofu workspace show 2>/dev/null || true)"
  if [[ -z "${original_workspace}" ]]; then
    return 1
  fi

  if ! tofu workspace select "${workspace}" >/dev/null 2>&1; then
    tofu workspace select "${original_workspace}" >/dev/null 2>&1 || true
    return 1
  fi

  if tofu state list >/dev/null 2>&1 && [[ -n "$(tofu state list 2>/dev/null || true)" ]]; then
    tofu workspace select "${original_workspace}" >/dev/null 2>&1 || true
    return 0
  fi

  tofu workspace select "${original_workspace}" >/dev/null 2>&1 || true
  return 1
}

describe_workspace() {
  local workspace="$1"
  local tfvars_path cluster_name os_family os_version
  tfvars_path="$(workspace_last_applied_tfvars_path "${workspace}")"
  if [[ -f "${tfvars_path}" ]]; then
    cluster_name="$(python3 - "${tfvars_path}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get("cluster_name", ""))
PY
)"
    os_family="$(python3 - "${tfvars_path}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get("os_family", ""))
PY
)"
    os_version="$(python3 - "${tfvars_path}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get("os_version", ""))
PY
)"
    printf '%s (%s, %s %s)\n' "${workspace}" "${cluster_name:-unknown}" "${os_family:-unknown}" "${os_version:-unknown}"
    return
  fi
  printf '%s\n' "${workspace}"
}

workspace_cluster_name() {
  local workspace="$1"
  local tfvars_path cluster_name
  tfvars_path="$(workspace_last_applied_tfvars_path "${workspace}")"
  if [[ -f "${tfvars_path}" ]]; then
    cluster_name="$(python3 - "${tfvars_path}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get("cluster_name", ""))
PY
)"
    if [[ -n "${cluster_name}" ]]; then
      printf '%s\n' "${cluster_name}"
      return
    fi
  fi
  printf '%s\n' "${workspace}"
}

proxmox_keychain_account() {
  local api_url ssh_host ssh_user
  api_url="$(read_tfvar proxmox_api_url)"
  ssh_user="$(read_tfvar proxmox_username)"
  ssh_host="$(python3 - "${api_url}" <<'PY'
import sys, urllib.parse
parsed = urllib.parse.urlparse(sys.argv[1])
print(parsed.hostname or "")
PY
)"
  printf '%s\n' "${ssh_user}@${ssh_host}"
}

can_use_keychain() {
  [[ "$(uname -s)" == "Darwin" ]] && command -v security >/dev/null 2>&1
}

load_password_from_keychain() {
  local account
  account="$(proxmox_keychain_account)"
  security find-generic-password \
    -s "${PROXMOX_KEYCHAIN_SERVICE}" \
    -a "${account}" \
    -w 2>/dev/null || true
}

save_password_to_keychain() {
  local account
  account="$(proxmox_keychain_account)"
  security add-generic-password \
    -U \
    -s "${PROXMOX_KEYCHAIN_SERVICE}" \
    -a "${account}" \
    -w "${PROXMOX_PASSWORD}" >/dev/null
}

load_proxmox_password() {
  if [[ -z "${PROXMOX_PASSWORD:-}" ]]; then
    if can_use_keychain; then
      PROXMOX_PASSWORD="$(load_password_from_keychain)"
    fi

    if [[ -z "${PROXMOX_PASSWORD:-}" ]]; then
      if [[ ! -t 0 ]]; then
        echo "Missing PROXMOX_PASSWORD and no interactive terminal is available." >&2
        exit 1
      fi

      read -r -s -p "Proxmox password: " PROXMOX_PASSWORD
      echo
      export PROXMOX_PASSWORD

      if can_use_keychain; then
        local reply
        read -r -p "Save the Proxmox password in macOS Keychain for reuse? [Y/n]: " reply
        case "${reply:-Y}" in
          y|Y|yes|YES|"")
            save_password_to_keychain
            ;;
        esac
      fi
    fi
  fi

  export PROXMOX_PASSWORD
  export TF_VAR_proxmox_password="${PROXMOX_PASSWORD}"
}

ensure_local_ssh_key() {
  need ssh-keygen
  local pubkey_path="${PROXMOX_SSH_KEY_PATH}.pub"
  if [[ ! -f "${PROXMOX_SSH_KEY_PATH}" || ! -f "${pubkey_path}" ]]; then
    mkdir -p "$(dirname "${PROXMOX_SSH_KEY_PATH}")"
    ssh-keygen -t ed25519 -f "${PROXMOX_SSH_KEY_PATH}" -N ""
  fi
}

setup_proxmox_ssh_access() {
  need python3
  need ssh-copy-id
  ensure_tfvars
  ensure_local_ssh_key

  local api_url ssh_host ssh_user
  api_url="$(read_tfvar proxmox_api_url)"
  ssh_user="$(read_tfvar proxmox_username)"
  ssh_host="$(python3 - "${api_url}" <<'PY'
import sys, urllib.parse
parsed = urllib.parse.urlparse(sys.argv[1])
print(parsed.hostname or "")
PY
)"
  ssh_user="${ssh_user%@*}"

  if [[ -z "${ssh_host}" || -z "${ssh_user}" ]]; then
    echo "Unable to determine Proxmox SSH target from ${TFVARS_FILE}." >&2
    exit 1
  fi

  echo "==> Installing ${PROXMOX_SSH_KEY_PATH}.pub on ${ssh_user}@${ssh_host}"
  ssh-copy-id -i "${PROXMOX_SSH_KEY_PATH}.pub" "${ssh_user}@${ssh_host}"
}

proxmox_ssh_host() {
  local api_url
  api_url="$(read_tfvar proxmox_api_url)"
  python3 - "${api_url}" <<'PY'
import sys, urllib.parse
parsed = urllib.parse.urlparse(sys.argv[1])
print(parsed.hostname or "")
PY
}

proxmox_ssh_user() {
  local ssh_user
  ssh_user="$(read_tfvar proxmox_username)"
  printf '%s\n' "${ssh_user%@*}"
}

ensure_local_snippets_dir() {
  need ssh
  need python3

  local snippets_datastore ssh_host ssh_user ssh_target
  snippets_datastore="$(read_tfvar snippets_datastore)"
  if [[ "${snippets_datastore}" != "local" ]]; then
    return 0
  fi

  ssh_host="$(proxmox_ssh_host)"
  ssh_user="$(proxmox_ssh_user)"
  ssh_target="${ssh_user}@${ssh_host}"

  echo "==> Ensuring Proxmox local snippets directory exists"

  if ssh -i "${PROXMOX_SSH_KEY_PATH}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    "${ssh_target}" "install -d -m 0755 /var/lib/vz/snippets" >/dev/null 2>&1; then
    return 0
  fi

  echo "Unable to create /var/lib/vz/snippets on ${ssh_target} automatically." >&2
  echo "Either run ./deploy.sh proxmox-ssh-setup first, or create it manually on the Proxmox host:" >&2
  echo "  sudo install -d -m 0755 /var/lib/vz/snippets" >&2
  exit 1
}

tf_init() {
  need tofu
  ensure_dirs
  validate_tfvars
  load_proxmox_password
  tofu init
}

select_workspace() {
  local workspace="$1"
  if tofu workspace select "${workspace}" >/dev/null 2>&1; then
    return 0
  fi
  tofu workspace new "${workspace}" >/dev/null
}

snapshot_last_applied_tfvars() {
  local workspace="${1}"
  local target_dir target_path
  ensure_dirs

  if [[ ! -f "${TFVARS_FILE}" ]]; then
    return
  fi

  target_dir="$(workspace_history_dir "${workspace}")"
  target_path="$(workspace_last_applied_tfvars_path "${workspace}")"
  mkdir -p "${target_dir}"

  cp "${TFVARS_FILE}" "${target_path}"
  cp "${TFVARS_FILE}" "${target_dir}/tfvars.$(date +%Y%m%d%H%M%S).json"
  snapshot_workspace_ssh_key "${workspace}"
}

resolve_destroy_tfvars() {
  local workspace="$1"
  local path
  path="$(workspace_last_applied_tfvars_path "${workspace}")"
  if [[ -f "${path}" ]]; then
    printf '%s\n' "${path}"
    return
  fi
  printf '%s\n' "${TFVARS_FILE}"
}

state_resource_count() {
  local state_path="$1"
  python3 - "${state_path}" <<'PY'
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    print(0)
    raise SystemExit(0)
try:
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    print(len(data.get("resources", [])))
except Exception:
    print(0)
PY
}

workspace_state_path() {
  local workspace="$1"
  if [[ "${workspace}" == "default" ]]; then
    printf '%s\n' "terraform.tfstate"
    return
  fi
  printf '%s\n' "terraform.tfstate.d/${workspace}/terraform.tfstate"
}

resolve_destroy_state_args() {
  local workspace="$1"
  local workspace_state root_state workspace_count root_count
  workspace_state="$(workspace_state_path "${workspace}")"
  root_state="terraform.tfstate"
  workspace_count="$(state_resource_count "${workspace_state}")"
  root_count="$(state_resource_count "${root_state}")"

  if (( workspace_count > 0 )); then
    return 0
  fi

  if [[ "${workspace}" != "default" ]] && (( root_count > 0 )); then
    echo "==> Workspace ${workspace} is empty, but legacy root state still has resources. Falling back to terraform.tfstate." >&2
    printf '%s\n' "-state=${root_state}"
  fi
}

choose_destroy_workspace() {
  local workspaces=()
  while IFS= read -r workspace; do
    [[ -z "${workspace}" ]] && continue
    workspaces+=("${workspace}")
  done < <(list_recorded_workspaces)

  if (( ${#workspaces[@]} == 0 )); then
    printf '%s\n' "$(current_workspace_name)"
    return
  fi

  if (( ${#workspaces[@]} == 1 )); then
    printf '%s\n' "${workspaces[0]}"
    return
  fi

  if [[ ! -t 0 ]]; then
    echo "Multiple tracked clusters exist. Set DESTROY_WORKSPACE to choose one by workspace name." >&2
    printf '%s\n' "${workspaces[0]}"
    return
  fi

  echo "Tracked clusters:" >&2
  local workspace
  local workspace_names_label=""
  for workspace in "${workspaces[@]}"; do
    echo "  - ${workspace}: $(describe_workspace "${workspace}")" >&2
    if [[ -n "${workspace_names_label}" ]]; then
      workspace_names_label="${workspace_names_label}, "
    fi
    workspace_names_label="${workspace_names_label}${workspace}"
  done

  while true; do
    local raw
    read -r -p "Enter the workspace name to destroy (${workspace_names_label}): " raw >&2
    for workspace in "${workspaces[@]}"; do
      if [[ "${raw}" == "${workspace}" ]]; then
        printf '%s\n' "${workspace}"
        return
      fi
    done
    echo "Enter one of the listed workspace names." >&2
  done
}

choose_upgrade_workspace() {
  local workspaces=()
  while IFS= read -r workspace; do
    [[ -z "${workspace}" ]] && continue
    workspaces+=("${workspace}")
  done < <(list_recorded_workspaces)

  if (( ${#workspaces[@]} == 0 )); then
    printf '%s\n' "$(current_workspace_name)"
    return
  fi

  if (( ${#workspaces[@]} == 1 )); then
    printf '%s\n' "${workspaces[0]}"
    return
  fi

  if [[ ! -t 0 ]]; then
    echo "Multiple tracked clusters exist. Set UPGRADE_WORKSPACE to choose one by workspace name." >&2
    printf '%s\n' "${workspaces[0]}"
    return
  fi

  echo "Tracked clusters:" >&2
  local workspace
  local workspace_names_label=""
  for workspace in "${workspaces[@]}"; do
    echo "  - ${workspace}: $(describe_workspace "${workspace}")" >&2
    if [[ -n "${workspace_names_label}" ]]; then
      workspace_names_label="${workspace_names_label}, "
    fi
    workspace_names_label="${workspace_names_label}${workspace}"
  done

  while true; do
    local raw
    read -r -p "Enter the workspace name to upgrade (${workspace_names_label}): " raw >&2
    for workspace in "${workspaces[@]}"; do
      if [[ "${raw}" == "${workspace}" ]]; then
        printf '%s\n' "${workspace}"
        return
      fi
    done
    echo "Enter one of the listed workspace names." >&2
  done
}

confirm_destroy_workspace() {
  local workspace="$1"

  if [[ ! -t 0 ]]; then
    return 0
  fi

  local description confirmation
  description="$(describe_workspace "${workspace}")"

  echo
  echo "You are about to destroy:"
  echo "  ${description}"
  echo
  read -r -p "Are you sure you want to destroy this cluster? [y/N]: " confirmation
  case "${confirmation:-N}" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
    echo "Destroy cancelled."
    exit 1
      ;;
  esac
}

run_configure() {
  need python3
  ensure_dirs
  python3 scripts/configure.py --output "${TFVARS_FILE}" "$@"
  validate_tfvars
}

load_workspace_snapshot_into_tfvars() {
  local workspace="$1"
  local snapshot_path
  snapshot_path="$(workspace_last_applied_tfvars_path "${workspace}")"
  if [[ ! -f "${snapshot_path}" ]]; then
    echo "Missing last applied deployment snapshot for workspace ${workspace}."
    echo "Run ./deploy.sh apply for that cluster first."
    exit 1
  fi
  cp "${snapshot_path}" "${TFVARS_FILE}"
  validate_tfvars >/dev/null
}

print_selected_image() {
  local os_family os_version image_url image_file_name
  os_family="$(read_tfvar os_family)"
  os_version="$(read_tfvar os_version)"
  image_url="$(read_tfvar cloud_image_url)"
  image_file_name="$(read_tfvar cloud_image_file_name)"

  echo "==> Selected guest OS: ${os_family} ${os_version}"
  echo "==> Cloud image file: ${image_file_name}"
  echo "==> Cloud image URL:  ${image_url}"
}

print_selected_workspace() {
  local workspace="$1"
  echo "==> Selected cluster workspace: ${workspace}"
}

probe_inventory_ssh_round() {
  local host_lines="$1"
  local ssh_user ssh_key_path
  ssh_user="$(read_tfvar ssh_username)"
  ssh_key_path="${OUT_DIR}/ssh/id_cluster_ed25519"
  local results_dir
  results_dir="$(mktemp -d)"

  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local name ip
    name="${line%% *}"
    ip="${line#* }"

    (
      if ssh $(ssh_probe_options) -i "${ssh_key_path}" "${ssh_user}@${ip}" true >/dev/null 2>&1; then
        printf 'ok %s %s\n' "${name}" "${ip}" > "${results_dir}/${name}"
      else
        printf 'pending %s %s\n' "${name}" "${ip}" > "${results_dir}/${name}"
      fi
    ) &
  done <<<"${host_lines}"

  wait
  cat "${results_dir}"/*
  rm -rf "${results_dir}"
}

wait_for_inventory_ssh() {
  need ansible-inventory
  need python3
  need ssh

  if [[ ! -f "${INVENTORY_PATH}" ]]; then
    echo "Missing ${INVENTORY_PATH}." >&2
    exit 1
  fi

  local inventory_json
  inventory_json="$(ansible-inventory -i "${INVENTORY_PATH}" --list)"

  local host_lines
  host_lines="$(python3 - "${inventory_json}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
meta = data.get("_meta", {}).get("hostvars", {})
for name, hostvars in sorted(meta.items()):
    host = hostvars.get("ansible_host")
    if host:
        print(f"{name} {host}")
PY
)"

  if [[ -z "${host_lines}" ]]; then
    echo "No hosts found in ${INVENTORY_PATH}." >&2
    exit 1
  fi

  local initial_grace_secs="${1:-$BOOTSTRAP_SSH_INITIAL_GRACE_SECS}"
  local host_summary
  host_summary="$(while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    local name ip
    name="${line%% *}"
    ip="${line#* }"
    printf '%s(%s) ' "${name}" "${ip}"
  done <<<"${host_lines}")"

  echo "==> Waiting for SSH on all inventory hosts"
  echo "==> Probing: ${host_summary}"
  if (( initial_grace_secs > 0 )); then
    echo "==> Giving new VMs ${initial_grace_secs}s to settle before probing SSH"
    sleep "${initial_grace_secs}"
  fi

  local deadline
  deadline=$((SECONDS + BOOTSTRAP_SSH_TIMEOUT_SECS))

  while true; do
    local pending=()
    local pending_hosts=()
    local probe_results
    probe_results="$(probe_inventory_ssh_round "${host_lines}")"

    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      local status name ip
      status="${line%% *}"
      line="${line#* }"
      name="${line%% *}"
      ip="${line#* }"
      if [[ "${status}" != "ok" ]]; then
        pending+=("${name}(${ip})")
        pending_hosts+=("${name}")
      fi
    done <<<"${probe_results}"

    if (( ${#pending[@]} == 0 )); then
      PENDING_SSH_HOSTS=()
      echo "==> All inventory hosts are reachable over SSH"
      return 0
    fi

    if (( SECONDS >= deadline )); then
      PENDING_SSH_HOSTS=("${pending_hosts[@]}")
      echo "Timed out waiting for SSH on: ${pending[*]}" >&2
      return 1
    fi

    local remaining
    remaining=$((deadline - SECONDS))
    echo "==> Still waiting on: ${pending[*]} (about ${remaining}s left)"
    sleep "${BOOTSTRAP_SSH_SLEEP_SECS}"
  done
}

inventory_host_lines() {
  need ansible-inventory
  need python3

  if [[ ! -f "${INVENTORY_PATH}" ]]; then
    echo "Missing ${INVENTORY_PATH}." >&2
    exit 1
  fi

  local inventory_json
  inventory_json="$(ansible-inventory -i "${INVENTORY_PATH}" --list)"

  python3 - "${inventory_json}" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
meta = data.get("_meta", {}).get("hostvars", {})
for name, hostvars in sorted(meta.items()):
    host = hostvars.get("ansible_host")
    if host:
        print(f"{name} {host}")
PY
}

bootstrap_background_monitor_loop() {
  local host_lines="$1"
  local last_status=""

  while true; do
    sleep "${BOOTSTRAP_BACKGROUND_MONITOR_INTERVAL_SECS}"

    local probe_results reachable pending
    reachable=()
    pending=()
    probe_results="$(probe_inventory_ssh_round "${host_lines}")"

    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      local status name ip
      status="${line%% *}"
      line="${line#* }"
      name="${line%% *}"
      ip="${line#* }"
      if [[ "${status}" == "ok" ]]; then
        reachable+=("${name}")
      else
        pending+=("${name}(${ip})")
      fi
    done <<<"${probe_results}"

    local current_status
    if (( ${#pending[@]} == 0 )); then
      current_status="all inventory hosts still reachable over SSH"
    else
      current_status="reachable=${#reachable[@]} pending=${#pending[@]} ${pending[*]}"
    fi

    if [[ "${current_status}" != "${last_status}" ]]; then
      echo "==> Bootstrap monitor: ${current_status}"
      last_status="${current_status}"
    fi
  done
}

start_bootstrap_background_monitor() {
  local host_lines="$1"
  if [[ "${BOOTSTRAP_BACKGROUND_MONITOR}" != "true" ]]; then
    return 0
  fi

  if [[ -z "${host_lines}" ]]; then
    return 0
  fi

  echo "==> Starting bootstrap heartbeat monitor (${BOOTSTRAP_BACKGROUND_MONITOR_INTERVAL_SECS}s interval)"
  bootstrap_background_monitor_loop "${host_lines}" &
  BOOTSTRAP_MONITOR_PID="$!"
}

cleanup_inventory_known_hosts() {
  need ansible-inventory
  need python3
  need ssh-keygen

  if [[ ! -f "${INVENTORY_PATH}" ]]; then
    echo "Missing ${INVENTORY_PATH}." >&2
    exit 1
  fi

  local inventory_json
  inventory_json="$(ansible-inventory -i "${INVENTORY_PATH}" --list)"

  python3 - "${inventory_json}" <<'PY' | while IFS= read -r target; do
import json, sys
data = json.loads(sys.argv[1])
meta = data.get("_meta", {}).get("hostvars", {})
seen = set()
for hostvars in meta.values():
    for key in ("ansible_host", "node_dns_name"):
        value = hostvars.get(key)
        if value and value not in seen:
            print(value)
            seen.add(value)
PY
    [[ -z "${target}" ]] && continue
    ssh-keygen -R "${target}" >/dev/null 2>&1 || true
  done
}

recover_unreachable_inventory_hosts() {
  need tofu
  ensure_tfvars

  if (( ${#PENDING_SSH_HOSTS[@]} == 0 )); then
    echo "No unreachable hosts were recorded for recovery." >&2
    return 1
  fi

  local replace_args=()
  local target_args=()
  local host
  for host in "${PENDING_SSH_HOSTS[@]}"; do
    replace_args+=("-replace=proxmox_virtual_environment_vm.node[\"${host}\"]")
    target_args+=("-target=proxmox_virtual_environment_vm.node[\"${host}\"]")
  done

  echo "==> Replacing unreachable hosts: ${PENDING_SSH_HOSTS[*]}"
  tofu init >/dev/null
  tofu apply -var-file="${TFVARS_FILE}" -auto-approve "${target_args[@]}" "${replace_args[@]}"
}

run_bootstrap() {
  need ansible-playbook
  need ansible-inventory
  validate_tfvars
  load_proxmox_password
  ensure_rendered_outputs_current

  cleanup_inventory_known_hosts

  local auto_replace_unreachable="${BOOTSTRAP_AUTO_REPLACE_UNREACHABLE}"
  if [[ "${ACTION}" == "bootstrap" ]]; then
    auto_replace_unreachable="false"
  fi

  if [[ "${SKIP_BOOTSTRAP_SSH_PREFLIGHT}" != "true" ]]; then
    local recovery_attempt=0
    local initial_grace_secs="${BOOTSTRAP_SSH_INITIAL_GRACE_SECS}"
    if [[ "${ACTION}" == "bootstrap" ]]; then
      initial_grace_secs=0
    fi

    while ! wait_for_inventory_ssh "${initial_grace_secs}"; do
      if [[ "${auto_replace_unreachable}" != "true" ]]; then
        if [[ "${ACTION}" == "bootstrap" ]]; then
          echo "==> Continuing bootstrap without full SSH preflight. Unreachable hosts: ${PENDING_SSH_HOSTS[*]}" >&2
          break
        fi
        return 1
      fi

      if (( recovery_attempt >= BOOTSTRAP_AUTO_REPLACE_MAX_ATTEMPTS )); then
        echo "==> Automatic node recovery limit reached." >&2
        return 1
      fi

      recovery_attempt=$((recovery_attempt + 1))
      echo "==> Attempting automatic recovery ${recovery_attempt}/${BOOTSTRAP_AUTO_REPLACE_MAX_ATTEMPTS}"
      recover_unreachable_inventory_hosts
      initial_grace_secs="${BOOTSTRAP_SSH_INITIAL_GRACE_SECS}"
    done
  else
    echo "==> Skipping SSH preflight because SKIP_BOOTSTRAP_SSH_PREFLIGHT=true"
  fi

  local -a ansible_cmd=(
    ansible-playbook
    -i "${INVENTORY_PATH}"
    ansible/site.yml
  )
  if [[ -n "${ANSIBLE_VERBOSITY}" ]]; then
    ansible_cmd+=("${ANSIBLE_VERBOSITY}")
  fi
  ansible_cmd+=(
    -e @"${ANSIBLE_VARS_PATH}"
    "$@"
  )

  if [[ "${BOOTSTRAP_BACKGROUND_MONITOR}" == "true" ]]; then
    local host_lines
    host_lines="$(inventory_host_lines)"
    start_bootstrap_background_monitor "${host_lines}"
  fi

  local ansible_rc=0
  ANSIBLE_HOST_KEY_CHECKING=False \
    PROXMOX_PASSWORD="${PROXMOX_PASSWORD}" \
    "${ansible_cmd[@]}" &
  ACTIVE_CHILD_PID="$!"
  wait "${ACTIVE_CHILD_PID}" || ansible_rc=$?
  ACTIVE_CHILD_PID=""

  stop_bootstrap_background_monitor

  return "${ansible_rc}"
}

run_upgrade() {
  need ansible-playbook
  need python3
  ensure_tfvars
  tf_init
  load_proxmox_password

  local upgrade_workspace
  upgrade_workspace="${UPGRADE_WORKSPACE:-$(choose_upgrade_workspace)}"
  select_workspace "${upgrade_workspace}"
  load_workspace_snapshot_into_tfvars "${upgrade_workspace}"
  refresh_workspace_rendered_outputs "${upgrade_workspace}"

  if [[ ! -f "${INVENTORY_PATH}" || ! -f "${ANSIBLE_VARS_PATH}" ]]; then
    echo "Missing generated inventory or ansible vars for ${upgrade_workspace}."
    echo "Run ./deploy.sh apply for that cluster first."
    exit 1
  fi

  prepare_upgrade_versions
  if [[ "${UPGRADE_SHOULD_RUN}" != "true" ]]; then
    return 0
  fi

  ANSIBLE_HOST_KEY_CHECKING=False \
    PROXMOX_PASSWORD="${PROXMOX_PASSWORD}" \
    ansible-playbook \
    -i "${INVENTORY_PATH}" \
    ansible/upgrade.yml \
    -e @"${ANSIBLE_VARS_PATH}" \
    "$@" &
  ACTIVE_CHILD_PID="$!"
  local upgrade_rc=0
  wait "${ACTIVE_CHILD_PID}" || upgrade_rc=$?
  ACTIVE_CHILD_PID=""
  if (( upgrade_rc == 0 )); then
    snapshot_last_applied_tfvars "${upgrade_workspace}"
  fi
  return "${upgrade_rc}"
}

refresh_workspace_rendered_outputs() {
  local workspace="$1"

  echo "==> Refreshing rendered outputs for workspace: ${workspace}"
  tofu apply \
    -auto-approve \
    -var-file="${TFVARS_FILE}" \
    -target=tls_private_key.cluster_ssh \
    -target=local_sensitive_file.cluster_ssh_private_key \
    -target=local_file.cluster_ssh_public_key \
    -target=local_file.ansible_inventory \
    -target=local_sensitive_file.ansible_vars >/dev/null
}

discover_upgrade_candidates() {
  python3 - "${TFVARS_FILE}" <<'PY'
import importlib.util
import json
import re
import sys
from pathlib import Path

tfvars_path = Path(sys.argv[1])
if not tfvars_path.exists():
    raise SystemExit(0)

spec = importlib.util.spec_from_file_location("configure_module", Path("scripts/configure.py"))
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
sys.modules[spec.name] = module
spec.loader.exec_module(module)

with tfvars_path.open("r", encoding="utf-8") as handle:
    data = json.load(handle)


def version_key(value: str) -> tuple:
    match = re.search(r"(\d+)\.(\d+)\.(\d+)", value or "")
    if not match:
        return (-1, -1, -1)
    return tuple(int(part) for part in match.groups())


def latest_chart(index_url: str, chart_name: str, fallback: str) -> str:
    versions = module.fetch_chart_versions(index_url, chart_name)
    if versions:
        return versions[0]
    return fallback


candidates = []

current_kubernetes = str(data.get("kubernetes_version", "")).strip()
try:
    kubernetes_versions = module.discover_kubernetes_versions()
except Exception:
    kubernetes_versions = []
if kubernetes_versions:
    latest_kubernetes = kubernetes_versions[0]
    if version_key(latest_kubernetes) > version_key(current_kubernetes):
        candidates.append(("kubernetes_version", "Kubernetes", current_kubernetes, latest_kubernetes))

chart_checks = [
    ("cilium_chart_version", "Cilium chart", "https://helm.cilium.io/index.yaml", "cilium", module.DEFAULT_CHART_VERSIONS["cilium"]),
    ("metallb_chart_version", "MetalLB chart", "https://metallb.github.io/metallb/index.yaml", "metallb", module.DEFAULT_CHART_VERSIONS["metallb"]),
    ("traefik_chart_version", "Traefik chart", "https://traefik.github.io/charts/index.yaml", "traefik", module.DEFAULT_CHART_VERSIONS["traefik"]),
]

if bool(data.get("install_proxmox_csi", False)):
    chart_checks.append(
        (
            "proxmox_csi_chart_version",
            "Proxmox CSI chart",
            "https://sergelogvinov.github.io/proxmox-csi-plugin/index.yaml",
            "proxmox-csi-plugin",
            module.DEFAULT_CHART_VERSIONS["proxmox-csi-plugin"],
        )
    )

for key, label, index_url, chart_name, fallback in chart_checks:
    current = str(data.get(key, fallback)).strip()
    try:
        latest = latest_chart(index_url, chart_name, fallback)
    except Exception:
        latest = fallback
    if version_key(latest) > version_key(current):
        candidates.append((key, label, current, latest))

for key, label, current, latest in candidates:
    print(f"{key}\t{label}\t{current}\t{latest}")
PY
}

apply_upgrade_version_selections() {
  local selections_file="$1"
  python3 - "${TFVARS_FILE}" "${ANSIBLE_VARS_PATH}" "${selections_file}" <<'PY'
import json
import re
import sys
from pathlib import Path

tfvars_path = Path(sys.argv[1])
ansible_vars_path = Path(sys.argv[2])
selections_path = Path(sys.argv[3])

with tfvars_path.open("r", encoding="utf-8") as handle:
    data = json.load(handle)

replacements: dict[str, str] = {}
for raw_line in selections_path.read_text(encoding="utf-8").splitlines():
    line = raw_line.strip()
    if not line:
        continue
    key, value = line.split("\t", 1)
    data[key] = value
    replacements[key] = value

tfvars_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

if "kubernetes_version" in replacements:
    kubernetes_version = replacements["kubernetes_version"]
    parts = kubernetes_version.split(".")
    replacements["kube_version_minor"] = ".".join(parts[:2])
    replacements["kube_package_version"] = f"{kubernetes_version}-1.1"

lines = ansible_vars_path.read_text(encoding="utf-8").splitlines()
updated_lines = []
for line in lines:
    replaced = False
    for key, value in replacements.items():
        if re.match(rf"^{re.escape(key)}:\s*", line):
            updated_lines.append(f"{key}: {value}")
            replaced = True
            break
    if not replaced:
        updated_lines.append(line)

ansible_vars_path.write_text("\n".join(updated_lines) + "\n", encoding="utf-8")
PY
}

prepare_upgrade_versions() {
  local candidates
  candidates="$(discover_upgrade_candidates)"
  UPGRADE_SHOULD_RUN="false"

  if [[ -z "${candidates}" ]]; then
    echo "No newer Kubernetes or addon versions were discovered."
    echo "Nothing will be upgraded."
    return 0
  fi

  echo "Upgrade check found newer versions:"
  echo

  local selections_file
  selections_file="$(mktemp)"

  local selected_any="false"
  while IFS=$'\t' read -r key label current latest; do
    [[ -z "${key}" ]] && continue
    echo "  ${label}: ${current} -> ${latest}"
    if prompt_yes_no "Upgrade ${label} to ${latest}?" true; then
      printf '%s\t%s\n' "${key}" "${latest}" >> "${selections_file}"
      selected_any="true"
    fi
  done <<< "${candidates}"

  if [[ "${selected_any}" == "true" ]]; then
    apply_upgrade_version_selections "${selections_file}"
    UPGRADE_SHOULD_RUN="true"
    echo
    echo "Updated ${TFVARS_FILE} and ${ANSIBLE_VARS_PATH} with the selected upgrade target versions."
  else
    echo
    echo "No upgrade targets were selected."
    echo "Nothing will be upgraded."
  fi

  rm -f "${selections_file}"
}

print_exports() {
  local workspace
  workspace="$(current_workspace_name)"
  select_workspace "${workspace}" >/dev/null
  local api_endpoint
  api_endpoint="$(tofu output -raw kubernetes_api_endpoint)"

  echo
  echo "Bootstrap complete."
  echo "cluster:    ${workspace}"
  echo
  echo "kubeconfig: ${KUBECONFIG_PATH}"
  echo "installed:  ${HOME}/.kube/config"
  echo "api:        ${api_endpoint}"
  echo
  echo "Use it for this shell:"
  echo "  export KUBECONFIG=${KUBECONFIG_PATH}"
  echo
  echo "Then verify the cluster:"
  echo "  kubectl get nodes -o wide"
  print_optional_tool_suggestions
}

out_ansible_vars_matches_workspace() {
  local workspace="$1"
  local target_cluster
  target_cluster="$(workspace_cluster_name "${workspace}")"

  if [[ ! -f "${ANSIBLE_VARS_PATH}" ]]; then
    return 1
  fi

  python3 - "${ANSIBLE_VARS_PATH}" "${target_cluster}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
target = sys.argv[2]

for line in path.read_text(encoding="utf-8").splitlines():
    if line.startswith("cluster_name:"):
        value = line.split(":", 1)[1].strip()
        raise SystemExit(0 if value == target else 1)

raise SystemExit(1)
PY
}

out_inventory_matches_workspace() {
  local workspace="$1"
  local target_cluster
  target_cluster="$(workspace_cluster_name "${workspace}")"

  if [[ ! -f "${INVENTORY_PATH}" ]]; then
    return 1
  fi

  grep -q "${target_cluster}-" "${INVENTORY_PATH}" 2>/dev/null
}

out_kubeconfig_matches_workspace() {
  local workspace="$1"
  local target_cluster
  target_cluster="$(workspace_cluster_name "${workspace}")"

  if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
    return 1
  fi

  if command -v kubectl >/dev/null 2>&1; then
    python3 - "${KUBECONFIG_PATH}" "${target_cluster}" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

path = Path(sys.argv[1])
target = sys.argv[2]

try:
    raw = subprocess.run(
        ["kubectl", "--kubeconfig", str(path), "config", "view", "--raw", "-o", "json"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    data = json.loads(raw)
except Exception:
    text = path.read_text(encoding="utf-8")
    raise SystemExit(0 if f"@{target}" in text or f"name: {target}" in text else 1)

clusters = data.get("clusters") or []
contexts = data.get("contexts") or []

for entry in clusters:
    if isinstance(entry, dict) and entry.get("name") == target:
        raise SystemExit(0)
for entry in contexts:
    if not isinstance(entry, dict):
        continue
    if entry.get("name", "").endswith(f"@{target}"):
        raise SystemExit(0)

raise SystemExit(1)
PY
  else
    grep -q "@${target_cluster}\\|name: ${target_cluster}" "${KUBECONFIG_PATH}" 2>/dev/null
  fi
}

cleanup_local_artifacts_for_workspace() {
  local workspace="$1"
  local matches_ansible_vars="false"
  local matches_inventory="false"
  local matches_kubeconfig="false"

  if out_ansible_vars_matches_workspace "${workspace}"; then
    matches_ansible_vars="true"
  fi

  if out_inventory_matches_workspace "${workspace}"; then
    matches_inventory="true"
  fi

  if out_kubeconfig_matches_workspace "${workspace}"; then
    matches_kubeconfig="true"
  fi

  if [[ "${matches_ansible_vars}" == "true" ]]; then
    rm -f "${ANSIBLE_VARS_PATH}"
  fi

  if [[ "${matches_inventory}" == "true" ]]; then
    rm -f "${INVENTORY_PATH}"
  fi

  if [[ "${matches_kubeconfig}" == "true" ]]; then
    rm -f "${KUBECONFIG_PATH}"
  fi
}

cleanup_destroyed_workspace_metadata() {
  local workspace="$1"
  local original_workspace history_dir

  rm -f "$(workspace_last_applied_tfvars_path "${workspace}")"
  history_dir="$(workspace_history_dir "${workspace}")"
  if [[ -d "${history_dir}" ]]; then
    rm -rf "${history_dir}"
  fi

  if [[ "${workspace}" == "default" ]]; then
    return 0
  fi

  original_workspace="$(tofu workspace show 2>/dev/null || true)"
  if [[ -n "${original_workspace}" && "${original_workspace}" == "${workspace}" ]]; then
    tofu workspace select default >/dev/null 2>&1 || true
  fi

  tofu workspace delete -force "${workspace}" >/dev/null 2>&1 || true
}

normalize_kubeconfig_for_merge() {
  local source_path="$1"
  local target_path="$2"
  local source_json_path

  source_json_path="$(mktemp)"
  kubectl --kubeconfig="${source_path}" config view --raw -o json > "${source_json_path}"

  python3 - "${source_json_path}" "${target_path}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
contexts = data.get("contexts", [])
users = data.get("users", [])

users_by_name = {
    entry.get("name"): entry.get("user", {})
    for entry in users
    if entry.get("name")
}

new_users = []
seen_users = set()

for context_entry in contexts:
    context = context_entry.get("context", {})
    cluster_name = context.get("cluster")
    user_name = context.get("user")

    if not cluster_name or not user_name:
      continue

    if user_name.endswith(f"@{cluster_name}"):
      desired_user_name = user_name
    else:
      desired_user_name = f"{user_name.split('@', 1)[0]}@{cluster_name}"

    context["user"] = desired_user_name

    if desired_user_name in seen_users:
      continue

    user_payload = users_by_name.get(user_name)
    if user_payload is None and "@" in user_name:
      user_payload = users_by_name.get(user_name.split("@", 1)[0])
    if user_payload is None:
      continue

    new_users.append({"name": desired_user_name, "user": user_payload})
    seen_users.add(desired_user_name)

if new_users:
    data["users"] = new_users

with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

  rm -f "${source_json_path}"
}

merge_kubeconfig_files() {
  local existing_path="$1"
  local incoming_path="$2"
  local target_path="$3"
  local existing_json_path

  existing_json_path="$(mktemp)"
  kubectl --kubeconfig="${existing_path}" config view --raw -o json > "${existing_json_path}"

  python3 - "${existing_json_path}" "${incoming_path}" "${target_path}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    existing = json.load(fh)

with open(sys.argv[2], encoding="utf-8") as fh:
    incoming = json.load(fh)

def merge_named(existing_items, incoming_items):
    existing_items = existing_items or []
    incoming_items = incoming_items or []
    merged = {item["name"]: item for item in existing_items if isinstance(item, dict) and item.get("name")}
    for item in incoming_items:
        if not isinstance(item, dict):
            continue
        name = item.get("name")
        if not name:
            continue
        merged[name] = item
    return list(merged.values())

merged = dict(existing)
merged["clusters"] = merge_named(existing.get("clusters", []), incoming.get("clusters", []))
merged["users"] = merge_named(existing.get("users", []), incoming.get("users", []))
merged["contexts"] = merge_named(existing.get("contexts", []), incoming.get("contexts", []))

if incoming.get("current-context"):
    merged["current-context"] = incoming["current-context"]

with open(sys.argv[3], "w", encoding="utf-8") as fh:
    json.dump(merged, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

  rm -f "${existing_json_path}"
}

prune_cluster_from_kubeconfig() {
  local workspace="$1"
  local target_path cluster_name context_name legacy_user_name cluster_user_name

  target_path="${HOME}/.kube/config"
  if [[ ! -f "${target_path}" ]]; then
    return 0
  fi

  cluster_name="$(workspace_cluster_name "${workspace}")"
  context_name="kubernetes-admin@${cluster_name}"
  legacy_user_name="kubernetes-admin"
  cluster_user_name="kubernetes-admin@${cluster_name}"

  if ! python3 - "${target_path}" "${cluster_name}" "${context_name}" "${legacy_user_name}" "${cluster_user_name}" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

path = Path(sys.argv[1])
cluster_name = sys.argv[2]
context_name = sys.argv[3]
legacy_user_name = sys.argv[4]
cluster_user_name = sys.argv[5]

raw = subprocess.run(
    ["kubectl", "--kubeconfig", str(path), "config", "view", "--raw", "-o", "json"],
    check=True,
    capture_output=True,
    text=True,
).stdout
data = json.loads(raw)

contexts = data.get("contexts", [])
clusters = data.get("clusters", [])
users = data.get("users", [])
current_context = data.get("current-context", "")

contexts_to_keep = []
removed_contexts = set()
users_in_use = set()

for entry in contexts:
    name = entry.get("name")
    context = entry.get("context", {})
    if name == context_name or context.get("cluster") == cluster_name:
        removed_contexts.add(name)
        continue
    contexts_to_keep.append(entry)
    user_name = context.get("user")
    if user_name:
        users_in_use.add(user_name)

clusters_to_keep = [entry for entry in clusters if entry.get("name") != cluster_name]

users_to_keep = []
for entry in users:
    name = entry.get("name")
    if name == cluster_user_name and name not in users_in_use:
        continue
    if name == legacy_user_name and name not in users_in_use:
        continue
    users_to_keep.append(entry)

data["contexts"] = contexts_to_keep
data["clusters"] = clusters_to_keep
data["users"] = users_to_keep

if current_context in removed_contexts:
    data["current-context"] = contexts_to_keep[0]["name"] if contexts_to_keep else ""

path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  then
    echo "Warning: unable to prune ${cluster_name} from ${target_path}. Review the kubeconfig manually." >&2
    return 0
  fi
}

install_kubeconfig() {
  local target_dir target_path backup_path merge_tmp merged_config_tmp normalized_source_path
  target_dir="${HOME}/.kube"
  target_path="${target_dir}/config"

  if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
    echo "Missing ${KUBECONFIG_PATH}."
    echo "Run ./deploy.sh bootstrap first."
    exit 1
  fi

  mkdir -p "${target_dir}"

  merge_tmp="$(mktemp -d)"
  normalized_source_path="${merge_tmp}/incoming-kubeconfig.json"

  if command -v kubectl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    normalize_kubeconfig_for_merge "${KUBECONFIG_PATH}" "${normalized_source_path}"
  else
    cp "${KUBECONFIG_PATH}" "${normalized_source_path}"
  fi

  if [[ -f "${target_path}" ]]; then
    backup_path="${target_path}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${target_path}" "${backup_path}"
    echo "Backed up existing kubeconfig to ${backup_path}"

    if command -v kubectl >/dev/null 2>&1; then
      merged_config_tmp="${merge_tmp}/config"
      merge_kubeconfig_files "${backup_path}" "${normalized_source_path}" "${merged_config_tmp}"
      cp "${merged_config_tmp}" "${target_path}"
      echo "Merged kubeconfig into ${target_path}"
    else
      cp "${normalized_source_path}" "${target_path}"
      echo "Installed kubeconfig to ${target_path}"
      echo "kubectl is not installed, so the kubeconfig could not be merged automatically."
    fi
  else
    cp "${normalized_source_path}" "${target_path}"
    echo "Installed kubeconfig to ${target_path}"
  fi

  rm -rf "${merge_tmp}"
  chmod 600 "${target_path}"
  echo "No shell profile update is needed when using ~/.kube/config."
}

refresh_kubeconfig_after_apply() {
  if [[ -f "${KUBECONFIG_PATH}" ]]; then
    echo
    echo "Refreshing local kubeconfig from ${KUBECONFIG_PATH}..."
    install_kubeconfig
  else
    echo
    echo "Kubeconfig will be installed after a successful bootstrap."
  fi
}

refresh_kubeconfig_after_bootstrap_if_available() {
  if [[ -f "${KUBECONFIG_PATH}" ]]; then
    echo
    echo "Refreshing local kubeconfig from ${KUBECONFIG_PATH}..."
    install_kubeconfig
  fi
}

apply_current_workspace() {
  ensure_tfvars
  tf_init
  local workspace
  workspace="$(current_workspace_name)"
  select_workspace "${workspace}"
  ensure_local_snippets_dir
  print_selected_workspace "${workspace}"
  print_selected_image
  tofu apply -var-file="${TFVARS_FILE}" -auto-approve
  snapshot_last_applied_tfvars "${workspace}"
  refresh_kubeconfig_after_apply
}

fetch_kubeconfig_from_first_control_plane() {
  local ssh_user ssh_host ssh_key ssh_args tmp_file

  if [[ ! -f "${TFVARS_FILE}" || ! -f "${OUT_DIR}/ssh/id_cluster_ed25519" ]]; then
    return 1
  fi

  ssh_user="$(jq -r '.ssh_username // empty' "${TFVARS_FILE}" 2>/dev/null || true)"
  ssh_host="$(jq -r '
    (.nodes // {})
    | to_entries
    | map(select(.value.role == "controlplane"))
    | sort_by(.key)
    | .[0].value.ip // empty
  ' "${TFVARS_FILE}" 2>/dev/null || true)"

  if [[ -z "${ssh_user}" || -z "${ssh_host}" ]]; then
    return 1
  fi

  ssh_key="${OUT_DIR}/ssh/id_cluster_ed25519"
  ssh_args=(
    -i "${ssh_key}"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o GlobalKnownHostsFile=/dev/null
    -o BatchMode=yes
    -o ConnectTimeout=5
  )

  if ! ssh "${ssh_args[@]}" "${ssh_user}@${ssh_host}" "sudo test -r /etc/kubernetes/admin.conf" >/dev/null 2>&1; then
    return 1
  fi

  tmp_file="$(mktemp "${OUT_DIR}/kubeconfig.apply.XXXXXX")"
  if ssh "${ssh_args[@]}" "${ssh_user}@${ssh_host}" "sudo cat /etc/kubernetes/admin.conf" >"${tmp_file}"; then
    mv "${tmp_file}" "${KUBECONFIG_PATH}"
    chmod 600 "${KUBECONFIG_PATH}"
    return 0
  fi

  rm -f "${tmp_file}"
  return 1
}

resolve_context_for_cluster() {
  local cluster_name="$1"
  local preferred_context="kubernetes-admin@${cluster_name}"

  if ! command -v kubectl >/dev/null 2>&1; then
    return 1
  fi

  if kubectl config get-contexts -o name 2>/dev/null | grep -Fxq "${preferred_context}"; then
    printf '%s\n' "${preferred_context}"
    return 0
  fi

  local fallback_context
  fallback_context="$(kubectl config get-contexts -o name 2>/dev/null | grep -F "@${cluster_name}" | head -n 1 || true)"
  if [[ -n "${fallback_context}" ]]; then
    printf '%s\n' "${fallback_context}"
    return 0
  fi

  return 1
}

health_checks() {
  need kubectl

  if [[ -f "${HOME}/.kube/config" ]]; then
    export KUBECONFIG="${HOME}/.kube/config"
  elif [[ -f "${KUBECONFIG_PATH}" ]]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
  else
    echo "Missing kubeconfig."
    echo "Run ./deploy.sh bootstrap first."
    exit 1
  fi

  echo "==> Using KUBECONFIG=${KUBECONFIG}"
  echo

  echo "==> kubectl get nodes -o wide"
  kubectl get nodes -o wide
  echo
  echo "==> kubectl wait --for=condition=Ready nodes --all --timeout=60s"
  kubectl wait --for=condition=Ready nodes --all --timeout=60s
  echo
  echo "==> kubectl get pods -A"
  kubectl get pods -A
  echo
  echo "==> kubectl wait -n kube-system --for=condition=Available deployment/coredns --timeout=120s"
  kubectl wait -n kube-system --for=condition=Available deployment/coredns --timeout=120s
  echo
  echo "==> kubectl wait -n metallb-system --for=condition=Available deployment/metallb-controller --timeout=120s"
  kubectl wait -n metallb-system --for=condition=Available deployment/metallb-controller --timeout=120s
  echo
  echo "==> kubectl wait -n traefik --for=condition=Available deployment/traefik --timeout=120s"
  kubectl wait -n traefik --for=condition=Available deployment/traefik --timeout=120s

  echo
  echo "==> kubectl get pods -A -o wide"
  kubectl get pods -A -o wide
  echo
  echo "==> kubectl cluster-info"
  kubectl cluster-info
  echo
  echo "Health checks passed."
}

case "${ACTION}" in
  configure)
    run_configure "$@"
    ;;
  plan)
    ensure_tfvars
    tf_init
    workspace="$(current_workspace_name)"
    select_workspace "${workspace}"
    ensure_local_snippets_dir
    print_selected_workspace "${workspace}"
    print_selected_image
    tofu plan -var-file="${TFVARS_FILE}" "$@"
    ;;
  apply)
    ensure_tfvars
    tf_init
    workspace="$(current_workspace_name)"
    select_workspace "${workspace}"
    ensure_local_snippets_dir
    print_selected_workspace "${workspace}"
    print_selected_image
    tofu apply -var-file="${TFVARS_FILE}" -auto-approve "$@"
    snapshot_last_applied_tfvars "${workspace}"
    refresh_kubeconfig_after_apply
    echo
    echo "Infrastructure apply complete."
    echo "Next steps:"
    echo "  ./deploy.sh bootstrap"
    echo "  ./deploy.sh output"
    ;;
  bootstrap)
    bootstrap_rc=0
    run_bootstrap "$@" || bootstrap_rc=$?
    refresh_kubeconfig_after_bootstrap_if_available
    if (( bootstrap_rc != 0 )); then
      exit "${bootstrap_rc}"
    fi
    print_exports
    ;;
  upgrade)
    run_upgrade "$@"
    ;;
  destroy)
    ensure_dirs
    ensure_tfvars
    tf_init
    destroy_workspace="${DESTROY_WORKSPACE:-$(choose_destroy_workspace)}"
    confirm_destroy_workspace "${destroy_workspace}"
    select_workspace "${destroy_workspace}"
    local_destroy_tfvars="$(resolve_destroy_tfvars "${destroy_workspace}")"
    destroy_state_arg="$(resolve_destroy_state_args "${destroy_workspace}")"
    if [[ ! -f "${local_destroy_tfvars}" ]]; then
      echo "Missing ${local_destroy_tfvars}."
      echo "Run ./deploy.sh apply first or restore the last applied tfvars snapshot for ${destroy_workspace}."
      exit 1
    fi
    echo "==> Destroying cluster workspace: ${destroy_workspace}"
    echo "==> Destroying using deployment snapshot: ${local_destroy_tfvars}"
    if [[ -n "${destroy_state_arg}" ]]; then
      tofu destroy -refresh=false "${destroy_state_arg}" -var-file="${local_destroy_tfvars}" -auto-approve "$@"
    else
      tofu destroy -refresh=false -var-file="${local_destroy_tfvars}" -auto-approve "$@"
    fi
    restore_shared_cluster_ssh_key_from_history "${destroy_workspace}" || true
    prune_cluster_from_kubeconfig "${destroy_workspace}"
    cleanup_local_artifacts_for_workspace "${destroy_workspace}"
    cleanup_destroyed_workspace_metadata "${destroy_workspace}"
    ;;
  output)
    tf_init
    workspace="$(current_workspace_name)"
    select_workspace "${workspace}"
    tofu output
    ;;
  install-kubeconfig)
    install_kubeconfig
    ;;
  proxmox-ssh-setup)
    setup_proxmox_ssh_access
    ;;
  health)
    health_checks
    ;;
  *)
    echo "Usage: ./deploy.sh [configure|plan|apply|bootstrap|upgrade|destroy|output|install-kubeconfig|proxmox-ssh-setup|health]" >&2
    exit 1
    ;;
esac
