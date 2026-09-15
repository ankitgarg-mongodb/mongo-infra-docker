# Monitoring Agent OTel Metrics

The monitoring agent can export metrics to OpenTelemetry (OTel) backends in parallel with its existing Ops Manager emission. Both paths consume the same collected samples, and the OTel side never affects OM emission — failures there are logged and swallowed.

## Reading the tables

**Kind** is the OTel instrument, chosen by the nature of the source data:

- `Counter` — monotonic Sum of a value that only increases since server start (opcounters, bytes, latency totals). Prometheus renders these with the `_total` suffix and `rate()`/delta tooling applies reset detection automatically.
- `UpDownCounter` — non-monotonic Sum of a point-in-time value (connections, cache bytes, ticket counts).
- `Gauge` — instantaneous sampled value (health, oplog window, agent goroutines).

**Unit** uses OTel/UCUM conventions: `By` for bytes, `ms`, `us`, `s` for time, `1` for unitless ratios, and `{operations}`-style bracketed annotation units for counts. Where MongoDB's native unit differs from the declared unit, the recorder converts at emit time (conversions noted per metric).

**Dimensions** are attribute keys stamped on every data point of the metric, splitting it into one series per unique combination of dimension values (labels, in Prometheus terms).

**Source** names where the numbers come from: the MongoDB command or runtime snapshot the signal collects, and the exact field of its output that feeds the metric. The same sample is teed to OM and OTel, so a value seen in the command's output corresponds to the metric emitted from it.

**Category** is the naming lineage, which tells you where a metric's name, kind and unit come from:

- Receiver-aligned — matches the OpenTelemetry Collector's `mongodbreceiver` (`metadata.yaml`) exactly, so dashboards built for the receiver work against this output unchanged.
- Receiver-style — no receiver equivalent exists, so the metric is named in the receiver's style under bare `mongodb.*`.
- Vendor namespace — agent self-health under `mongodb.mms.*`, since the agent itself is the subject.

## Attributes

### Resource-level

Each monitored process exports under its own resource so backends can address individual `mongod`/`mongos` processes independently. Every resource, the agent's and each process's, is built on the same deployment-identity base (`service.name`, `service.namespace`, `service.version`, `mms.group_id`): the base is merged into each per-process resource, so those attributes appear on both scopes.

| Attribute | Scope | Description |
|---|---|---|
| `service.name` | agent + process | Always `mongodb-agent` |
| `service.namespace` | agent + process | Always `mongodb.mms` |
| `service.version` | agent + process | Agent build version |
| `mms.group_id` | agent + process | OM group/project the agent serves |
| `service.instance.id` | agent + process | Deterministic UUID v5. For the agent, derived from `hostname/groupID`. For each process, derived from `hostname:port` under the same namespace UUID the receiver uses, so values match receiver output |
| `server.address`, `server.port` | process | Hostname and port of the monitored process |
| `mongodb.process_type` | process | `mongod` or `mongos`, corrected per status sample |
| `mongodb.replica_set` | process | Replica set name, when applicable |
| `mongodb.version` | process | MongoDB server version from buildInfo, persisted across samples |
| `process.pid`, `process.runtime.*`, `host.*` | agent | Standard semconv detectors, populated on the agent's own resource only. Per-process resources are built from attributes alone, so they carry no process/host detector output |

### Point-level (dimensions)

Point-level dimensions (on individual metric data points):

| Attribute | Used by | Values |
|---|---|---|
| `operation` | opcounters, document operations, latency, operation time | `insert`, `query`, `update`, `delete`, `getmore`, `command` (latency uses `read`, `write`, `command`) |
| `type` | connections, memory, cache operations, tickets, queue depth, asserts, scanned targets, agent memory | Value set depends on the metric, see the tables above |
| `lock_type` | lock metrics | `global`, `database`, `collection`, `mutex`, `metadata`, `oplog`, `parallel_batch_write_mode`, `replication_state_transition` |
| `lock_mode` | lock metrics | `intent_shared` (r), `intent_exclusive` (w), `shared` (R), `exclusive` (W) |
| `db.namespace` | dbStats, sharded chunks | Database or namespace name |
| `mongodb.wt.log.operation.type` | `mongodb.wt.log.operation.count` | `write`, `sync`, `flush` |
| `mongodb.wt.concurrent_transaction.ticket.type` | `mongodb.wt.concurrent_transaction.ticket.in_use` | `read`, `write` |
| `mongodb.shard` | sharded chunk metrics | Shard name |
| `mongodb.member` | replication metrics | Member `host:port` |

