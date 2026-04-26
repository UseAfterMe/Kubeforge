#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$(printf '4\n' | "${repo_root}/scripts/install-prereqs.sh" 2>&1)"

if ! printf '%s\n' "${output}" | grep -q "Kubeforge prerequisite installer"; then
  echo "expected no-arg install-prereqs to show the interactive menu" >&2
  printf '%s\n' "${output}" >&2
  exit 1
fi

if ! printf '%s\n' "${output}" | grep -q "Install optional tools"; then
  echo "expected menu to include optional-tool installation" >&2
  printf '%s\n' "${output}" >&2
  exit 1
fi

if printf '%s\n' "${output}" | grep -q "Install selected tools"; then
  echo "did not expect main menu to include selected-tool wording" >&2
  printf '%s\n' "${output}" >&2
  exit 1
fi

if printf '%s\n' "${output}" | grep -q "^Usage:"; then
  echo "did not expect no-arg install-prereqs to print usage" >&2
  printf '%s\n' "${output}" >&2
  exit 1
fi

selected_output="$(printf '2\nb\n4\n' | "${repo_root}/scripts/install-prereqs.sh" 2>&1)"

if ! printf '%s\n' "${selected_output}" | grep -q "b = back"; then
  echo "expected selected-tool menu to show b/back help" >&2
  printf '%s\n' "${selected_output}" >&2
  exit 1
fi

if ! printf '%s\n' "${selected_output}" | grep -q "q = quit"; then
  echo "expected selected-tool menu to show q/quit help" >&2
  printf '%s\n' "${selected_output}" >&2
  exit 1
fi

if ! printf '%s\n' "${selected_output}" | grep -q "Select optional tools (numbers/all/missing, b=back, q=quit):"; then
  echo "expected optional-tool prompt to be explicit" >&2
  printf '%s\n' "${selected_output}" >&2
  exit 1
fi

if printf '%s\n' "${selected_output}" | grep -q "Selection \\[b/q\\]"; then
  echo "did not expect confusing Selection [b/q] prompt" >&2
  printf '%s\n' "${selected_output}" >&2
  exit 1
fi

if printf '%s\n' "${selected_output}" | grep -q "required OpenTofu"; then
  echo "did not expect optional-tool menu to list required prerequisites" >&2
  printf '%s\n' "${selected_output}" >&2
  exit 1
fi

if ! printf '%s\n' "${selected_output}" | grep -q "optional Cilium CLI"; then
  echo "expected optional-tool menu to list optional tools" >&2
  printf '%s\n' "${selected_output}" >&2
  exit 1
fi

confirm_output="$(printf '2\n1\nn\n4\n' | "${repo_root}/scripts/install-prereqs.sh" 2>&1)"

if ! printf '%s\n' "${confirm_output}" | grep -q "Install selected optional tools? \\[Y/n\\]"; then
  echo "expected selected-tool flow to ask for Y/n confirmation" >&2
  printf '%s\n' "${confirm_output}" >&2
  exit 1
fi

required_output="$(printf '1\n4\n' | "${repo_root}/scripts/install-prereqs.sh" 2>&1)"

if printf '%s\n' "${required_output}" | grep -q "Install or update Kubeforge-managed kubectl"; then
  echo "did not expect required install flow to ask about updating installed kubectl" >&2
  printf '%s\n' "${required_output}" >&2
  exit 1
fi

freelens_output="$(
  printf '2\nfreelens\ny\n4\n' |
    KUBEFORGE_TEST_PLATFORM_ID=apt KUBEFORGE_TEST_FORCE_MISSING_TOOLS=freelens "${repo_root}/scripts/install-prereqs.sh" 2>&1
)"

if printf '%s\n' "${freelens_output}" | grep -q "Install Freelens now"; then
  echo "did not expect Linux Freelens flow to prompt for unsupported automatic install" >&2
  printf '%s\n' "${freelens_output}" >&2
  exit 1
fi

if ! printf '%s\n' "${freelens_output}" | grep -q "Automatic install is not available for Freelens on Ubuntu/Debian"; then
  echo "expected Linux Freelens flow to print manual install guidance" >&2
  printf '%s\n' "${freelens_output}" >&2
  exit 1
fi

if ! rg -q "./scripts/install-prereqs.sh" "${repo_root}/scripts/configure.py"; then
  echo "expected configure hints to point at the interactive prereq installer" >&2
  exit 1
fi

if rg -q "prereqs --optional-only" "${repo_root}/scripts/configure.py" "${repo_root}/README.md"; then
  echo "did not expect docs/configure hints to point at --optional-only" >&2
  exit 1
fi
