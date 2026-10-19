# PostgreSQL Restore Runbook

## Scope

This runbook restores the ShopStack `boutique` PostgreSQL database from a logical `pg_dump` backup.

Environment used for the Task 6 restore exercise:

- Namespace: `data`
- PostgreSQL StatefulSet: `postgres`
- PostgreSQL Pod: `postgres-0`
- Database: `boutique`
- Backup format: PostgreSQL custom format (`pg_dump -Fc`)
- Kubernetes credentials: `data/frontend-db-secret`

The PostgreSQL container receives the database username and password through the `POSTGRES_USER` and `POSTGRES_PASSWORD` environment variables sourced from the Kubernetes Secret.

## 1. Create a logical backup

Create a custom-format dump inside the PostgreSQL Pod:

~~~bash
kubectl exec \
  -n data \
  postgres-0 \
  -- sh -c '
    PGPASSWORD="$POSTGRES_PASSWORD" \
    pg_dump \
      -U "$POSTGRES_USER" \
      -d boutique \
      -Fc \
      -f /tmp/boutique.dump
  '
~~~

Verify that the dump exists:

~~~bash
kubectl exec \
  -n data \
  postgres-0 \
  -- ls -lh /tmp/boutique.dump
~~~

Inspect the dump contents:

~~~bash
kubectl exec \
  -n data \
  postgres-0 \
  -- pg_restore -l /tmp/boutique.dump |
grep products
~~~

Generate a checksum inside the cluster:

~~~bash
kubectl exec \
  -n data \
  postgres-0 \
  -- sha256sum /tmp/boutique.dump
~~~

## 2. Copy the backup outside the cluster

Create a local temporary backup directory:

~~~bash
mkdir -p /tmp/shopstack-task6
~~~

Copy the dump from Kubernetes to the local machine:

~~~bash
kubectl cp \
  data/postgres-0:/tmp/boutique.dump \
  /tmp/shopstack-task6/boutique.dump
~~~

Verify the local checksum:

~~~bash
shasum -a 256 /tmp/shopstack-task6/boutique.dump
~~~

The local checksum must match the checksum generated inside the PostgreSQL Pod.

## 3. Disaster drill

Verify the expected row count before the destructive step:

~~~bash
kubectl exec \
  -n data \
  postgres-0 \
  -- sh -c '
    PGPASSWORD="$POSTGRES_PASSWORD" \
    psql \
      -U "$POSTGRES_USER" \
      -d boutique \
      -tAc "SELECT COUNT(*) FROM products;"
  '
~~~

During the Task 6 restore drill, the `products` table contained 5 rows before the destructive step.

Delete the table:

~~~bash
kubectl exec \
  -n data \
  postgres-0 \
  -- sh -c '
    PGPASSWORD="$POSTGRES_PASSWORD" \
    psql \
      -U "$POSTGRES_USER" \
      -d boutique \
      -c "DROP TABLE products;"
  '
~~~

Confirm that the table is unavailable:

~~~bash
kubectl exec \
  -n data \
  postgres-0 \
  -- sh -c '
    PGPASSWORD="$POSTGRES_PASSWORD" \
    psql \
      -U "$POSTGRES_USER" \
      -d boutique \
      -c "SELECT COUNT(*) FROM products;"
  '
~~~

Expected failure:

~~~text
ERROR: relation "products" does not exist
~~~

## 4. Restore from the external backup copy

Copy the verified backup from the local machine back into the PostgreSQL Pod:

~~~bash
kubectl cp \
  /tmp/shopstack-task6/boutique.dump \
  data/postgres-0:/tmp/boutique-restore.dump
~~~

Verify its checksum:

~~~bash
kubectl exec \
  -n data \
  postgres-0 \
  -- sha256sum /tmp/boutique-restore.dump
~~~

Restore the database objects and data:

~~~bash
kubectl exec \
  -n data \
  postgres-0 \
  -- sh -c '
    PGPASSWORD="$POSTGRES_PASSWORD" \
    pg_restore \
      -U "$POSTGRES_USER" \
      -d boutique \
      /tmp/boutique-restore.dump
  '
~~~

## 5. Verify recovery

Confirm that the expected 5 rows have been restored:

~~~bash
kubectl exec \
  -n data \
  postgres-0 \
  -- sh -c '
    PGPASSWORD="$POSTGRES_PASSWORD" \
    psql \
      -U "$POSTGRES_USER" \
      -d boutique \
      -tAc "SELECT COUNT(*) FROM products;"
  '
~~~

Verify the restored records:

~~~bash
kubectl exec \
  -n data \
  postgres-0 \
  -- sh -c '
    PGPASSWORD="$POSTGRES_PASSWORD" \
    psql \
      -U "$POSTGRES_USER" \
      -d boutique \
      -c "SELECT id, sku, name, category, price FROM products ORDER BY id;"
  '
~~~

Confirm that PostgreSQL remains healthy:

~~~bash
kubectl get pod postgres-0 \
  -n data
~~~

Expected state:

~~~text
postgres-0   1/1   Running
~~~

## Recovery Notes

- This procedure is a logical restore using `pg_dump` and `pg_restore`.
- The backup is copied outside the Kubernetes cluster before the destructive drill, so recovery does not depend on data remaining inside the PostgreSQL Pod.
- The backup checksum should be verified before a restore.
- A production recovery process should also define retention, encryption, off-cluster or object-storage replication, and regular restore testing.