One further attribute, `mms.host_ref`, exists internally on every point to identify the monitored process it came from. The export loop resolves it to that process's resource and strips it, so it never reaches the wire.

## Metric inventory

### serverStatus core (receiver-aligned)

`serverStatus` is MongoDB's built-in self-report of one server's live state, returned as a single snapshot: operation counters, connections, memory, network traffic, and storage-engine internals. The status monitor collects it from every monitored process, and the OM status ping ingests the same sample. This group is the receiver-aligned core of that snapshot — the signals dashboards built for the receiver expect.

Source: the `serverStatus` command. Emitted once per monitored process on each status collection cycle.

| Metric | Kind | Unit | Dimensions | Source | Description |
|---|---|---|---|---|---|
| `mongodb.operation.count` | Counter | `{operations}` | `operation` | `opcounters` | Operations executed, by type: `insert`, `query`, `update`, `delete`, `getmore`, `command` |
| `mongodb.operation.repl.count` | Counter | `{operations}` | `operation` | `opcountersRepl` | Replicated operations executed, by the same operation types |
| `mongodb.global_lock.time` | Counter | `ms` | — | `globalLock.totalTime` | Time the global lock has been held. Converted from microseconds |
| `mongodb.page_faults` | Counter | `{faults}` | — | `extra_info.page_faults` | Page faults |
| `mongodb.uptime` | Counter | `ms` | — | `uptimeMillis` | Time the server has been running |
| `mongodb.cache.operations` | Counter | `{operations}` | `type` | `wiredTiger.cache` | Cache operations: `miss` is pages read into cache, `hit` is pages requested minus pages read into cache. WiredTiger only |
| `mongodb.wtcache.bytes.read` | Counter | `By` | — | `wiredTiger.cache "bytes read into cache"` | Bytes read into the WiredTiger cache. WiredTiger only |
| `mongodb.wt.log.write` | Counter | `By` | — | `wiredTiger.log "log bytes written"` | Bytes written to the WiredTiger journal. WiredTiger only |
| `mongodb.wt.log.operation.count` | Counter | `{operation}` | `mongodb.wt.log.operation.type` | `wiredTiger.log` | Journal operations: `write`, `sync`, `flush`. WiredTiger only |
| `mongodb.wt.log.sync.time` | Counter | `s` | — | `wiredTiger.log "log sync time duration (usecs)"` | Cumulative time spent syncing the journal. Converted from microseconds |
| `mongodb.wt.fsync.count` | Counter | `{fsync}` | — | `wiredTiger.connection "total fsync I/Os"` | fsync I/Os issued by the storage engine. WiredTiger only |
| `mongodb.lock.acquire.count` | Counter | `{count}` | `lock_type`, `lock_mode` | `locks.*.acquireCount` | Lock acquisitions, by lock type and mode |
| `mongodb.lock.acquire.time` | Counter | `us` | `lock_type`, `lock_mode` | `locks.*.timeAcquiringMicros` | Cumulative wait time for lock acquisitions |
| `mongodb.lock.acquire.wait_count` | Counter | `{count}` | `lock_type`, `lock_mode` | `locks.*.acquireWaitCount` | Acquisitions that encountered waits in a conflicting mode |
| `mongodb.lock.deadlock.count` | Counter | `{count}` | `lock_type`, `lock_mode` | `locks.*.deadlockCount` | Acquisitions that encountered deadlocks |
| `mongodb.cursor.timeout.count` | Counter | `{cursors}` | — | `metrics.cursor.timedOut` | Cursors that have timed out |
| `mongodb.document.operation.count` | Counter | `{documents}` | `operation` | `metrics.document` | Document operations: `insert`, `update`, `delete` |
| `mongodb.network.io.receive` | Counter | `By` | — | `network.physicalBytesIn`, falling back to `bytesIn` | Bytes received. Prefers the post-compression physical count when the server reports it |
| `mongodb.network.io.transmit` | Counter | `By` | — | `network.physicalBytesOut`, falling back to `bytesOut` | Bytes transmitted, with the same physical-first preference |
| `mongodb.network.request.count` | Counter | `{requests}` | — | `network.numRequests` | Requests received by the server |
| `mongodb.operation.latency.time` | Counter | `us` | `operation` | `opLatencies` | Cumulative operation latency, by `read`, `write`, `command`. Emitted only when the server reports opLatencies |
| `mongodb.connection.count` | UpDownCounter | `{connections}` | `type` | `connections` | Connections: `active`, `available`, `current` |
| `mongodb.memory.usage` | UpDownCounter | `By` | `type` | `mem` | Memory usage: `resident` and `virtual`. Converted from MiB |
| `mongodb.cursor.count` | UpDownCounter | `{cursors}` | — | `metrics.cursor.open.total` | Open cursors maintained for clients |
| `mongodb.session.count` | UpDownCounter | `{sessions}` | — | `wiredTiger.session "open session count"` | Active WiredTiger sessions. WiredTiger only |
| `mongodb.wt.concurrent_transaction.ticket.in_use` | UpDownCounter | `{ticket}` | `mongodb.wt.concurrent_transaction.ticket.type` | `queues.execution.*.out` on 8.0+, `wiredTiger.concurrentTransactions.*.out` on 6.0–7.x | In-flight read/write concurrency tickets. Emitted only when the server reports ticket occupancy |
| `mongodb.active.reads` | UpDownCounter | `{reads}` | — | `globalLock.activeClients.readers` | Read operations currently being processed |
| `mongodb.active.writes` | UpDownCounter | `{writes}` | — | `globalLock.activeClients.writers` | Write operations currently being processed |
| `mongodb.health` | Gauge | `1` | — | `ok` | Server health: 1 when `ok` is exactly 1, 0 otherwise. Emitted only when `ok` is present |

