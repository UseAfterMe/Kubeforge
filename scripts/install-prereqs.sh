#!/usr/bin/env bash
set -euo pipefail

LOCAL_BIN="${KUBEFORGE_LOCAL_BIN:-${HOME}/.local/bin}"
TFVARS_FILE="${TFVARS_FILE:-terraform.tfvars.json}"
PATH="${LOCAL_BIN}:${PATH}"

COLOR_RESET=""
COLOR_CYAN=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""
COLOR_DIM=""
COLOR_BOLD=""

init_colors() {
  if [[ -t 1 && "${TERM:-}" != "dumb" ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_CYAN=$'\033[36m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_RED=$'\033[31m'
    COLOR_DIM=$'\033[2m'
    COLOR_BOLD=$'\033[1m'
  fi
}

log_step() {
  printf '%s==>%s %s\n' "${COLOR_CYAN}${COLOR_BOLD}" "${COLOR_RESET}" "$*"
}

log_success() {
  printf '%s%s%s\n' "${COLOR_GREEN}${COLOR_BOLD}" "$*" "${COLOR_RESET}"
}

log_warn() {
  printf '%s%s%s\n' "${COLOR_YELLOW}${COLOR_BOLD}" "$*" "${COLOR_RESET}" >&2
}

log_error() {
  printf '%s%s%s\n' "${COLOR_RED}${COLOR_BOLD}" "$*" "${COLOR_RESET}" >&2
}

init_colors

usage() {
  local prog
  prog="${0#./}"
  cat <<EOF
Usage:
  ${prog}
  ${prog} install [--required-only|--optional-only]
  ${prog} check [--required] [--verbose]
  ${prog} optional-status
  ${prog} hint <command>
  ${prog} check-command <command>

Environment:
  KUBEFORGE_LOCAL_BIN   Directory for local binaries, default ~/.local/bin
  KUBECTL_VERSION       Optional kubectl version, for example v1.34.1
  TFVARS_FILE           terraform.tfvars JSON file used to infer kubectl version
EOF
}

platform_id() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s\n' "macos"
    return
  fi

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian)
        printf '%s\n' "apt"
        return
        ;;
      rocky|rhel|fedora|centos|almalinux)
        printf '%s\n' "dnf"
        return
        ;;
    esac
    if [[ "${ID_LIKE:-}" == *debian* ]]; then
      printf '%s\n' "apt"
      return
    fi
    if [[ "${ID_LIKE:-}" == *rhel* || "${ID_LIKE:-}" == *fedora* ]]; then
      printf '%s\n' "dnf"
      return
    fi
  fi

  printf '%s\n' "unknown"
}

platform_label() {
  case "$(platform_id)" in
    macos) printf '%s\n' "macOS" ;;
    apt) printf '%s\n' "Ubuntu/Debian" ;;
    dnf) printf '%s\n' "RHEL/Rocky/Fedora" ;;
    *) printf '%s\n' "unknown OS" ;;
  esac
}

required_tools() {
  cat <<'EOF'
tofu
ansible-playbook
ansible-inventory
python3
ssh
ssh-keygen
kubectl
jq
openssl
EOF
}

optional_tools() {
  cat <<'EOF'
cilium
ssh-copy-id
kubectx
freelens
k9s
pvecsictl
EOF
}

tool_label() {
  case "$1" in
    tofu) printf '%s\n' "OpenTofu" ;;
    ansible-playbook) printf '%s\n' "Ansible playbook runner" ;;
    ansible-inventory) printf '%s\n' "Ansible inventory CLI" ;;
    python3) printf '%s\n' "Python 3" ;;
    ssh) printf '%s\n' "OpenSSH client" ;;
    ssh-keygen) printf '%s\n' "OpenSSH key tools" ;;
    kubectl) printf '%s\n' "kubectl" ;;
    jq) printf '%s\n' "jq" ;;
    openssl) printf '%s\n' "OpenSSL" ;;
    cilium) printf '%s\n' "Cilium CLI" ;;
    ssh-copy-id) printf '%s\n' "ssh-copy-id" ;;
    kubectx) printf '%s\n' "kubectx" ;;
    freelens) printf '%s\n' "Freelens" ;;
    k9s) printf '%s\n' "k9s" ;;
    pvecsictl) printf '%s\n' "pvecsictl" ;;
    go) printf '%s\n' "Go" ;;
    curl) printf '%s\n' "curl" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

