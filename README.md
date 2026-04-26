# Kubeforge

Kubeforge builds production-style Kubernetes clusters on Proxmox using `kubeadm`, OpenTofu, cloud-init, and Ansible.

It is designed for environments that range from homelabs to more serious lab, edge, and enterprise-style deployments where you want repeatable cluster lifecycle management without giving up control over the underlying Kubernetes stack.

Out of the box it handles:

- VM provisioning on Proxmox with OpenTofu
- cloud image bootstrapping with cloud-init
- Kubernetes node preparation with Ansible
- `kubeadm` + `containerd`
- Cilium with native LoadBalancer IPAM and L2 announcements
- Traefik
- kube-vip for multi-control-plane API high availability
- optional Proxmox CSI

Ubuntu and Rocky Linux cloud images are both supported.

## Highlights

- Interactive `configure` flow with curated Ubuntu and Rocky presets
- VM/IP/VMID planning with subnet validation and safer config guardrails
- Proxmox-managed NIC MAC addresses by default
- kube-vip for lightweight multi-control-plane API high availability
- Cilium-native service load balancing
- Automatic kubeconfig fetch, install, and merge into `~/.kube/config`
- Cluster-aware `destroy` and `upgrade` workflows for multi-cluster workstations
- Built-in `health` command for fast post-bootstrap validation
- Upstream Helm-based Proxmox CSI support, with `pvecsictl` available for manual local-storage PV moves

## Requirements

Run the deployer from macOS, Ubuntu/Debian, or Rocky/RHEL/Fedora.

Required tools:

- `tofu`
- `ansible-playbook`
- `ansible-inventory`
- `python3`
- `ssh`
- `ssh-keygen`
- `kubectl`
- `jq`
- `openssl`

Optional but recommended local tools:

- `cilium` CLI for inspecting Cilium networking, policies, and LoadBalancer state
- `ssh-copy-id` for `./deploy.sh proxmox-ssh-setup`
- `kubectx` for faster multi-cluster context switching
- `Freelens` for a local Kubernetes GUI
- `k9s` for a terminal Kubernetes UI
- `pvecsictl` for moving local Proxmox CSI volumes between Proxmox nodes
  - pvecsictl requires Go when installed via `go install`

Install or check prerequisites before deploying:

```bash
./deploy.sh prereqs
./deploy.sh check-prereqs
```

The prereq installer:

- detects macOS, Ubuntu, Debian, RHEL, Rocky, and Fedora hosts
- uses Homebrew, `apt`, or `dnf` where appropriate
- prompts before installing each required and optional tool
- installs `kubectl` as a local binary in `~/.local/bin`
- treats existing installations as valid, so already-prepared workstations are not changed unless you choose to install or update a tool

Supported auto-install prompts use:

- macOS via Homebrew
- Debian/Ubuntu via `apt`
- Rocky/RHEL/Fedora via `dnf`

## Quick Start

```bash
./deploy.sh prereqs
./deploy.sh configure
./deploy.sh apply
./deploy.sh bootstrap
./deploy.sh health
```

That flow gives you:

- rendered Terraform and Ansible inputs
- provisioned Proxmox VMs
- a bootstrapped Kubernetes cluster
- merged kubeconfig in `~/.kube/config`
- a quick post-bootstrap health check

### What each step does

`configure`

- Writes `terraform.tfvars.json`
- Validates Proxmox connectivity and VMID choices
- Lets you choose Ubuntu or Rocky image presets, plus custom image URL/file overrides

`apply`

- Applies infrastructure with OpenTofu
- Downloads the selected cloud image
- Creates VMs and renders fresh inventory / Ansible vars
- Refreshes your local kubeconfig from `out/kubeconfig` only when one already exists from a previous successful bootstrap

`bootstrap`

