# ShopStack Kubernetes Lab IP Plan

## Environment

Task 2 Final Run uses the documented cloud-VM fallback because Proxmox hardware was not available.

- Provider: Google Cloud Platform
- Region: us-central1
- Zone: us-central1-a
- VPC: shopstack-vpc
- Subnet: shopstack-subnet
- Subnet CIDR: 10.10.0.0/24
- Gateway: 10.10.0.1

## Cluster IP Plan

| Host | Role | Static Internal IP | Machine Type | Resources |
|---|---|---|---|---|
| k8s-cp | Control plane | 10.10.0.10 | e2-medium | 2 vCPU / 4 GB RAM |
| k8s-worker-1 | Worker | 10.10.0.11 | e2-medium | 2 vCPU / 4 GB RAM |
| k8s-worker-2 | Worker | 10.10.0.12 | e2-medium | 2 vCPU / 4 GB RAM |

All three addresses are reserved static internal IPv4 addresses and were verified as IN_USE.

Stable internal addressing is required because Ansible and Kubernetes must be able to identify nodes consistently.

## SSH Access

The MacBook Pro uses `~/.ssh/config` aliases:

- `ssh k8s-cp`
- `ssh k8s-worker-1`
- `ssh k8s-worker-2`

The aliases currently use the VMs' external IPv4 addresses for access from the MacBook Pro.

The external addresses are ephemeral and may change after VM lifecycle changes. The cluster's stable addressing is provided by the reserved internal IPv4 addresses above.

## Firewall

The GCP VPC uses:

- `shopstack-allow-internal` — permits internal ShopStack node traffic from `10.10.0.0/24`.
- `shopstack-allow-ssh` — permits TCP/22 to VMs with the `shopstack-k8s` network tag.

For this temporary lab, SSH is permitted from `0.0.0.0/0` because the administrator's VPN public IP changes frequently. A production deployment should restrict SSH sources or use a controlled access mechanism such as IAP or a bastion host.
