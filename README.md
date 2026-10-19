# ShopStack — DevOps Pre-Onboarding Lab

An end-to-end DevOps practice project covering Linux administration, cloud VM provisioning, Ansible, kubeadm, containers, GitHub Actions, Helm, Istio, four Kubernetes data stores, persistent storage, MinIO object storage, and backup/restore.

**Project:** `shopstack-devops-lab`  
**Implementation:** Tasks 1–7 on Google Cloud Compute Engine  

> **Scope of this README:** Document the **implemented** lab environment, provide an ordered reproduction guide, and identify the remaining manual steps and resource limitations. This repository is a learning lab, **not** a production-ready one-command installer.

## 1. Architecture

```text
                         SHOPSTACK DEVOPS ARCHITECTURE

         Infrastructure                             Source / CI/CD
+--------------------------------+       +--------------------------------+
| Ubuntu 24.04 GCE Machine Image |       | Git repository / frontend-src/ |
| shopstack-ubuntu2404-template  |       +---------------+----------------+
+---------------+----------------+                       |
                |                                        v
                v                        +--------------------------------+
+--------------------------------+       | GitHub Actions                 |
| 3 GCP Compute Engine VMs       |       | Buildx: AMD64 + ARM64          |
| k8s-cp + 2 worker nodes        |       | Trivy CRITICAL scan           |
+---------------+----------------+       +---------------+----------------+
                ^                                        |
                |                                        v
+---------------+----------------+       +--------------------------------+
| Ansible playbooks              |       | GHCR: shopstack-frontend       |
| common / containerd / packages |       +---------------+----------------+
| kubeadm bootstrap + Flannel    |                       |
+---------------+----------------+                       v
                |                        +--------------------------------+
                v                        | Helm upgrade --install         |
+--------------------------------+<------+ CI deploy: self-hosted runner  |
| 3-node kubeadm Kubernetes      |       | SSH tunnel to private K8s API |
| v1.37.0 / containerd / Flannel |       +--------------------------------+
+---------------+----------------+
                |
     +----------+--------------------------+-------------------------+
     |                                     |                         |
     v                                     v                         v
+----------------------------+ +---------------------------+ +------------------------+
| shopstack namespace        | | data namespace            | | storage namespace      |
| Online Boutique services   | | PostgreSQL 16 StatefulSet | | MinIO / S3 API         |
| Helm: custom Flask frontend| | Redis 8 + password / AOF  | | shopstack-images       |
| Istio sidecars / STRICT mTLS| | Elasticsearch (ECK)       | | shopstack-backups      |
| IngressGateway             | | NebulaGraph (operator)    | | versioned bucket       |
| shopstack.local            | +-------------+-------------+ +------------+-----------+
| canary: 90% v0.1.0         |               |                            ^
|         10% v0.2.0         |               v                            |
+----------------------------+ +---------------------------+              |
                               | Dynamically created PVCs  |              |
                               | local-path / node-local   |              |
                               +---------------------------+              |
                                                                          |
  PostgreSQL --> nightly pg_dump CronJob (shopstack) ----------------------+
  PostgreSQL <-- verified manual restore from MinIO backup object <-------+

Note: the data-store exercises and the upstream application are separately
validated lab workloads; this diagram does not imply that Online Boutique
uses all four data stores as its application backends.
```

**Important distinctions:**

- The actual infrastructure uses the **permitted GCP cloud-VM fallback**, not Proxmox. `docs/cloud-init-template.md` maps the equivalent concepts.
- The Kubernetes PVs are dynamically provisioned with **Rancher Local Path Provisioner**. This is node-local persistence on the VM filesystem; it is **not** a GCE Persistent Disk CSI-backed PVC. A separate GCP Persistent Disk hot-attach/XFS/LVM exercise was completed for Task 7.
- Online Boutique and the custom Flask frontend are application demonstrations. The PostgreSQL, Redis, Elasticsearch, and NebulaGraph exercises prove operation, data loading, policies, and recovery; this repository does **not** claim the upstream Online Boutique application's real product catalog has been rewritten to use all four stores.
- The production-like architecture is illustrative. The control plane and each data service are single-node or lab-sized, not a high-availability production configuration.