- Waits for SSH reachability
- Prepares nodes
- Bootstraps kubeadm
- Installs Cilium, Cilium LoadBalancer IPAM / L2 announcements, Traefik, kube-vip for HA clusters, and optional Proxmox CSI
- Uses the upstream Helm-based Proxmox CSI install path and creates a `proxmox` StorageClass for the selected Proxmox datastore
- Fetches `out/kubeconfig`
- Backs up and merges the cluster kubeconfig into `~/.kube/config` as soon as `out/kubeconfig` is available during bootstrap
- Prints optional local tool suggestions at the end of a successful bootstrap

`health`

- Uses the installed kubeconfig if available, otherwise `out/kubeconfig`
- Validates nodes, core cluster services, cluster API reachability, Cilium LoadBalancer IP pools, and assigned LoadBalancer service IPs

`upgrade`

- Prompts for the target tracked cluster when more than one cluster exists
- Checks your configured Kubernetes and chart versions against newer available upstream versions
- Prompts you which discovered upgrades you want to apply before running the upgrade playbook
- Updates `terraform.tfvars.json` and the rendered Ansible vars for the selected target versions

## Commands

```bash
./deploy.sh prereqs
./deploy.sh check-prereqs
./deploy.sh configure
./deploy.sh plan
./deploy.sh apply
./deploy.sh bootstrap
./deploy.sh upgrade
./deploy.sh destroy
./deploy.sh output
./deploy.sh install-kubeconfig
./deploy.sh proxmox-ssh-setup
./deploy.sh health
```

## Generated Files

Useful outputs:

- `out/inventory.yml`
- `out/ansible-vars.yml`
- `out/kubeconfig`
- `out/ssh/id_cluster_ed25519`
- `out/deployment-history/<workspace>/last-applied.tfvars.json`
- `out/deployment-history/<workspace>/ssh/id_cluster_ed25519`

## Kubeconfig Behavior

After a successful `bootstrap`:

- the cluster kubeconfig is fetched to `out/kubeconfig`
- the deployer installs it into `~/.kube/config`
- if `~/.kube/config` already exists, it is:
  - backed up with a timestamped `.bak.*` suffix
  - merged with the new cluster config while preserving cluster-specific authinfo names

If bootstrap later fails after kubeconfig has already been fetched, the deployer still refreshes `~/.kube/config` from that fetched file instead of losing it.

You do not need to edit your shell profile when using `~/.kube/config`.

If you want to reinstall or re-merge it later:

```bash
./deploy.sh install-kubeconfig
```

After `apply`:

- if `out/kubeconfig` already exists from an earlier successful bootstrap, the deployer refreshes `~/.kube/config`
- if no kubeconfig has been fetched yet, the deployer leaves kubeconfig alone and tells you that installation will happen after bootstrap

## OS Notes

### Ubuntu

- Uses `apt`
- Uses the configured bootstrap user, default `ubuntu`
- Recommends Ubuntu 24.04 LTS in the interactive configure flow
- Adds a serial socket for Ubuntu cloud-image VMs so Proxmox disk resize works reliably during first boot
- Applies node updates before Kubernetes prep

### Rocky

- Uses `dnf`
- Uses the configured bootstrap user, default `rocky`
- Can optionally install and enable Cockpit
- Writes explicit DNS settings before package work to avoid cloud-init / NetworkManager DNS surprises
- Enables `sshd` correctly in cloud-init

## Multi-Control-Plane Behavior

- Single control plane:
  - Kubernetes API endpoint is the control-plane node IP
- Two or more control planes:
  - kube-vip provides a floating virtual IP for the Kubernetes API
  - Kubernetes API endpoint points at the kube-vip IP

## Destroy Behavior

The deployer keeps a history of the last applied config per cluster workspace.

That allows `destroy` to:

- target the correct cluster even if your current `terraform.tfvars.json` has changed
- prompt you when multiple tracked clusters exist
- fall back to legacy root state when cleaning up older deployments created before workspace-aware state handling
- prune only the destroyed cluster from `~/.kube/config`, while leaving other contexts intact
- remove shared `out/` artifacts only when they belong to the cluster being destroyed
- preserve the shared bootstrap SSH key in `out/ssh/` by restoring it from another remaining cluster history when appropriate

