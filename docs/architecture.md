# Architecture

`main.zolo` loads configuration and creates the host. `host.zolo` authorizes
requests and orders operations. `protocol.zolo` handles pkt-lines; `domain.zolo`
validates names, OIDs, and transactions. `wal.zolo` publishes objects and indexes
through `object_store::Store`. `git.zolo` runs Git and maintains the cache;
`auth.zolo` handles credential hashes and ACLs. `pack.zolo` owns temporary files
and their locks; `cache_policy.zolo` evicts by age and budget. `ssh.zolo` integrates
OpenSSH's forced command and publication hook. `monitor.zolo` defines the Verniz
index interface; the generated `monitor_page.zolo` serves its equivalent HTML.

## Persistence

Each repository has the following object families:

| Key | Contents |
| --- | --- |
| `repos/<name>/repo.json` | Version, name, object format, visibility, authorized hashes, and timestamp |
| `repos/<name>/index.json` | Version, object format, live and superseded entries, refs, and HEAD |
| `repos/<name>/wal/<uuid>.json` | Ref updates, pack size and SHA-256, timestamp |
| `repos/<name>/wal/<uuid>.pack` | Received pack bytes, including an empty pack |

Packs and entry metadata are immutable and written only with a create precondition.
The index is conditionally created or updated by ETag. ETags are opaque and include
the S3 server's quotes. UUIDs identify entries; their order comes from the index list.

## Push

1. Validate framing, OIDs, names, duplicates, limits, and credentials.
2. Load metadata and the index; reconstruct the cache when necessary.
3. Invalidate the cache marker before ingestion. Run `index-pack --strict --fix-thin`,
   verify connectivity of new tips, and prepare/abort a ref transaction with
   `update-ref --stdin`.
4. Claim metadata for a new name with conditional creation; reauthorize its winner.
5. Reload the index, validate old values, and prepare against that snapshot.
   Persist the pack and entry, then publish the index by CAS.
6. On conflict, revalidate against the new snapshot, including ingestion: concurrent
   compaction may have removed delta bases. Retry at most eight times.
7. Acknowledge success. Subsequent compaction is recoverable maintenance and does
   not change the push result.

Local preparation does not hold a distributed lock. CAS is the linearization point;
preparation proves that the transaction is valid in the snapshot protected by that
ETag. Redelivery already matching all current tips is a no-op without WAL writes.
Orphaned packs from failed attempts are not replayed.

If a CAS response is lost, the host rereads the index and searches for the entry ID
in both live and superseded lists before reporting failure. If it also cannot reread
the source of truth, the outcome is indeterminate and the client must retry;
idempotency allows convergence.

## Reads and cache

Every discovery or fetch POST reauthorizes and reads the S3 index. Its ETag is
compared with the cache only after that read. The cache is disposable and never
serves as a consensus source. A missing index always reconstructs an empty bare.

Replay verifies each pack's size and SHA-256 before passing it to Git. Transactions
are reapplied in order; resulting refs must match the index. The ETag marker is
written last, after `git fsck`. Storage or replay failure rejects a read instead
of serving stale cache contents.

An OS lock protects each repository throughout authorization, reconstruction,
and use. Release updates the access marker. Locks survive resource aliases and
are released on close or process exit. Multiple workers and processes can share
a local directory. The maintenance lock never waits for a busy repository,
avoiding an inversion of lock order.

Eviction considers only host-generated cache names, checks the canonical path,
and rechecks access under lock. It prioritizes older caches and protects active
ones. Spool files have their own identity and lock; sweeping recovers old orphans
without deleting active transfers. This bounds idle growth without replacing
a filesystem quota.

## Transport and memory

The protocol keeps only pkt-lines in memory; packs move through streams and spool
files in chunks of up to 64 KiB. The HTTP queue has bounded capacity and propagates
read pressure to its producer. Fetch and compaction redirect Git output to a file
without assembling the entire pack in an array. Hashes are computed from the same
open file that will be uploaded to S3.

Large uploads use multipart. Parts do not publish an object: the CAS precondition
is attached to CompleteMultipartUpload. Failures abort the upload when possible;
an ambiguous response never triggers blind republication. Early HTTP responses
retain their status, including when the server refuses the body.

SSH uses a disposable bare repository and verified POSIX permissions. Pre-receive
validates the quarantined pack and publishes to the same WAL before accepting refs.
A hook does not grant its own authorization: the ACL is consulted again during push.
The session keeps stdin/stdout connected to Git, without a pump waiting for input
after child exit. SSH fetch does not use the HTTP spool limit.

## Compaction

Git produces a self-contained pack of the snapshot's tips. It is indexed and
verified in a separate empty bare repository. Publication replaces only the
observed entry prefix, preserving entries appended after it. Before every CAS,
the entire candidate is reconstructed in an isolated cache: a concurrent thin
pack may depend on historical objects missing from the checkpoint. In that case,
compaction is deferred without changing the index. A changed prefix prevents
an index write. Replaced entries remain in `superseded`; historical objects are
not removed.

## Web monitor

The monitor displays the published repository index, references, object format,
and active and superseded WAL entries. Each refresh reads durable state through
the authenticated HTTP API. It does not measure process resource usage or
transfer throughput.

Repository tokens remain in page memory and are cleared on disconnection. The
page avoids browser persistence, disables response caching, and sets a content
security policy restricting connections to the same origin.

Monitor components are authored in `src/monitor.zolo`. The build generates the
embedded page in `src/monitor_page.zolo`; after editing the source, regenerate it
with `zolo run tools/render_monitor.zolo`. Tests verify page and header equivalence.