## 2. Lab environment

| Component | Configuration |
|---|---|
| Cloud provider | Google Cloud Compute Engine, `us-central1-a` |
| VPC / subnet | `shopstack-vpc` / `shopstack-subnet` (`10.10.0.0/24`) |
| `k8s-cp` | `10.10.0.10` — `e2-medium`, 2 vCPU, 4 GiB RAM |
| `k8s-worker-1` | `10.10.0.11` — `e2-medium`, 2 vCPU, 4 GiB RAM |
| `k8s-worker-2` | `10.10.0.12` — `e2-medium`, 2 vCPU, 4 GiB RAM |
| VM image / boot disks | Ubuntu 24.04 LTS (AMD64); independent 40 GB `pd-standard` boot disks |
| Kubernetes / runtime | kubeadm v1.37.0; containerd 2.2.1; Flannel v0.28.9 on `ens4` |
| StorageClass | `local-path` (Rancher Local Path Provisioner v0.0.36) |
| Frontend registry | `ghcr.io/culerty516/shopstack-frontend` (`linux/amd64`, `linux/arm64`) |
| Application packaging | `charts/frontend-chart`, Helm 3 |
| Service mesh | Istio 1.31.0, sidecar injection, `STRICT` mTLS |
| Data platform | PostgreSQL 16, Redis 8.x, Elasticsearch 9.5.3 (ECK 3.5.0), NebulaGraph v3.8.0 (operator chart 1.8.8) |
| Object store | PVC-backed single-node MinIO, S3-compatible API |
| Local control machine | MacBook Pro, SSH access to GCP and private Kubernetes API tunnel |

Full addresses, firewall assumptions, snapshots, and template notes: [IP plan](docs/ip-plan.md), [cloud-init fallback](docs/cloud-init-template.md), [snapshot evidence](docs/snapshot-backup-evidence.md).

## 3. Repository guide

| Path | Purpose |
|---|---|
| [`journal.md`](journal.md) | Detailed Tasks 1–7 work log, commands, results, troubleshooting, and checkpoint answers |
| [`ansible/`](ansible/) | Node setup, containerd, Kubernetes packages, kubeadm/Flannel, inventory, idempotency proof |
| [`frontend-src/`](frontend-src/) | Custom Flask frontend (`/` and `/healthz`), container image source |
| [`.github/workflows/build-image.yaml`](.github/workflows/build-image.yaml) | Buildx/QEMU image build, GHCR publishing, Trivy gate, optional runner-based Helm deploy |
| [`charts/frontend-chart/`](charts/frontend-chart/) | Original Helm chart for custom frontend Deployment, Service and ServiceAccount; optional Ingress disabled by default |
| [`k8s/`](k8s/) | Online Boutique manifests and Kubernetes practice resources |
| [`istio/`](istio/) | Gateway, VirtualServices, canary workloads, DestinationRule, mTLS, policy and telemetry |
| [`data/`](data/) | PostgreSQL StatefulSet, headless Service, backup PVC/CronJob and policies |
| [`redis/`](redis/) | Redis StatefulSet/AOF, network policies, Sentinel lab and cache-aside notes |
| [`elastic/`](elastic/) | ECK Elasticsearch/Kibana resources, `products` mapping/data/query examples |
| [`nebula/`](nebula/) | NebulaCluster CR, nGQL schema, sample graph and recommendation queries |
| [`minio/`](minio/) | MinIO resources, least-privilege policies, object storage/restore/versioning evidence |
| [`runbooks/`](runbooks/) | PostgreSQL recovery, Elasticsearch snapshot and Nebula backup documentation |
| [`docs/evidence/`](docs/evidence/) | Screenshots captured during Tasks 5–7 |
| [`storage/`](storage/) | Storage access-mode experiment |
| [`diskguard.sh`](diskguard.sh), [`pulse.sh`](pulse.sh), [`systemd/`](systemd/) | Linux foundations deliverables |