tool_description() {
  case "$1" in
    tofu) printf '%s\n' "Provisions Proxmox infrastructure with OpenTofu." ;;
    ansible-playbook|ansible-inventory) printf '%s\n' "Runs Kubernetes node preparation and bootstrap playbooks." ;;
    python3) printf '%s\n' "Runs Kubeforge configuration, validation, and kubeconfig helpers." ;;
    ssh|ssh-keygen) printf '%s\n' "Handles Proxmox snippets setup, host preflight checks, and SSH key management." ;;
    kubectl) printf '%s\n' "Manages kubeconfig and runs cluster health checks." ;;
    jq) printf '%s\n' "Reads generated configuration during kubeconfig and SSH helper flows." ;;
    openssl) printf '%s\n' "Creates optional SHA-512 recovery password hashes during configure." ;;
    cilium) printf '%s\n' "Troubleshoot and inspect Cilium networking and LoadBalancer state." ;;
    ssh-copy-id) printf '%s\n' "Install your local SSH key on the Proxmox host." ;;
    kubectx) printf '%s\n' "Switch quickly between Kubernetes contexts." ;;
    freelens) printf '%s\n' "Desktop Kubernetes UI." ;;
    k9s) printf '%s\n' "Inspect workloads, logs, and events from the terminal." ;;
    pvecsictl) printf '%s\n' "Move local Proxmox CSI volumes between Proxmox nodes." ;;
    *) printf '%s\n' "" ;;
  esac
}

tool_installed() {
  local tool="$1"
  case "${tool}" in
    freelens)
      command -v freelens >/dev/null 2>&1 ||
        command -v Freelens >/dev/null 2>&1 ||
        [[ -d "/Applications/Freelens.app" || -d "${HOME}/Applications/Freelens.app" ]]
      ;;
    *)
      command -v "${tool}" >/dev/null 2>&1
      ;;
  esac
}

prompt_yes_no() {
  local question="$1"
  local default="${2:-false}"
  local label="y/N"
  if [[ "${default}" == "true" ]]; then
    label="Y/n"
  fi

  while true; do
    local reply lowered
    printf '%s [%s]: ' "${question}" "${label}"
    read -r reply
    lowered="$(printf '%s' "${reply}" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "${lowered}" ]]; then
      [[ "${default}" == "true" ]]
      return
    fi
    case "${lowered}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
    esac
    echo "Enter y or n."
  done
}

require_interactive() {
  if [[ ! -t 0 ]]; then
    log_error "Interactive prereq installation requires a terminal."
    return 1
  fi
}

