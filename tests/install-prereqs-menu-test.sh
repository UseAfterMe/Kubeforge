#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$(printf '5\n' | "${repo_root}/scripts/install-prereqs.sh" 2>&1)"

if ! printf '%s\n' "${output}" | grep -q "Kubeforge prerequisite installer"; then
  echo "expected no-arg install-prereqs to show the interactive menu" >&2
  printf '%s\n' "${output}" >&2
  exit 1
fi

if ! printf '%s\n' "${output}" | grep -q "Install selected tools"; then
  echo "expected menu to include selected-tool installation" >&2
  printf '%s\n' "${output}" >&2
  exit 1
fi

if printf '%s\n' "${output}" | grep -q "^Usage:"; then
  echo "did not expect no-arg install-prereqs to print usage" >&2
  printf '%s\n' "${output}" >&2
  exit 1
fi
