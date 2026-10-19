# Redis Cache-Aside Pattern

## ShopStack example

The Task 6 exercise demonstrated the cache-aside pattern using product `SKU-002`.

The flow was:

1. Check Redis for `product:SKU-002`.
2. If Redis returns no value, treat it as a cache miss.
3. Query PostgreSQL for the product.
4. Write the PostgreSQL result into Redis with a TTL.
5. Subsequent requests can use the cached Redis value until it expires.

Example logic:

~~~text
GET product:SKU-002

if cache hit:
    return cached product

if cache miss:
    query PostgreSQL
    SET product:SKU-002 <product-data> EX 300
    return database result
~~~

During the cache-aside demonstration, the first Redis lookup was a cache miss.

PostgreSQL returned:

~~~text
SKU-002|Keyboard|electronics|699.00
~~~

The value was cached with a 300-second TTL. A subsequent Redis lookup returned the cached value, and the observed TTL was 282 seconds.

## Failure mode 1 — Cache stampede

A cache stampede can occur when a popular key expires and many requests miss the cache simultaneously. Those requests may all query PostgreSQL at the same time, creating a sudden load spike.

One mitigation is request coalescing or a distributed lock so that only one request refreshes the cache while other requests wait for the refreshed value.

## Failure mode 2 — Stale data

Redis can contain an older product value after PostgreSQL has been updated.

One mitigation is to invalidate or update the corresponding Redis key after a successful PostgreSQL write. TTLs also limit how long stale values can remain cached.