install_hint() {
  local tool="$1"
  case "$(platform_id):${tool}" in
    macos:tofu) printf '%s\n' "brew install opentofu" ;;
    macos:ansible-playbook|macos:ansible-inventory) printf '%s\n' "brew install ansible" ;;
    macos:python3) printf '%s\n' "brew install python" ;;
    macos:jq) printf '%s\n' "brew install jq" ;;
    macos:openssl) printf '%s\n' "brew install openssl@3" ;;
    macos:ssh|macos:ssh-keygen) printf '%s\n' "OpenSSH is normally bundled with macOS; install Xcode Command Line Tools if it is missing." ;;
    macos:kubectl) printf '%s\n' "Kubeforge installs kubectl locally to ${LOCAL_BIN}/kubectl." ;;
    macos:cilium) printf '%s\n' "brew install cilium-cli" ;;
    macos:ssh-copy-id) printf '%s\n' "brew install ssh-copy-id" ;;
    macos:kubectx) printf '%s\n' "brew install kubectx" ;;
    macos:k9s) printf '%s\n' "brew install k9s" ;;
    macos:freelens) printf '%s\n' "brew install --cask freelens" ;;
    macos:pvecsictl) printf '%s\n' "GOBIN=\"${LOCAL_BIN}\" go install github.com/sergelogvinov/proxmox-csi-plugin/cmd/pvecsictl@latest" ;;
    apt:tofu) printf '%s\n' "Use the official OpenTofu deb installer, then apt installs the tofu package." ;;
    apt:ansible-playbook|apt:ansible-inventory) printf '%s\n' "sudo apt-get install -y ansible" ;;
    apt:python3) printf '%s\n' "sudo apt-get install -y python3" ;;
    apt:ssh|apt:ssh-keygen|apt:ssh-copy-id) printf '%s\n' "sudo apt-get install -y openssh-client" ;;
    apt:jq) printf '%s\n' "sudo apt-get install -y jq" ;;
    apt:openssl) printf '%s\n' "sudo apt-get install -y openssl" ;;
    apt:kubectl) printf '%s\n' "Kubeforge installs kubectl locally to ${LOCAL_BIN}/kubectl." ;;
    apt:kubectx) printf '%s\n' "sudo apt-get install -y kubectx" ;;
    apt:k9s) printf '%s\n' "Install k9s from your package source or https://k9scli.io/." ;;
    apt:freelens) printf '%s\n' "Install Freelens from the official DEB, Flatpak, or Snap package." ;;
    apt:cilium) printf '%s\n' "Kubeforge can install the Cilium CLI locally to ${LOCAL_BIN}/cilium." ;;
    apt:pvecsictl) printf '%s\n' "GOBIN=\"${LOCAL_BIN}\" go install github.com/sergelogvinov/proxmox-csi-plugin/cmd/pvecsictl@latest" ;;
    dnf:tofu) printf '%s\n' "Use the official OpenTofu rpm installer, then dnf installs the tofu package." ;;
    dnf:ansible-playbook|dnf:ansible-inventory) printf '%s\n' "sudo dnf install -y ansible" ;;
    dnf:python3) printf '%s\n' "sudo dnf install -y python3" ;;
    dnf:ssh|dnf:ssh-keygen|dnf:ssh-copy-id) printf '%s\n' "sudo dnf install -y openssh-clients" ;;
    dnf:jq) printf '%s\n' "sudo dnf install -y jq" ;;
    dnf:openssl) printf '%s\n' "sudo dnf install -y openssl" ;;
    dnf:kubectl) printf '%s\n' "Kubeforge installs kubectl locally to ${LOCAL_BIN}/kubectl." ;;
    dnf:kubectx) printf '%s\n' "Install kubectx from your package source or https://github.com/ahmetb/kubectx." ;;
    dnf:k9s) printf '%s\n' "Install k9s from your package source or https://k9scli.io/." ;;
    dnf:freelens) printf '%s\n' "Install Freelens from the official RPM, Flatpak, or Snap package." ;;
    dnf:cilium) printf '%s\n' "Kubeforge can install the Cilium CLI locally to ${LOCAL_BIN}/cilium." ;;
    dnf:pvecsictl) printf '%s\n' "GOBIN=\"${LOCAL_BIN}\" go install github.com/sergelogvinov/proxmox-csi-plugin/cmd/pvecsictl@latest" ;;
    *) printf '%s\n' "Install $(tool_label "${tool}") manually for this platform." ;;
  esac
}

brew_install() {
  if ! command -v brew >/dev/null 2>&1; then
    log_error "Homebrew is required to install this tool automatically on macOS."
    return 1
  fi
  brew install "$@"
}

brew_install_cask() {
  if ! command -v brew >/dev/null 2>&1; then
    log_error "Homebrew is required to install this app automatically on macOS."
    return 1
  fi
  brew install --cask "$@"
}

apt_install() {
  sudo apt-get update
  sudo apt-get install -y "$@"
}

dnf_install() {
  sudo dnf install -y "$@"
}

fetch_url() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${dest}"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "${dest}" "${url}"
    return
  fi
  log_error "Missing curl or wget for downloading ${url}."
  return 1
}

