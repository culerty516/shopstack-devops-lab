# Task 2 Snapshot and Backup Evidence

## Snapshot Evidence

Snapshots were created for all three Kubernetes nodes before proceeding:

| Snapshot | Source Disk | Size | Status |
|---|---|---|---|
| `k8s-cp-pre-task3` | `k8s-cp` | 40 GB | READY |
| `k8s-worker-1-pre-task3` | `k8s-worker-1` | 40 GB | READY |
| `k8s-worker-2-pre-task3` | `k8s-worker-2` | 40 GB | READY |

These GCP Persistent Disk snapshots are the cloud-fallback evidence for the Task 2 snapshot requirement.

## Why Snapshots Are Not Backups

A traditional hypervisor snapshot is mainly a point-in-time rollback mechanism. It may still depend on the same underlying storage as the original VM.

A proper backup strategy should include:

- independent backup storage;
- scheduled backups;
- retention policies;
- integrity verification;
- tested restore procedures.

Cloud disk snapshots are durable recovery artifacts, but they still do not replace a complete backup and disaster-recovery policy.

## Proxmox Backup Job

In a real Proxmox VE environment, a backup job would define:

- which VM is protected;
- the backup storage target;
- the backup schedule;
- backup mode;
- retention policy;
- periodic restore testing.

For example, the Kubernetes control-plane VM could be included in a nightly scheduled backup job with multiple retained restore points.

## Proxmox Backup Server

Proxmox Backup Server (PBS) would normally be used as a dedicated backup target rather than relying only on the Proxmox VE host's local storage.

PBS provides features including:

- incremental backups;
- deduplication;
- backup verification;
- retention management;
- efficient restore.

Because this Final Run used the permitted GCP fallback, actual GCP disk snapshots were created and the equivalent Proxmox backup design was documented rather than claiming that a Proxmox environment was available.
