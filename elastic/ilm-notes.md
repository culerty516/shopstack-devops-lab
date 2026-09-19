# Elasticsearch ILM Notes

## Where ILM matters

Index Lifecycle Management (ILM) is most useful for time-series or log-style data whose volume grows continuously, for example:

- application logs
- access logs
- audit events
- infrastructure logs
- monitoring or metrics indices

These indices normally have predictable lifecycle and retention requirements.

A typical lifecycle may:

1. keep recent data in the hot phase for active searching;
2. roll over to a new index when an age or size threshold is reached;
3. move older data to lower-cost warm or cold storage where appropriate;
4. delete data automatically after the required retention period.

For example, operational logs could roll over daily or after reaching a configured size, then be deleted after 30 or 90 days depending on troubleshooting, audit, and compliance requirements.

## ShopStack products index

The `products` index used in Task 6 is application data rather than log-style time-series data.

Product documents are updated in place and must remain searchable. Automatically ageing them out based only on index age would therefore be inappropriate.

For the `products` index, application-controlled updates and snapshot or restore procedures are more relevant than a log-retention ILM policy.

## Why ILM is operationally useful

Without lifecycle management, log indices can grow indefinitely and eventually consume all available disk space.

ILM makes retention predictable and helps DevOps teams control:

- storage consumption
- shard growth
- search performance
- retention requirements
- storage cost across data tiers

Lifecycle rules should therefore be designed around workload behaviour and retention requirements rather than applied blindly to every Elasticsearch index.