fetch_text() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO- "${url}"
    return
  fi
  log_error "Missing curl or wget for downloading ${url}."
  return 1
}

ensure_downloader() {
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    return 0
  fi
  if ! prompt_yes_no "curl or wget is required for this install. Install curl now?" true; then
    return 1
  fi
  case "$(platform_id)" in
    macos) brew_install curl ;;
    apt) apt_install curl ;;
    dnf) dnf_install curl ;;
    *) return 1 ;;
  esac
}

install_opentofu_from_official_installer() {
  local method="$1"
  local tmpdir
  ensure_downloader
  tmpdir="$(mktemp -d)"
  fetch_url "https://get.opentofu.org/install-opentofu.sh" "${tmpdir}/install-opentofu.sh"
  chmod +x "${tmpdir}/install-opentofu.sh"
  "${tmpdir}/install-opentofu.sh" --install-method "${method}"
  rm -rf "${tmpdir}"
}

install_tofu() {
  case "$(platform_id)" in
    macos) brew_install opentofu ;;
    apt) install_opentofu_from_official_installer deb ;;
    dnf) install_opentofu_from_official_installer rpm ;;
    *) return 1 ;;
  esac
}

install_ansible() {
  case "$(platform_id)" in
    macos) brew_install ansible ;;
    apt) apt_install ansible ;;
    dnf) dnf_install ansible ;;
    *) return 1 ;;
  esac
}

install_python3() {
  case "$(platform_id)" in
    macos) brew_install python ;;
    apt) apt_install python3 ;;
    dnf) dnf_install python3 ;;
    *) return 1 ;;
  esac
}

install_openssh_client() {
  case "$(platform_id)" in
    macos)
      log_warn "OpenSSH is normally bundled with macOS. Install Xcode Command Line Tools if this is missing."
      return 1
      ;;
    apt) apt_install openssh-client ;;
    dnf) dnf_install openssh-clients ;;
    *) return 1 ;;
  esac
}

install_jq() {
  case "$(platform_id)" in
    macos) brew_install jq ;;
    apt) apt_install jq ;;
    dnf) dnf_install jq ;;
    *) return 1 ;;
  esac
}

install_openssl() {
  case "$(platform_id)" in
    macos) brew_install openssl@3 ;;
    apt) apt_install openssl ;;
    dnf) dnf_install openssl ;;
    *) return 1 ;;
  esac
}

install_ssh_copy_id() {
  case "$(platform_id)" in
    macos) brew_install ssh-copy-id ;;
    apt) apt_install openssh-client ;;
    dnf) dnf_install openssh-clients ;;
    *) return 1 ;;
  esac
}

detect_kubectl_version() {
  if [[ -n "${KUBECTL_VERSION:-}" ]]; then
    printf '%s\n' "${KUBECTL_VERSION}"
    return
  fi

  if [[ -f "${TFVARS_FILE}" ]]; then
    local version
    version="$(sed -nE 's/.*"kubernetes_version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p; s/^[[:space:]]*kubernetes_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "${TFVARS_FILE}" | head -n 1)"
    if [[ -n "${version}" ]]; then
      case "${version}" in
        v*) printf '%s\n' "${version}" ;;
        *) printf 'v%s\n' "${version}" ;;
      esac
      return
    fi
  fi

  fetch_text "https://dl.k8s.io/release/stable.txt"
}

binary_os() {
  case "$(uname -s)" in
    Darwin) printf '%s\n' "darwin" ;;
    Linux) printf '%s\n' "linux" ;;
    *) return 1 ;;
  esac
}

binary_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf '%s\n' "amd64" ;;
    arm64|aarch64) printf '%s\n' "arm64" ;;
    *) return 1 ;;
  esac
}

verify_sha256() {
  local file="$1"
  local checksum_file="$2"
  local expected
  expected="$(tr -d '[:space:]' < "${checksum_file}")"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s  %s\n' "${expected}" "${file}" | sha256sum --check >/dev/null
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    local actual
    actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
    [[ "${actual}" == "${expected}" ]]
    return
  fi
  log_warn "Could not verify checksum because sha256sum/shasum is unavailable."
}

