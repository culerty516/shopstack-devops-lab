# Task 2 Cloud-Init Template Notes

## Fallback Implementation

The Task 2 instructions permit cloud VMs when Proxmox hardware is unavailable. The Final Run therefore used Google Compute Engine.

The Proxmox concepts were mapped as follows:

| Proxmox | Google Cloud fallback |
|---|---|
| Ubuntu 24.04 cloud image | Official Ubuntu 24.04 LTS GCE cloud image |
| `qm disk import` | Boot disk created from the official GCE image |
| Cloud-init drive | Instance metadata `user-data` |
| VM template | GCE Machine Image |
| Full clone | New VM with an independent Persistent Disk |
| `vmbr0` | VPC and subnet |
| CPU/RAM configuration | GCE machine type |

## Source VM

The reusable source VM was:

- Name: `shopstack-template-source`
- OS: Ubuntu 24.04 LTS
- Architecture: x86_64
- Machine type: `e2-medium`
- CPU: 2 vCPU
- Memory: 4 GB
- Disk: 40 GB `pd-standard`
- VPC: `shopstack-vpc`
- Subnet: `shopstack-subnet`
- Network tag: `shopstack-k8s`

A 40 GB disk was used because the earlier trial exposed insufficient root-disk capacity.

Verification showed:

- `cloud-init status`: `done`
- user: `ubuntu`
- boot disk: 40 GB
- root partition: approximately 39 GB
- root filesystem: approximately 38 GB ext4

## Cloud-Init

Cloud-init configured:

- the `ubuntu` user;
- sudo access;
- the dedicated ShopStack SSH public key;
- password SSH authentication disabled;
- root SSH access disabled;
- root partition growth;
- root filesystem resize.

The dedicated key is stored on the MacBook Pro as:

`~/.ssh/shopstack_lab_ed25519`

Before creating the reusable image, the source VM was cleaned with:

`sudo cloud-init clean --logs --machine-id`

The source VM was then powered off.

## Reusable Template

A reusable GCE Machine Image was created:

`shopstack-ubuntu2404-template`

Its status was verified as `READY`.

Three VMs were created from this image:

- `k8s-cp`
- `k8s-worker-1`
- `k8s-worker-2`

All three use `e2-medium` and have independent 40 GB `pd-standard` boot disks.

## Full Clone vs Linked Clone

A full clone has an independent virtual disk and does not depend on the original template disk after creation.

A linked clone stores only differences relative to a shared base disk. It is faster and more storage-efficient to create, but it remains dependent on the parent/base image.

The GCP implementation is equivalent to a full-clone model because each Kubernetes VM has its own independent Persistent Disk.