Lock metrics map MongoDB's internal lock names to wire values: lock types `Global`, `Database`, `Collection`, `Mutex`, `Metadata`, `oplog`, `ParallelBatchWriterMode`, `ReplicationStateTransition`, and lock modes `r` (intent_shared), `w` (intent_exclusive), `R` (shared), `W` (exclusive). Lock keys with no mapping are skipped rather than invented.

### serverStatus extras (receiver-style)

The other half of the same snapshot — fields OM has long ingested but the receiver does not model, such as ticket availability, queue depth and query-executor counters.

Source: same serverStatus sample.

| Metric | Kind | Unit | Dimensions | Source | Description |
|---|---|---|---|---|---|
| `mongodb.ticket.available` | UpDownCounter | `{tickets}` | `type` | `queues.execution.*.available` on 8.0+, `wiredTiger.concurrentTransactions.*.available` on 6.0–7.x | Available read/write concurrency (ticket) slots |
| `mongodb.global_lock.current_queue.count` | UpDownCounter | `{operations}` | `type` | 8.0+: `queues.execution.*.normalPriority.queueLength`. 7.0+: `wiredTiger.concurrentTransactions.*.queueLength`. 6.0: derived as `currentQueue + activeClients − tickets out`, clamped at 0 | Operations queued waiting for a read/write execution ticket |
| `mongodb.wtcache.bytes.used` | UpDownCounter | `By` | — | `wiredTiger.cache "bytes currently in the cache"` | Bytes currently held in the WiredTiger cache |
| `mongodb.wtcache.bytes.dirty` | UpDownCounter | `By` | — | `wiredTiger.cache "tracked dirty bytes in the cache"` | Dirty bytes in the WiredTiger cache |
| `mongodb.wtcache.bytes.written` | Counter | `By` | — | `wiredTiger.cache "bytes written from cache"` | Bytes written from the WiredTiger cache |
| `mongodb.wtcache.bytes.total` | UpDownCounter | `By` | — | `wiredTiger.cache "maximum bytes configured"` | WiredTiger cache capacity. Changes only on reconfigure |
| `mongodb.assert.count` | Counter | `{asserts}` | `type` | `asserts` | Asserts raised since server start: `regular`, `warning`, `msg`, `user` |
| `mongodb.query_executor.scanned.count` | Counter | `{scanned}` | `type` | `metrics.queryExecutor` | Scanned targets: `index` items and `document` objects |
| `mongodb.operation.scan_and_order.count` | Counter | `{operations}` | — | `metrics.operation.scanAndOrder` | Queries that performed an in-memory sort |
| `mongodb.operation.killed.count` | Counter | `{operations}` | — | `metrics.operation.killedDueToMaxTimeMSExpired` | Operations killed on maxTimeMS expiry |
| `mongodb.ttl.deleted.count` | Counter | `{documents}` | — | `metrics.ttl.deletedDocuments` | Documents deleted by TTL monitors |
| `mongodb.document.returned.count` | Counter | `{documents}` | — | `metrics.document.returned` | Documents returned by queries |
| `mongodb.operation.latency.count` | Counter | `{operations}` | `operation` | `opLatencies.*.ops` | Operations counted toward operation latency, by `read`, `write`, `command` |
| `mongodb.flow_control.time` | Counter | `us` | — | `flowControl.timeAcquiringMicros` | Cumulative time spent acquiring flow-control tickets |
| `mongodb.connection.created.count` | Counter | `{connections}` | — | `connections.totalCreated` | Connections created since server start |