install_local_kubectl() {
  local os arch version tmpdir url
  ensure_downloader
  os="$(binary_os)"
  arch="$(binary_arch)"
  version="$(detect_kubectl_version)"
  tmpdir="$(mktemp -d)"
  mkdir -p "${LOCAL_BIN}"

  url="https://dl.k8s.io/release/${version}/bin/${os}/${arch}/kubectl"
  log_step "Installing kubectl ${version} to ${LOCAL_BIN}/kubectl"
  fetch_url "${url}" "${tmpdir}/kubectl"
  fetch_url "${url}.sha256" "${tmpdir}/kubectl.sha256"
  verify_sha256 "${tmpdir}/kubectl" "${tmpdir}/kubectl.sha256"
  install -m 0755 "${tmpdir}/kubectl" "${LOCAL_BIN}/kubectl"
  rm -rf "${tmpdir}"
  warn_local_bin_path
}

install_local_cilium() {
  local os arch version tmpdir asset
  ensure_downloader
  os="$(binary_os)"
  arch="$(binary_arch)"
  version="$(fetch_text "https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt")"
  tmpdir="$(mktemp -d)"
  mkdir -p "${LOCAL_BIN}"

  asset="cilium-${os}-${arch}.tar.gz"
  log_step "Installing Cilium CLI ${version} to ${LOCAL_BIN}/cilium"
  fetch_url "https://github.com/cilium/cilium-cli/releases/download/${version}/${asset}" "${tmpdir}/${asset}"
  fetch_url "https://github.com/cilium/cilium-cli/releases/download/${version}/${asset}.sha256sum" "${tmpdir}/${asset}.sha256sum"
  (cd "${tmpdir}" && sha256sum --check "${asset}.sha256sum" >/dev/null 2>&1) || log_warn "Skipping Cilium checksum verification on this platform."
  tar -xzf "${tmpdir}/${asset}" -C "${tmpdir}"
  install -m 0755 "${tmpdir}/cilium" "${LOCAL_BIN}/cilium"
  rm -rf "${tmpdir}"
  warn_local_bin_path
}

install_go() {
  case "$(platform_id)" in
    macos) brew_install go ;;
    apt) apt_install golang-go ;;
    dnf) dnf_install golang ;;
    *) return 1 ;;
  esac
}

install_pvecsictl() {
  if ! command -v go >/dev/null 2>&1; then
    if ! prompt_yes_no "pvecsictl requires Go. Install Go now?" true; then
      return 1
    fi
    install_go
  fi
  mkdir -p "${LOCAL_BIN}"
  GOBIN="${LOCAL_BIN}" go install github.com/sergelogvinov/proxmox-csi-plugin/cmd/pvecsictl@latest
  warn_local_bin_path
}

install_kubectx() {
  case "$(platform_id)" in
    macos) brew_install kubectx ;;
    apt) apt_install kubectx ;;
    dnf) dnf_install kubectx ;;
    *) return 1 ;;
  esac
}

install_k9s() {
  case "$(platform_id)" in
    macos) brew_install k9s ;;
    apt) apt_install k9s ;;
    dnf) dnf_install k9s ;;
    *) return 1 ;;
  esac
}

install_freelens() {
  case "$(platform_id)" in
    macos) brew_install_cask freelens ;;
    *)
      log_warn "Automatic Freelens install is not wired for this Linux platform."
      log_warn "$(install_hint freelens)"
      return 1
      ;;
  esac
}

install_cilium() {
  case "$(platform_id)" in
    macos) brew_install cilium-cli ;;
    apt|dnf) install_local_cilium ;;
    *) return 1 ;;
  esac
}