## 4. Reproduction: prerequisites and manual provisioning

This section gives the **documented deployment order and representative commands**, but it is **not yet an independently executed clean-room bootstrap script**. Some source infrastructure and runtime secrets are not in Git; those steps must be performed by the reviewer.

### 4.1 Required tooling and access

- Git, SSH, Ansible, `kubectl`, Helm 3, `istioctl` (version 1.31.0), `mc` (MinIO Client), and (for infrastructure creation) the GCP Console or `gcloud`.
- A GCP project with a valid billing account, quota for three `e2-medium` VMs, appropriate Compute Engine access, and a compatible Ubuntu 24.04 AMD64 image.
- An administrator-controlled dedicated SSH key (the reference workstation uses `~/.ssh/shopstack_lab_ed25519`; replace with your own key as appropriate). **The private key and kubeconfig are not part of this repository.**
- Permission to create/update runtime Kubernetes Secrets, GHCR image access, and the required operator Helm releases.
- A dedicated self-hosted GitHub Actions runner with label `task4-deploy` is required **only for the optional CI deployment job**. Image build and Trivy scanning run on GitHub-hosted runners.

### 4.2 Re-create or substitute the VM template

The GCE Machine Image is named `shopstack-ubuntu2404-template`, created from a cloud-init-cleaned Ubuntu 24.04 source VM. This image is **not exported in the repository** and cannot be assumed available in another GCP project or GitHub fork.

Recreate a compatible image following [`docs/cloud-init-template.md`](docs/cloud-init-template.md), then provision three fresh VMs in `us-central1-a` with independent 40 GB boot disks, `e2-medium` machine types, and the reserved internal addresses shown in [`docs/ip-plan.md`](docs/ip-plan.md). Set up `shopstack-vpc`, `shopstack-subnet`, intra-cluster firewall access, and admin SSH access. These cloud resources were provisioned manually rather than through a committed Terraform/Ansible cloud-provisioning module.

Set local `~/.ssh/config` aliases so these work, updating external addresses after GCP VM lifecycle changes:

```bash
ssh k8s-cp
ssh k8s-worker-1
ssh k8s-worker-2
```

**Security:** Keep TCP 6443 private; the original lab allowed external SSH access using keys. Narrow SSH access (such as IAP or a bastion) for a real environment. Avoid committing SSH private keys, kubeconfigs, MinIO credentials, or real Secret values.

### 4.3 Clone repository and configure nodes

```bash
git clone https://github.com/culerty516/shopstack-devops-lab.git
cd shopstack-devops-lab

ansible -i ansible/inventory.ini all -m ping
ansible-playbook -i ansible/inventory.ini ansible/k8s-node-setup.yaml
ansible-playbook -i ansible/inventory.ini ansible/k8s-cluster.yaml
```

The inventory assumes SSH aliases `k8s-cp`, `k8s-worker-1`, and `k8s-worker-2` and GCP node addresses `10.10.0.10–12`. Edit the inventory and associated kubeadm/GCP-specific settings if deploying to a different network or interface. The control plane playbook initializes kubeadm, configures Flannel to use `ens4`, joins workers, and waits for three Ready nodes. See the idempotency records in [`ansible/evidence/`](ansible/evidence/).

### 4.4 Access the private Kubernetes API

Kubernetes port 6443 is intentionally not exposed publicly. Run the SSH tunnel on the control workstation:

```bash
ssh -fN -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:6443:10.10.0.10:6443 k8s-cp
```

Retrieve the admin kubeconfig prepared for the `ubuntu` user by the Ansible playbook, then point its API endpoint at the tunnel:

```bash
mkdir -p "$HOME/.kube"
scp k8s-cp:/home/ubuntu/.kube/config "$HOME/.kube/task4-final-config"
chmod 600 "$HOME/.kube/task4-final-config"
export KUBECONFIG="$HOME/.kube/task4-final-config"

kubectl config set-cluster kubernetes \
  --server=https://127.0.0.1:6443 \
  --tls-server-name=10.10.0.10
kubectl config use-context kubernetes-admin@kubernetes
kubectl get nodes -o wide
```

**Every new shell** must export `KUBECONFIG` again, unless a secure persistent shell setup is configured. If `127.0.0.1:6443` is refused, first verify the SSH tunnel rather than resetting the cluster.

### 4.5 Provision base namespaces and local storage

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f data/namespace.yaml
kubectl apply -f minio/namespace.yaml
kubectl apply -f \
  https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml
kubectl get storageclass
```

For this lab, `local-path` has `WaitForFirstConsumer` binding behavior. Its PVC data is node-local: it is **not** portable multi-zone managed cloud block storage. Real GCP volume attachment would require a suitable, correctly configured GCE Persistent Disk CSI environment.

### 4.6 Create runtime credentials **before** deploying dependent services

The following namespace-qualified Kubernetes Secrets are required by the committed manifests and must be created through an approved secrets workflow:

| Namespace | Secret | Required keys / usage |
|---|---|---|
| `shopstack` | `frontend-db-secret` | `db-user`, `db-password` (backup CronJob) |
| `data` | `frontend-db-secret` | Matching `db-user`, `db-password` (PostgreSQL StatefulSet) |
| `data` | `redis-auth-secret` | `redis-password` (Redis) |
| `storage` | `minio-root-credentials` | `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` (MinIO) |
| `shopstack` | `minio-backup-credentials` | `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` (backup upload) |
| `shopstack` | `minio-app-credentials` | Application-only MinIO identity, created during the access-control exercise |

The same database username/password must be used in both database Secrets because Secrets cannot be referenced across namespaces. After MinIO starts, use `mc` to set up `shopstack-images`, `shopstack-backups`, the limited policies from [`minio/`](minio/), and the associated application/backup identities. The backup uploader must **not** have object-delete permission. Enable versioning on `shopstack-backups` and configure the 7-day noncurrent-version lifecycle rule; details and observed proof are in [`minio/README.md`](minio/README.md).

**Do not use the demonstration values in [`k8s/frontend-secret.yaml`](k8s/frontend-secret.yaml) as real credentials.** The tracked file is a classroom example, not a production secret-management solution. For real deployment use an approved secret manager/External Secrets workflow, keep credentials out of Git, and rotate any exposed demonstration values before use.

### 4.7 Install application and service mesh

Deploy the upstream Online Boutique demo from the tracked manifest; the application manifest is based on upstream release v0.10.6:

```bash
kubectl apply -n shopstack -f k8s/online-boutique.yaml
```

**Helm ownership warning:** Upstream/demo or non-Helm-managed `Deployment/frontend` and `Service/frontend` resources may conflict with the names managed by `charts/frontend-chart`. Before installing the custom Helm frontend, inspect the resources and remove **only conflicting frontend objects** if they are not Helm-owned; do not delete the entire demo stack.

```bash
helm lint charts/frontend-chart
helm upgrade --install shopstack-frontend charts/frontend-chart \
  --namespace shopstack --wait --timeout 5m
