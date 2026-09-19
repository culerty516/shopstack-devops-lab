# NebulaGraph Backup and Restore Runbook

## Purpose

ShopStack uses NebulaGraph for graph-based recommendation data.

This runbook documents the Community NebulaGraph BR (Backup & Restore) procedure for backing up the `shopstack` NebulaGraph cluster to S3-compatible object storage such as MinIO.

Current lab cluster:

- Namespace: `data`
- NebulaCluster: `shopstack-nebula`
- NebulaGraph version: `v3.8.0`
- graphd replicas: 1
- metad replicas: 1
- storaged replicas: 2
- metad service: `shopstack-nebula-metad-headless.data.svc.cluster.local:9559`
- target backup bucket: `shopstack-backups`
- target prefix: `nebula`

The object-storage target is provided by Task 7 MinIO.

---

## 1. Community BR behaviour

NebulaGraph BR is a command-line backup and restore tool.

Community BR supports:

- full cluster backup
- backup of selected spaces
- local storage
- S3-compatible storage such as MinIO

Important operational characteristics:

- backup temporarily blocks DDL and DML writes while snapshots are created
- restore is an offline operation
- incremental backup is not supported by Community BR
- backup should be stored outside the NebulaGraph data PVCs
- S3-compatible storage is preferred over node-local storage for recoverability

---

## 2. Prerequisites

Before running BR:

1. The NebulaGraph cluster must be healthy.
2. `SHOW HOSTS` must report the required storaged hosts as `ONLINE`.
3. `SHOW SPACES` must list `shopstack`.
4. `nebula-agent` must be running on each NebulaGraph cluster host required by BR.
5. BR CLI must be able to reach metad on port 9559.
6. The MinIO `shopstack-backups` bucket must exist.
7. Use a dedicated MinIO service account with access only to the required backup bucket/prefix.
8. Do not commit MinIO access keys or secret keys to Git.

---

## 3. Verify NebulaGraph before backup

Using Nebula Console:

~~~ngql
SHOW HOSTS;
SHOW SPACES;
~~~

Verify application data before backup:

~~~ngql
USE shopstack;
MATCH (p:product)
RETURN id(p) AS product_id, p.product.name AS product
ORDER BY product_id;
~~~

The current Task 6 dataset should contain five products.

---

## 4. Install or build Community BR

Obtain Community BR from the official repository:

~~~bash
git clone https://github.com/vesoft-inc/nebula-br.git
cd nebula-br
make
~~~

Verify the binary:

~~~bash
bin/br version
~~~

In a production workflow, use an approved pinned release or internally built image rather than compiling an unpinned branch during a recovery event.

---

## 5. Configure S3-compatible credentials

Do not place credentials directly in repository files.

Load the MinIO credentials into the execution environment or inject them from a Kubernetes Secret.

Example environment variables:

~~~bash
export BR_S3_ACCESS_KEY='<ACCESS_KEY>'
export BR_S3_SECRET_KEY='<SECRET_KEY>'
~~~

Example MinIO endpoint inside Kubernetes:

~~~text
http://minio.storage.svc.cluster.local:9000
~~~

Target backup URI:

~~~text
s3://shopstack-backups/nebula/
~~~

---

## 6. Perform a full backup

Run BR from a host or pod that can reach the NebulaGraph metad service and MinIO:

~~~bash
br backup full \
  --meta "shopstack-nebula-metad-headless.data.svc.cluster.local:9559" \
  --storage "s3://shopstack-backups/nebula/" \
  --s3.endpoint "http://minio.storage.svc.cluster.local:9000" \
  --s3.access_key "${BR_S3_ACCESS_KEY}" \
  --s3.secret_key "${BR_S3_SECRET_KEY}" \
  --s3.region "default"
~~~

BR creates a backup name similar to:

~~~text
BACKUP_YYYY_MM_DD_HH_MM_SS
~~~

Record the generated backup name in the change or incident record.