install_tool() {
  case "$1" in
    tofu) install_tofu ;;
    ansible-playbook|ansible-inventory) install_ansible ;;
    python3) install_python3 ;;
    ssh|ssh-keygen) install_openssh_client ;;
    kubectl) install_local_kubectl ;;
    jq) install_jq ;;
    openssl) install_openssl ;;
    cilium) install_cilium ;;
    ssh-copy-id) install_ssh_copy_id ;;
    kubectx) install_kubectx ;;
    freelens) install_freelens ;;
    k9s) install_k9s ;;
    pvecsictl) install_pvecsictl ;;
    *) return 1 ;;
  esac
}

warn_local_bin_path() {
  case ":${PATH}:" in
    *":${LOCAL_BIN}:"*) ;;
    *)
      log_warn "${LOCAL_BIN} is not in PATH for this shell."
      log_warn "Add this to your shell profile: export PATH=\"${LOCAL_BIN}:\$PATH\""
      ;;
  esac
}

print_tool_status() {
  local tool="$1"
  local label desc
  label="$(tool_label "${tool}")"
  desc="$(tool_description "${tool}")"
  if tool_installed "${tool}"; then
    printf '  %s[installed]%s %s' "${COLOR_GREEN}" "${COLOR_RESET}" "${label}"
  else
    printf '  %s[missing]%s   %s' "${COLOR_YELLOW}" "${COLOR_RESET}" "${label}"
  fi
  if [[ -n "${desc}" ]]; then
    printf ' - %s' "${desc}"
  fi
  printf '\n'
}