### Replication and oplog (receiver-style)

Replica set health and oplog state: which members exist, their state and health, how far each lags the primary, and how much oplog headroom remains. Collected from replication-specific commands alongside the status signal.

Source: `replSetGetStatus`, the oplog `rsStats` collected with the status signal, and `serverStatus.oplog`. Emitted per monitored replica set member where applicable.

| Metric | Kind | Unit | Dimensions | Source | Description |
|---|---|---|---|---|---|
| `mongodb.oplog.size` | UpDownCounter | `By` | — | `rsStats.maxSize` | Maximum oplog size, the capped-collection limit. Omitted when rsStats is unavailable |
| `mongodb.oplog.used.size` | UpDownCounter | `By` | — | `rsStats.size` | Current size of stored oplog data |
| `mongodb.oplog.window.time` | Gauge | `s` | — | `serverStatus.oplog` earliest/latest optimes | Seconds between the oldest and newest oplog entries. A measured window of 0 is emitted as 0, not omitted |
| `mongodb.replication.lag.time` | Gauge | `s` | `mongodb.member` | `replSetGetStatus.members` | Seconds the member is behind the primary's optime. 0 for the primary, and for all members while no primary exists, e.g. during an election |
| `mongodb.replication.member.health` | Gauge | `1` | `mongodb.member` | `replSetGetStatus.members` | 1 healthy, 0 unhealthy, as reported by the server |
| `mongodb.replication.member.state` | Gauge | `1` | `mongodb.member` | `replSetGetStatus.members` | Numeric replica set state code, e.g. 1 = PRIMARY, 2 = SECONDARY. See MongoDB's replica-set member states reference |

### dbStats (per database)

Storage and document statistics per database: how many collections, indexes and documents it holds, and how much space the data and its indexes occupy. Collected for each database the dbStats monitor covers.

Source: the `dbStats` command, plus the count of monitored databases.