## Health Checks

Run:

```bash
./deploy.sh health
```

It validates:

- node readiness
- cluster API access
- `coredns`
- `cilium-operator`
- `traefik`
- Cilium LoadBalancer IP pool ranges and usage
- LoadBalancer services and assigned external IPs
- all pods across namespaces

## Troubleshooting

### `bootstrap` says rendered outputs are stale

If you changed `terraform.tfvars.json`, run:

```bash
./deploy.sh apply
```

### Ubuntu `apply` fails while creating VMs

If Proxmox reports worker, lock, or boot-disk resize failures while creating Ubuntu VMs:

- retry with the current Kubeforge defaults first
- prefer Ubuntu 24.04 LTS unless you are actively testing a newer Ubuntu release
- set `KUBEFORGE_TOFU_PARALLELISM=1` for the retry if your Proxmox host is still hitting worker or storage-lock races
- if a failed run left partial VMs behind, destroy that workspace and apply again

`bootstrap` uses rendered outputs from `out/inventory.yml` and `out/ansible-vars.yml`. It should not run against old rendered data.

### Proxmox snippets upload fails

If Proxmox is using the `local` snippets datastore, the host needs:

```bash
sudo install -d -m 0755 /var/lib/vz/snippets
```

The deployer can create that automatically if Proxmox SSH access has been set up with:

```bash
./deploy.sh proxmox-ssh-setup
```

### QEMU guest agent is installed but inactive

The guest package alone is not enough. The Proxmox VM option must also enable the QEMU guest agent device. If you changed that option on an existing VM, a full stop/start may be required.

### Rocky package installs hang or fail

The deployer writes explicit DNS configuration and bounds package-manager timeouts, but mirror issues can still happen. Re-running `bootstrap` after connectivity stabilizes is usually enough.

### Cilium LoadBalancer IP pool validation fails

Use full IPv4 range syntax in the rendered config. The deployer now normalizes shorthand like:

- `192.168.1.80-89`

into:

- `192.168.1.80-192.168.1.89`

If you changed the tfvars manually, rerun:

```bash
./deploy.sh apply
```

before `bootstrap`.

### Proxmox CSI and local storage migration

The deployer installs Proxmox CSI using the upstream Helm chart flow and creates a `proxmox` StorageClass that points at your selected Proxmox datastore.

For local Proxmox storage like `lvm`, `lvm-thin`, `zfs`, `ext4`, or `xfs`, cross-node PV moves are still a manual workflow. The upstream project documents `pvecsictl` for those offline PV migrations.

### Re-running `bootstrap`

If you changed configuration and want to rerun bootstrap cleanly, refresh the rendered outputs first:

```bash
./deploy.sh apply
./deploy.sh bootstrap
```

## Optional Local Tooling

If you want a smoother day-to-day operator experience, these are the most useful optional tools to add:

- `cilium` CLI for Cilium networking and service IP troubleshooting
- `Freelens` for a desktop Kubernetes UI
- `kubectx` for fast context switching between clusters
- `k9s` for terminal-based Kubernetes inspection
- `pvecsictl` for manual local Proxmox CSI volume moves between Proxmox nodes
  - `pvecsictl` requires Go when installed with `go install`

Run the prereq installer to add optional tools interactively:

```bash
./deploy.sh prereqs --optional-only
```

Kubeforge installs local binaries into `~/.local/bin`. Add it to your shell profile if it is not already in your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Official project links:

- Freelens: https://freelensapp.github.io/
- kubectx: https://github.com/ahmetb/kubectx
- k9s: https://k9scli.io/
- pvecsictl: https://github.com/sergelogvinov/proxmox-csi-plugin

## Example Config

See `terraform.tfvars.example` for the generated config structure.

## License

Kubeforge is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