```

Install Istio demo profile and enroll `shopstack` in sidecar mode:

```bash
istioctl install --set profile=demo -y
kubectl label namespace shopstack istio-injection=enabled --overwrite
kubectl rollout restart deployment -n shopstack
```

Apply the committed traffic/security definitions individually. **Do not recursively apply the entire `istio/` directory**: `istio/tests/` contains fault-injection/troubleshooting resources that are not normal bootstrap configuration.

```bash
kubectl apply -f istio/canary-workloads.yaml
kubectl apply -f istio/destinationrule.yaml
kubectl apply -f istio/gateway.yaml
kubectl apply -f istio/virtualservice.yaml
kubectl apply -f istio/peer-authentication.yaml
kubectl apply -f istio/authorization-policy.yaml
kubectl apply -f istio/telemetry.yaml
```

The live canary route defined in [`istio/virtualservice.yaml`](istio/virtualservice.yaml) sends **90%** of requests to frontend `0.1.0` and **10%** to `0.2.0`. `shopstack.local` is served through `istio-ingressgateway`; no cloud load-balancer IP is allocated in this bare-kubeadm lab. Use a local port-forward to the gateway and the correct `Host: shopstack.local` HTTP header, or provide an equivalent private routing/DNS setup.

The regular Helm release `frontend` and the separate Istio canary `shopstack-frontend-v1/v2` are distinct resources; the Gateway's `VirtualService` targets the **canary Service**, not the regular Helm `frontend` Service.

### 4.8 Deploy data stores, operators, and MinIO

After creating runtime credentials and the StorageClass, apply the committed persistent resources in dependency order:

```bash
kubectl apply -f data/postgres-headless-service.yaml
kubectl apply -f data/postgres-statefulset.yaml
kubectl apply -f data/postgres-peer-authentication.yaml
kubectl apply -f data/postgres-authorization-policy.yaml

kubectl apply -f redis/redis-service.yaml
kubectl apply -f redis/redis-statefulset.yaml
kubectl apply -f redis/redis-networkpolicy.yaml
kubectl apply -f redis/redis-peer-authentication.yaml
kubectl apply -f redis/redis-authorization-policy.yaml

kubectl apply -f minio/pvc.yaml
kubectl apply -f minio/deployment.yaml
kubectl apply -f minio/service.yaml
```

Install operators **before** applying their Custom Resources (CRs). The deployment uses ECK operator chart `3.5.0` in `elastic-system` and Nebula Operator chart `1.8.8` in `nebula-system`:

```bash
helm repo add elastic https://helm.elastic.co
helm repo add nebula-operator https://vesoft-inc.github.io/nebula-operator/charts
helm repo update

helm upgrade --install elastic-operator elastic/eck-operator \
  --namespace elastic-system --create-namespace --version 3.5.0
helm upgrade --install nebula-operator nebula-operator/nebula-operator \
  --namespace nebula-system --create-namespace --version 1.8.8

