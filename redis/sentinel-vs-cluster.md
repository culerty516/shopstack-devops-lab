# Redis Sentinel vs Redis Cluster

## Redis Sentinel

Redis Sentinel provides high availability for a primary-replica Redis deployment.

Sentinel monitors the Redis primary and replicas, detects failures, coordinates failover, promotes a replica to become the new primary, and informs clients about the current primary.

In the ShopStack Task 6 Final Run, three Redis Sentinel instances were deployed with a quorum of two.

The initial topology was:

~~~text
redis-ha-0  -> primary
redis-ha-1  -> replica
redis-ha-2  -> replica
~~~

The initial primary was deliberately stopped. Sentinel detected the failure, reached objective-down quorum, elected a Sentinel leader, selected a replica, promoted `redis-ha-1`, and switched the monitored primary to the new Redis node.

After `redis-ha-0` returned, it was automatically reconfigured as a replica of the new primary.

Sentinel is suitable when the main requirement is high availability for a Redis dataset without distributing that dataset across multiple Redis shards.

## Redis Cluster

Redis Cluster provides both high availability and horizontal data partitioning.

Instead of storing the complete dataset on one primary and its replicas, Redis Cluster divides the Redis keyspace into hash slots and distributes those slots across multiple primary nodes.

Each primary can also have replicas for failover.

This allows Redis Cluster to scale data capacity and write throughput beyond a single Redis primary, but it introduces additional operational and application complexity.

Applications and Redis clients must be cluster-aware because a key may be owned by a different cluster node.

## Comparison

| Area | Redis Sentinel | Redis Cluster |
| --- | --- | --- |
| Primary purpose | High availability | High availability and horizontal scaling |
| Data distribution | Full dataset remains on the primary and replicas | Dataset is sharded across multiple primaries |
| Automatic failover | Yes | Yes |
| Horizontal write scaling | No | Yes |
| Client requirements | Client should support Sentinel discovery | Client must be Redis Cluster aware |
| Operational complexity | Lower | Higher |
| Typical use case | Dataset fits on one Redis primary but requires HA | Dataset or throughput requires multiple Redis primaries |

## ShopStack lab choice

Redis Sentinel was selected for the Task 6 high-availability exercise because the objective was to demonstrate primary failure detection and automatic failover rather than horizontal Redis sharding.

The three-Sentinel setup used a quorum of two so that a single Sentinel could not independently declare the primary objectively down and authorize a failover.

The Final Run demonstrated that:

- all three Sentinels discovered each other;
- quorum and failover authorization were available;
- a replicated proof value existed before failure;
- the original primary was deliberately stopped;
- Sentinel detected subjective and objective failure;
- a replica was promoted to primary;
- the proof value survived the failover;
- the original primary later rejoined as a replica; and
- the final topology returned to one primary with two replicas.
