# Elasticsearch Snapshot and Restore Runbook

## Purpose

ShopStack uses Elasticsearch for product search. This runbook documents how to back up and restore Elasticsearch snapshots to S3-compatible object storage.

The current Task 6 lab does not yet provide an object store. Task 7 deploys MinIO and creates the `shopstack-backups` bucket, so that bucket is the intended snapshot repository.

The Elasticsearch cluster is managed by ECK:

- Namespace: `data`
- Elasticsearch resource: `shopstack`
- HTTP service: `shopstack-es-http`
- Snapshot repository name: `shopstack-backups`
- Object-storage bucket: `shopstack-backups`
- Base path: `elasticsearch`

Do not store S3 access keys directly in the Elasticsearch manifest.

---

## 1. Create Kubernetes Secret for S3 credentials

Create a Secret containing the S3-compatible access key and secret key.

Example:

~~~bash
kubectl create secret generic elasticsearch-s3-credentials \
  -n data \
  --from-literal=s3.client.default.access_key='<ACCESS_KEY>' \
  --from-literal=s3.client.default.secret_key='<SECRET_KEY>'
~~~

The literal values must come from the MinIO service account created in Task 7.

Do not commit plaintext credentials to Git.

---

## 2. Attach secure settings to the ECK Elasticsearch resource

Add the Secret under `spec.secureSettings`:

~~~yaml
spec:
  secureSettings:
    - secretName: elasticsearch-s3-credentials
~~~

Configure the S3-compatible endpoint in the Elasticsearch node configuration.

Example for MinIO:

~~~yaml
spec:
  nodeSets:
    - name: default
      config:
        s3.client.default.endpoint: minio.storage.svc.cluster.local:9000
        s3.client.default.protocol: http
        s3.client.default.path_style_access: true
~~~

Preserve all existing Elasticsearch settings, JVM heap settings, resource limits, node placement, and PVC configuration when adding these values.

Apply the updated ECK manifest and wait until Elasticsearch returns to Ready.

---

## 3. Verify Elasticsearch connectivity

Retrieve the ECK-generated `elastic` password from the Kubernetes Secret and load it into the temporary client environment without committing it to Git.

From a temporary curl pod inside the cluster, verify Elasticsearch:

~~~bash
curl -sk \
  -u "elastic:${ELASTIC_PASSWORD}" \
  https://shopstack-es-http.data.svc:9200/_cluster/health
~~~

---

## 4. Register the snapshot repository

Register the MinIO bucket as an S3 repository:

~~~http
PUT _snapshot/shopstack-backups
{
  "type": "s3",
  "settings": {
    "bucket": "shopstack-backups",
    "base_path": "elasticsearch",
    "compress": true
  }
}
~~~

Expected response:

~~~json
{
  "acknowledged": true
}
~~~

---

## 5. Verify repository configuration

~~~http
GET _snapshot/shopstack-backups
~~~

Then verify that Elasticsearch can access the repository:

~~~http
POST _snapshot/shopstack-backups/_verify
~~~

The verification must succeed before relying on the repository for backups.

---

## 6. Create a snapshot

Create a named snapshot:

~~~http
PUT _snapshot/shopstack-backups/shopstack-manual-001?wait_for_completion=true
{
  "indices": "products",
  "include_global_state": false
}
~~~

Verify the snapshot:

~~~http
GET _snapshot/shopstack-backups/shopstack-manual-001
~~~

Confirm that:

- snapshot state is `SUCCESS`
- the `products` index is included
- failed shard count is zero

---

## 7. List available snapshots

~~~http
GET _snapshot/shopstack-backups/_all
~~~

Use this before any restore to confirm the required snapshot exists.

---

## 8. Restore procedure

Restoring an index with the same name requires the existing index to be removed or renamed first.

Confirm the snapshot exists:

~~~http
GET _snapshot/shopstack-backups/shopstack-manual-001
~~~

Delete only the index being restored:

~~~http
DELETE products
~~~

Restore it:

~~~http
POST _snapshot/shopstack-backups/shopstack-manual-001/_restore
{
  "indices": "products",
  "include_global_state": false
}
~~~

Monitor recovery:

~~~http
GET _cat/recovery/products?v
~~~

Check cluster health:

~~~http
GET _cluster/health
~~~

Verify document count:

~~~http
GET products/_count
~~~

The expected ShopStack Task 6 lab count is:

~~~text
10
~~~

---

## 9. Operational considerations

- Store snapshot credentials in Kubernetes Secrets and ECK secure settings, never Git.
- Keep snapshots outside the Elasticsearch data PVC; snapshots on the same disk do not protect against disk loss.
- Verify repositories and perform restore drills regularly.
- Apply object-storage versioning and lifecycle controls to backup data.
- Use unique snapshot names or an automated naming convention.
- Monitor snapshot failures and repository capacity.
- Restrict the MinIO service account to the required backup bucket and prefix.
- A snapshot is not a substitute for high availability: replicas protect availability, while snapshots protect recoverability.