kubectl apply -f elastic/elasticsearch.yaml
kubectl apply -f nebula/nebula-cluster.yaml
```

Populate Elasticsearch's `products` index using [`elastic/products-mapping.json`](elastic/products-mapping.json) and [`elastic/products-bulk.ndjson`](elastic/products-bulk.ndjson); sample fuzzy/bool/aggregation queries are in the same directory. Load the NebulaGraph `shopstack` space with [`nebula/schema.ngql`](nebula/schema.ngql), [`nebula/sample-data.ngql`](nebula/sample-data.ngql), and test the 2-hop recommendation in [`nebula/queries.ngql`](nebula/queries.ngql). The exact console/client commands and troubleshooting history are recorded in [`journal.md`](journal.md).

Optional Kibana and Nebula Studio visual interfaces are represented by [`elastic/kibana.yaml`](elastic/kibana.yaml) and [`nebula/studio.yaml`](nebula/studio.yaml), but they are **not mandatory runtime components for the Capstone data-store requirement** and may be scaled down after gathering evidence to conserve RAM.

Once MinIO's buckets, permissions and backup credentials have been configured, install the scheduled backup resources:

```bash
kubectl apply -f data/postgres-backup-pvc.yaml
kubectl apply -f data/postgres-backup-cronjob.yaml
```

**Actual CronJob namespace:** `shopstack`, not `data`. It runs at `02:00` (Kubernetes controller time zone unless configured otherwise), creates a PostgreSQL custom-format `pg_dump`, and uploads it using the `minio-upload` container to `shopstack-backups`. It requires `shopstack/minio-backup-credentials`, `shopstack/frontend-db-secret`, and the `shopstack/postgres-backups` PVC.

### 4.9 CI/CD and deployment ownership

[`.github/workflows/build-image.yaml`](.github/workflows/build-image.yaml) implements:

1. Push to `main`, push of a `v*` tag, or manual dispatch.
2. GitHub-hosted Buildx/QEMU build and push to GHCR for `linux/amd64` **and** `linux/arm64`, tagged by immutable full commit SHA (and semver on release tags).
3. Build cache (`type=gha`) and Trivy CRITICAL vulnerability gates on both architectures.
4. On `main` only, a `self-hosted`/`task4-deploy` runner connects over the existing private API tunnel and performs `helm upgrade --install` with the new immutable SHA image, followed by rollout/response verification.

**The deploy stage does not run unless the self-hosted runner is registered, online, and has the expected local SSH/kubeconfig setup.** A GitHub-hosted green *build/scan* alone is not proof that a fresh cluster has been deployed. Never place privileged cluster kubeconfig content in this public Git repository.

## 5. Validation checklist

Run these checks with the correct kubeconfig and tunnel:

```bash
kubectl get nodes -o wide
kubectl get pods -n shopstack
kubectl get pods -n data
kubectl get pvc -A
kubectl get storageclass
kubectl get elasticsearch -n data
kubectl get nebulacluster -n data
kubectl get cronjobs,jobs -n shopstack
helm status shopstack-frontend -n shopstack
istioctl proxy-status
```

Also verify (with the documented runtime clients): HTTP `Host: shopstack.local` routing; approximate 90/10 canary responses over repeated requests; mTLS from Kiali; `products` search index and Nebula 2-hop recommendation result; `boutique` PostgreSQL row count; Redis authentication/AOF persistence; and MinIO object presence/versioning. **Do not mark a validation complete based solely on the existence of a manifest file.**

## 6. PostgreSQL restore from MinIO (non-destructive verification)

A restore test successfully recovered a `pg_dump -Fc` object from the versioned `shopstack-backups` bucket into a **temporary database**, with `original_rows=5` and `restored_rows=5` (see [`minio/README.md`](minio/README.md)). This is safer than dropping the live `boutique` database during a routine review.

**Runbook for an authorized lab restore:**

1. Confirm the backup object exists in `shopstack-backups` and the `mc` alias points to the intended MinIO instance. When MinIO has no external endpoint, use a local `kubectl -n storage port-forward svc/minio 9000:9000`, then configure the `mc` alias with securely retrieved runtime credentials.
2. Download the chosen object to the control workstation, for example:

   ```bash
   mc cp shopstack/shopstack-backups/<BACKUP_FILENAME>.dump /tmp/boutique-restore.dump
   ```

   `shopstack` in this example is the **local mc alias**, not a Kubernetes namespace. Replace `<BACKUP_FILENAME>` with a real listed object.
3. Copy the object into PostgreSQL and create an empty scratch database:

   ```bash
   kubectl cp /tmp/boutique-restore.dump data/postgres-0:/tmp/boutique-restore.dump
   kubectl exec -n data postgres-0 -- sh -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE boutique_restore_check;"'
   ```

4. Restore and check the product rows:

   ```bash
   kubectl exec -n data postgres-0 -- sh -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -U "$POSTGRES_USER" -d boutique_restore_check /tmp/boutique-restore.dump'

   kubectl exec -n data postgres-0 -- sh -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" psql -U "$POSTGRES_USER" -d boutique_restore_check -tAc "SELECT COUNT(*) FROM products;"'
   ```

5. Compare restored rows with the expected backup contents, validate sample records, and only then optionally drop `boutique_restore_check`. Keep the original database intact. To perform a deliberate destructive recovery test, follow the safety steps in [`runbooks/postgres-restore.md`](runbooks/postgres-restore.md), which documents a local-copy disaster drill; the MinIO download step above supplies an S3-origin backup instead.

Restore success depends on valid runtime credentials, accessible MinIO, compatible PostgreSQL archive format, and enough free disk capacity. This is a **manual runbook**, not an automated restore controller.

## 7. Evidence and assessment

### Tracked screenshots

- [Kiali service graph](docs/evidence/task5/kiali-healthy-service-graph.png) and [Kiali mTLS lock verification](docs/evidence/task5/kiali-mtls-lock-verification.png)
- [Grafana request/error rates](docs/evidence/task5/grafana-request-error-rates.png) and [Jaeger trace](docs/evidence/task5/jaeger-distributed-trace.png)
- [Kibana product query](docs/evidence/task6/kibana-dev-tools-products-query.png) and [NebulaGraph Studio graph](docs/evidence/task6/nebula-studio-shopstack-graph.png)
- [MinIO versioned backup bucket browser](docs/evidence/task7/minio-console-bucket-browser.png)

### CI evidence

- [GitHub Actions workflow and run history](https://github.com/culerty516/shopstack-devops-lab/actions/workflows/build-image.yaml)
- [Workflow configuration](.github/workflows/build-image.yaml) including `linux/amd64,linux/arm64` build, vulnerability scan, and conditional deployment.
- [Green Multi-Arch CI Screenshot](docs/evidence/task4/github-actions-multiarch-success.png) — [Successful Workflow #11](https://github.com/culerty516/shopstack-devops-lab/actions/runs/35516140322), demonstrating successful AMD64/ARM64 build, Trivy vulnerability gate, and Kubernetes deployment.

### Other evidence

- [Ansible idempotency output](ansible/evidence/)
- [Helm history](charts/helm-history-evidence.txt)
- [MinIO backup/restore, policy, versioning and lifecycle evidence](minio/README.md)
- [Full implementation and troubleshooting journal](journal.md)

## 8. Known limitations and next steps

1. **Capacity:** Three `e2-medium` VMs have 12 GiB total RAM, but ordinary workloads are generally scheduled onto the two 4 GiB workers (less node/OS overhead). Elasticsearch uses a 2 GiB JVM heap with a 3 GiB container limit; Task 6 measured approximately 2.7 GiB Elasticsearch usage and approximately 85% memory consumption on worker 2. Optional UIs, stretch labs, or other Pods were scaled down to free resources. Simultaneous, sustained operation of every Capstone-required component under this configuration has **not** been revalidated in an independent clean-room run. A larger worker footprint may be necessary for stable full-stack operation.
2. **Node-local persistence:** `local-path` PVCs are not zonal GCP CSI volumes; rescheduling a stateful workload to another node does not give it the same attached storage. Do not treat this as production high-availability database storage.
3. **Manual infrastructure:** GCP VPC, firewall, static private IPs, machine-image recreation, VM creation, admin SSH aliases, credentials, service-account permissions, MinIO bucket/policy initialization, ECK/Nebula sample-data loading, and runner registration require manual steps or additional automation not yet committed here.
4. **Single-node components:** The control plane, PostgreSQL, Elasticsearch, and MinIO are lab-sized; they have no production-grade HA, disaster recovery, or managed-secret guarantees.
5. **Environment-bound automation:** The workflow deployment job assumes a MacBook self-hosted runner and a local kubeconfig/tunnel. A new fork needs its own GHCR ownership, workflow permissions, runner and access configuration.

## 9. References

- [Kubernetes documentation](https://kubernetes.io/docs/)
- [Ansible documentation](https://docs.ansible.com/)
- [Helm documentation](https://helm.sh/docs/)
- [Istio documentation](https://istio.io/latest/docs/)
- [Online Boutique upstream repository](https://github.com/GoogleCloudPlatform/microservices-demo)
- [Elastic Cloud on Kubernetes](https://www.elastic.co/docs/deploy-manage/deploy/cloud-on-k8s)
- [NebulaGraph documentation](https://docs.nebula-graph.io/)
- [Rancher Local Path Provisioner](https://github.com/rancher/local-path-provisioner)

---
