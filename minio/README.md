# Task 7 MinIO Evidence

This directory contains the declarative MinIO resources and policy artifacts used for Task 7.

## Deployment

Tracked manifests:

- `namespace.yaml`
- `pvc.yaml`
- `deployment.yaml`
- `service.yaml`

Runtime namespace:

```text
storage
```

Runtime root credentials were stored in:

```text
Secret/storage/minio-root-credentials
```

Credential values are intentionally not committed to Git.

The MinIO deployment used a 5 GiB RWO PVC backed by the lab `local-path` StorageClass.

## Buckets

The following buckets were created and verified with `mc`:

```text
shopstack-images
shopstack-backups
```

Normal object upload/download was verified against `shopstack-images`.

Presigned download and presigned upload were also verified successfully.

## Application Policy

Policy file:

```text
shopstack-images-rw-policy.json
```

The application service account was allowed to:

```text
ListBucket
GetBucketLocation
GetObject
PutObject
DeleteObject
```

only for:

```text
shopstack-images
shopstack-images/*
```

Positive test:

```text
APP IMAGES READ/WRITE PASS
```

Negative tests against `shopstack-backups` returned:

```text
Access Denied
EXPECTED DENY: backups list blocked
EXPECTED DENY: backups write blocked
CONFIRMED: denied object does not exist
```

The runtime application credentials were stored in:

```text
Secret/shopstack/minio-app-credentials
```

and are not committed.

## PostgreSQL Backup Policy

Policy file:

```text
shopstack-backups-rw-policy.json
```

The dedicated PostgreSQL backup identity was granted:

```text
ListBucket
GetBucketLocation
GetObject
PutObject
```

for `shopstack-backups`, deliberately without object-delete permission.

Runtime credentials were stored in:

```text
Secret/shopstack/minio-backup-credentials
```

and are not committed.

## PostgreSQL Backup CronJob

The updated CronJob is tracked at:

```text
../data/postgres-backup-cronjob.yaml
```

The Job contains:

```text
pg-dump
minio-upload
```

The successfully uploaded PostgreSQL backup object was:

```text
shopstack-backups/boutique-20260920T092242Z.dump
```

A real restore was performed from the MinIO object copy:

```text
original_rows=5
restored_rows=5
OBJECT RESTORE VERIFIED
```

The production database remained intact after the temporary restore database was removed.

## Versioning Proof

Versioning was enabled on:

```text
shopstack-backups
```

Test object:

```text
task7-versioning-proof.txt
```

Observed version history:

```text
v1  fdf22ff9-4674-422b-b956-ec93c11fe74d  Task 7 backup version ONE
v2  d57d7311-f604-4ecf-bdce-6cfffb1f37cd  Task 7 backup version TWO
v3  2c5949c2-7ed0-42fe-9e17-baf975d6aa85  Task 7 backup version ONE
```

The original v1 was retrieved explicitly by version ID:

```text
PREVIOUS VERSION RETRIEVED
```

and then restored as the current version:

```text
PREVIOUS VERSION RESTORED AS CURRENT
```

## Lifecycle

A lifecycle rule was enabled for:

```text
NoncurrentVersionExpiration = 7 days
```

This keeps recent historical versions available for recovery while automatically expiring older non-current versions.

## Istio Console Evidence

MinIO Console is exposed through:

```text
minio.shopstack.local
```

using:

```text
../istio/minio-virtualservice.yaml
../istio/gateway.yaml
```

Screenshot evidence:

```text
../docs/evidence/task7/minio-console-bucket-browser.png
```

The screenshot shows the `shopstack-backups` bucket containing:

```text
boutique-20260920T092242Z.dump
task7-versioning-proof.txt
```

For full commands, troubleshooting history, and checkpoint answers, see the Task 7 section of `../journal.md`.