check_required_tools() {
  local missing=()
  local tool
  while IFS= read -r tool; do
    [[ -z "${tool}" ]] && continue
    if ! tool_installed "${tool}"; then
      missing+=("${tool}")
    fi
  done < <(required_tools)

  if (( ${#missing[@]} == 0 )); then
    return 0
  fi

  log_error "Missing required Kubeforge prerequisites:"
  for tool in "${missing[@]}"; do
    printf '  - %s (%s)\n' "$(tool_label "${tool}")" "${tool}" >&2
    printf '    %s\n' "$(install_hint "${tool}")" >&2
  done
  echo >&2
  echo "Run ./deploy.sh prereqs to install missing prerequisites before deployment." >&2
  return 1
}

install_tool_if_requested() {
  local tool="$1"
  local label
  label="$(tool_label "${tool}")"

  if tool_installed "${tool}"; then
    print_tool_status "${tool}"
    if [[ "${tool}" == "kubectl" ]]; then
      if prompt_yes_no "Install or update Kubeforge-managed kubectl in ${LOCAL_BIN} anyway?" false; then
        install_tool "${tool}"
      fi
    fi
    return 0
  fi

  print_tool_status "${tool}"
  echo "    Suggested install: $(install_hint "${tool}")"
  if prompt_yes_no "Install ${label} now?" true; then
    install_tool "${tool}" || {
      log_warn "Unable to install ${label} automatically."
      return 1
    }
    if tool_installed "${tool}"; then
      log_success "Installed ${label}."
    else
      log_warn "${label} still is not visible in PATH after installation."
    fi
  fi
}

install_required_tools() {
  local tool
  log_step "Required prerequisites"
  while IFS= read -r tool; do
    [[ -z "${tool}" ]] && continue
    install_tool_if_requested "${tool}" || true
  done < <(required_tools)
}

install_optional_tools() {
  local tool
  log_step "Optional tools"
  while IFS= read -r tool; do
    [[ -z "${tool}" ]] && continue
    install_tool_if_requested "${tool}" || true
  done < <(optional_tools)
}

print_all_status() {
  local tool
  echo
  log_step "Required prerequisites"
  while IFS= read -r tool; do
    [[ -z "${tool}" ]] && continue
    print_tool_status "${tool}"
    if ! tool_installed "${tool}"; then
      printf '    %s\n' "$(install_hint "${tool}")"
    fi
  done < <(required_tools)

  print_optional_status
}

print_optional_status() {
  local tool
  echo
  log_step "Optional tools"
  while IFS= read -r tool; do
    [[ -z "${tool}" ]] && continue
    print_tool_status "${tool}"
    if ! tool_installed "${tool}"; then
      printf '    %s\n' "$(install_hint "${tool}")"
    fi
  done < <(optional_tools)
}

write_selectable_tools() {
  local output_file="$1"
  local index=1
  local tool
  : > "${output_file}"

  while IFS= read -r tool; do
    [[ -z "${tool}" ]] && continue
    printf '%s\trequired\t%s\n' "${index}" "${tool}" >> "${output_file}"
    index=$((index + 1))
  done < <(required_tools)

  while IFS= read -r tool; do
    [[ -z "${tool}" ]] && continue
    printf '%s\toptional\t%s\n' "${index}" "${tool}" >> "${output_file}"
    index=$((index + 1))
  done < <(optional_tools)
}

print_selectable_tools() {
  local menu_file="$1"
  local index group tool label desc status

  echo
  log_step "Choose prerequisites to install"
  while IFS=$'\t' read -r index group tool; do
    label="$(tool_label "${tool}")"
    desc="$(tool_description "${tool}")"
    if tool_installed "${tool}"; then
      status="${COLOR_GREEN}installed${COLOR_RESET}"
    else
      status="${COLOR_YELLOW}missing${COLOR_RESET}"
    fi
    printf '  %2s) [%s] %-8s %s' "${index}" "${status}" "${group}" "${label}"
    if [[ -n "${desc}" ]]; then
      printf ' - %s' "${desc}"
    fi
    printf '\n'
  done < "${menu_file}"
  echo
  echo "Selections:"
  echo "  numbers  Install specific tools, for example: 1 7 14"
  echo "  all      Select every listed tool"
  echo "  missing  Select missing required and optional tools"
  echo "  required Select required tools"
  echo "  optional Select optional tools"
  echo "  b        Back to main menu"
  echo "  q        Quit"
  echo
  echo "Shortcuts: b = back, q = quit"
}

number_is_selected() {
  local selected_numbers="$1"
  local number="$2"
  case " ${selected_numbers} " in
    *" ${number} "*) return 0 ;;
    *) return 1 ;;
  esac
}

install_selected_tools() {
  local menu_file selection selected_numbers token install_all install_missing install_required install_optional
  local index group tool matched selected_file label confirm
  menu_file="$(mktemp)"
  selected_file="$(mktemp)"
  write_selectable_tools "${menu_file}"
  print_selectable_tools "${menu_file}"

  printf 'Selection [b/q]: '
  read -r selection || {
    rm -f "${selected_file}"
    rm -f "${menu_file}"
    return 0
  }

  selection="$(printf '%s' "${selection}" | tr '[:upper:]' '[:lower:]')"
  case "${selection}" in
    ""|back|b)
      rm -f "${selected_file}"
      rm -f "${menu_file}"
      return 0
      ;;
    q|quit|exit)
      INTERACTIVE_MENU_EXIT=true
      rm -f "${selected_file}"
      rm -f "${menu_file}"
      return 0
      ;;
  esac

  selected_numbers=""
  install_all=false
  install_missing=false
  install_required=false
  install_optional=false
  for token in ${selection}; do
    case "${token}" in
      all) install_all=true ;;
      missing) install_missing=true ;;
      required) install_required=true ;;
      optional) install_optional=true ;;
      *[!0-9]*)
        log_warn "Ignoring unknown selection: ${token}"
        ;;
      *)
        selected_numbers="${selected_numbers} ${token}"
        ;;
    esac
  done

  matched=false
  : > "${selected_file}"
  while IFS=$'\t' read -r index group tool; do
    if [[ "${install_all}" == "true" ]] ||
      [[ "${install_required}" == "true" && "${group}" == "required" ]] ||
      [[ "${install_optional}" == "true" && "${group}" == "optional" ]] ||
      number_is_selected "${selected_numbers}" "${index}"; then
      matched=true
      printf '%s\t%s\t%s\n' "${index}" "${group}" "${tool}" >> "${selected_file}"
    elif [[ "${install_missing}" == "true" ]] && ! tool_installed "${tool}"; then
      matched=true
      printf '%s\t%s\t%s\n' "${index}" "${group}" "${tool}" >> "${selected_file}"
    fi
  done < "${menu_file}"

  if [[ "${matched}" != "true" ]]; then
    log_warn "No matching tools selected."
    rm -f "${selected_file}"
    rm -f "${menu_file}"
    return 0
  fi

  echo
  log_step "Selected tools"
  while IFS=$'\t' read -r index group tool; do
    label="$(tool_label "${tool}")"
    if tool_installed "${tool}"; then
      printf '  %2s) [installed] %-8s %s\n' "${index}" "${group}" "${label}"
    else
      printf '  %2s) [missing]   %-8s %s\n' "${index}" "${group}" "${label}"
    fi
  done < "${selected_file}"
  echo

  while true; do
    printf 'Install selected tools? [Y/n] (b = back, q = quit): '
    read -r confirm || confirm="n"
    confirm="$(printf '%s' "${confirm}" | tr '[:upper:]' '[:lower:]')"
    case "${confirm}" in
      ""|y|yes)
        while IFS=$'\t' read -r index group tool; do
          install_tool_if_requested "${tool}" || true
        done < "${selected_file}"
        break
        ;;
      n|no|b|back)
        break
        ;;
      q|quit|exit)
        INTERACTIVE_MENU_EXIT=true
        break
        ;;
      *)
        echo "Enter y, n, b, or q."
        ;;
    esac
  done

  rm -f "${selected_file}"
  rm -f "${menu_file}"
}