| Metric | Kind | Unit | Dimensions | Source | Description |
|---|---|---|---|---|---|
| `mongodb.collection.count` | UpDownCounter | `{collections}` | `db.namespace` | `dbStats.collections` | Number of collections in the database |
| `mongodb.data.size` | UpDownCounter | `By` | `db.namespace` | `dbStats.dataSize` | Size of the collection data, unaffected by compression |
| `mongodb.storage.size` | UpDownCounter | `By` | `db.namespace` | `dbStats.storageSize` | Storage allocated to the collections |
| `mongodb.object.count` | UpDownCounter | `{objects}` | `db.namespace` | `dbStats.objects` | Number of documents (objects) |
| `mongodb.index.count` | UpDownCounter | `{indexes}` | `db.namespace` | `dbStats.indexes` | Number of indexes |
| `mongodb.index.size` | UpDownCounter | `By` | `db.namespace` | `dbStats.indexSize` | Space allocated to all indexes, including free index space |
| `mongodb.view.count` | UpDownCounter | `{views}` | `db.namespace` | `dbStats.views` | Number of views. No receiver equivalent |
| `mongodb.database.count` | UpDownCounter | `{databases}` | — | count of monitored databases | Databases covered by the dbStats signal, reported once per host. Note this is the monitored set, not an unfiltered `listDatabases` |

### Operation time (from top)

How much execution time the server has spent on each operation type, aggregated across every collection. The `top` admin command reports per-collection time sums, which are totalled per operation before emission.

Source: the `top` admin command.

| Metric | Kind | Unit | Dimensions | Source | Description |
|---|---|---|---|---|---|
| `mongodb.operation.time` | Counter | `ms` | `operation` | `top.totals.<coll>.<op>.time` | Total time spent performing operations, by `insert`, `query`, `update`, `delete`, `getmore`, `command`. Converted from microseconds. Skipped entirely when no collection decodes, so zeros never read as a counter reset |

### Sharded cluster distribution (receiver-style)

How a sharded collection's data is spread across the cluster: chunks, owned and orphaned data sizes, and document counts per shard. Collected from the cluster's `mongos`, whose sharded data distribution view exposes the placement the balancer maintains.

Source: the sharded namespace metrics signal. One series per (host, shard, namespace) combination.

| Metric | Kind | Unit | Dimensions | Source | Description |
|---|---|---|---|---|---|
| `mongodb.shard.chunk.count` | UpDownCounter | `{chunks}` | `mongodb.shard`, `db.namespace` | shard chunk counts | Chunks of the namespace owned by the shard |
| `mongodb.shard.size.owned` | UpDownCounter | `By` | `mongodb.shard`, `db.namespace` | sharded data distribution | Owned data size |
| `mongodb.shard.size.orphaned` | UpDownCounter | `By` | `mongodb.shard`, `db.namespace` | sharded data distribution | Orphaned data size |
| `mongodb.shard.documents.owned` | UpDownCounter | `{documents}` | `mongodb.shard`, `db.namespace` | sharded data distribution | Owned document count |
| `mongodb.shard.documents.orphaned` | UpDownCounter | `{documents}` | `mongodb.shard`, `db.namespace` | sharded data distribution | Orphaned document count |

### Agent self-health (vendor namespace)

The monitoring agent's own vitals — uptime, goroutine count and Go heap memory. They measure the exporter process rather than MongoDB, so they carry no host attributes and export under the agent's own resource.

Source: the agent's own stats snapshot plus the Go runtime. They go out every export cycle, excluded from the budget rotation described below.

| Metric | Kind | Unit | Dimensions | Source | Description |
|---|---|---|---|---|---|
| `mongodb.mms.agent.uptime` | Gauge | `s` | — | agent GlobalStats uptime | Time since the monitoring agent process started. A restart reports the new, lower lifetime |
| `mongodb.mms.agent.goroutine.count` | Gauge | `{goroutines}` | — | `runtime.NumGoroutine()` | Goroutines currently running in the agent |
| `mongodb.mms.agent.memory.usage` | Gauge | `By` | `type` | `runtime.MemStats` | Go heap memory: `heap_allocated` (HeapAlloc) and `heap_in_use` (HeapInuse) |