---

## 7. List and verify backups

List available backups:

~~~bash
br show \
  --storage "s3://shopstack-backups/nebula/" \
  --s3.endpoint "http://minio.storage.svc.cluster.local:9000" \
  --s3.access_key "${BR_S3_ACCESS_KEY}" \
  --s3.secret_key "${BR_S3_SECRET_KEY}" \
  --s3.region "default"
~~~

Confirm that the new backup appears and includes the expected ShopStack data.

Also verify the backup objects in MinIO with the MinIO client:

~~~bash
mc ls --recursive shopstack/shopstack-backups/nebula/
~~~

Replace the `shopstack` alias with the configured MinIO client alias.

---

## 8. Restore procedure

Restore is an offline and disruptive operation.

Before restoring:

1. announce a maintenance window;
2. stop application writes to NebulaGraph;
3. confirm the required backup name;
4. confirm `nebula-agent` is available;
5. confirm the target cluster topology is compatible with the backup;
6. verify access to the S3-compatible backup location.

List backups:

~~~bash
br show \
  --storage "s3://shopstack-backups/nebula/" \
  --s3.endpoint "http://minio.storage.svc.cluster.local:9000" \
  --s3.access_key "${BR_S3_ACCESS_KEY}" \
  --s3.secret_key "${BR_S3_SECRET_KEY}" \
  --s3.region "default"
~~~

Restore the selected backup:

~~~bash
br restore full \
  --meta "shopstack-nebula-metad-headless.data.svc.cluster.local:9559" \
  --storage "s3://shopstack-backups/nebula/" \
  --s3.endpoint "http://minio.storage.svc.cluster.local:9000" \
  --s3.access_key "${BR_S3_ACCESS_KEY}" \
  --s3.secret_key "${BR_S3_SECRET_KEY}" \
  --s3.region "default" \
  --name "<BACKUP_NAME>"
~~~

Do not run restore casually against a healthy production cluster.

---

## 9. Post-restore verification

After restore and after NebulaGraph services return to Ready:

~~~ngql
SHOW HOSTS;
SHOW SPACES;
~~~

Verify the ShopStack graph:

~~~ngql
USE shopstack;

MATCH (p:product)
RETURN id(p) AS product_id, p.product.name AS product
ORDER BY product_id;
~~~

Verify the required 2-hop recommendation query:

~~~ngql
USE shopstack;

MATCH (p1:product)<-[:bought]-(c:customer)-[:bought]->(p2:product)
WHERE id(p1) == "p001" AND id(p2) != "p001"
RETURN DISTINCT id(p2) AS product_id,
                p2.product.name AS recommended_product;
~~~

The restore is not considered successful until both service health and application-level graph queries pass.

---

## 10. Backup cleanup

BR can remove failed or obsolete backup data with its cleanup command.

Example:

~~~bash
br cleanup \
  --meta "shopstack-nebula-metad-headless.data.svc.cluster.local:9559" \
  --storage "s3://shopstack-backups/nebula/" \
  --s3.endpoint "http://minio.storage.svc.cluster.local:9000" \
  --s3.access_key "${BR_S3_ACCESS_KEY}" \
  --s3.secret_key "${BR_S3_SECRET_KEY}" \
  --name "<BACKUP_NAME>"
~~~

Do not delete backups until retention and restore requirements have been checked.

---

## 11. Production considerations

- Store backup credentials in Kubernetes Secrets or an external secret manager.
- Use least-privilege object-storage credentials.
- Keep backups outside the NebulaGraph PVCs.
- Enable bucket versioning and lifecycle controls where appropriate.
- Monitor failed backup jobs and storage capacity.
- Schedule regular restore drills.
- Document the cluster topology associated with each backup.
- Treat restore as an offline maintenance operation.
- Prefer S3-compatible shared storage over node-local backup paths.

Task 7 will provide the MinIO object-storage target for this procedure.