interactive_menu() {
  local choice
  INTERACTIVE_MENU_EXIT=false
  while true; do
    [[ "${INTERACTIVE_MENU_EXIT}" == "true" ]] && return 0
    echo
    printf '%sKubeforge prerequisite installer%s\n' "${COLOR_BOLD}" "${COLOR_RESET}"
    printf 'Platform: %s\n' "$(platform_label)"
    printf 'Local bin: %s\n' "${LOCAL_BIN}"
    echo
    echo "  1) Install required prerequisites"
    echo "  2) Install selected tools"
    echo "  3) Show status"
    echo "  4) Exit"
    echo
    printf 'Choose an option [1-4] (q = quit): '
    read -r choice || return 0
    case "${choice}" in
      1)
        install_required_tools
        ;;
      2)
        install_selected_tools
        ;;
      3)
        print_all_status
        ;;
      4|q|quit|exit)
        return 0
        ;;
      *)
        echo "Enter a number from 1 to 4, or q to quit."
        ;;
    esac
  done
}

install_flow() {
  local mode="${1:-all}"
  require_interactive
  log_step "Detected platform: $(platform_label)"
  log_step "Local binary directory: ${LOCAL_BIN}"
  case "${mode}" in
    required) install_required_tools ;;
    optional) install_optional_tools ;;
    all)
      install_required_tools
      echo
      install_optional_tools
      ;;
  esac
  echo
  if [[ "${mode}" != "optional" ]]; then
    check_required_tools
  fi
}

main() {
  local command="${1:-}"
  shift || true

  case "${command}" in
    install)
      local mode="all"
      while (( $# > 0 )); do
        case "$1" in
          --required-only) mode="required" ;;
          --optional-only) mode="optional" ;;
          *) usage; return 2 ;;
        esac
        shift
      done
      install_flow "${mode}"
      ;;
    check)
      local verbose="false"
      while (( $# > 0 )); do
        case "$1" in
          --required) ;;
          --verbose) verbose="true" ;;
          *) usage; return 2 ;;
        esac
        shift
      done
      check_required_tools
      if [[ "${verbose}" == "true" ]]; then
        log_success "All required Kubeforge prerequisites are installed."
      fi
      ;;
    optional-status)
      print_optional_status
      ;;
    hint)
      [[ $# -eq 1 ]] || { usage; return 2; }
      install_hint "$1"
      ;;
    check-command)
      [[ $# -eq 1 ]] || { usage; return 2; }
      tool_installed "$1"
      ;;
    "")
      interactive_menu
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      return 2
      ;;
  esac
}

main "$@"
