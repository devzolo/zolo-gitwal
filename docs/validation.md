# Testing

Gitwal includes unit tests for repository rules, authentication, protocol handling,
packs, cache policy, WAL publication, and the web monitor. Integration clients use
real Git, OpenSSH, and RustFS to verify transport and storage behavior.

## Unit tests

With the development toolchain installed:

```sh
zolo install
zolo test src
```

Or use the Docker development image:

```sh
docker compose --profile test run --rm --build --no-deps unit
```

## HTTP and storage integration

From the project root, with Docker and Linux containers:

```sh
docker compose up -d --build --wait
docker compose --profile test run --rm --build smoke
docker compose --profile test run --rm --no-deps --entrypoint /usr/local/bin/gitwal-test-storage smoke
```

The HTTP client creates a uniquely named repository and transfers an 8 MiB binary
payload. It saves private credentials and state in the `smoke-state` volume.
The storage client uses that state to inspect the actual index, WAL, and packs.

To check restart recovery and reconstruction with an empty cache:

```sh
docker compose restart rustfs gitwal
docker compose up -d --wait
docker compose --profile test run --rm smoke verify
```

`verify` reads the saved repository instead of creating another one.

## Multipart and compaction

Set these values in `.env`, recreate Gitwal, and run a new HTTP integration test:

```dotenv
GITWAL_COMPACT_AFTER=1
GITWAL_MULTIPART_THRESHOLD=5242880
```

```sh
docker compose up -d --wait gitwal
docker compose --profile test run --rm smoke
docker compose --profile test run --rm --no-deps --entrypoint /usr/local/bin/gitwal-test-storage smoke strict
```

Strict mode additionally requires multipart ETags and a compacted snapshot with
superseded entries.

## Git object formats

Run the HTTP and storage suites with the default `sha1` format, then set
`GITWAL_OBJECT_FORMAT=sha256` in `.env`, recreate Gitwal, and create a new test
repository. Existing repositories keep their stored format.

## SSH integration

The SSH client generates disposable keys inside Docker and verifies shared HTTP
and SSH ownership, access control, command restrictions, and restart persistence.
Setup and repeat commands are in the [SSH guide](ssh.md#integration-test).

## Coverage

| Suite | Contracts |
| --- | --- |
| `tests/http.zolo` | CLI, binary push, clone/fetch, Git integrity, incremental updates, private/public access, unrelated tokens, revocation, ref deletion, idempotent redelivery, atomic stale-ref rejection, monitor, and invalid input |
| `tests/storage.zolo` | Durable index/WAL reads, pack sizes and SHA-256 hashes, binary/empty objects, conditional reads, create/update CAS, and concurrent writers with one winner |
| `tests/storage.zolo strict` | Multipart ETags and compaction with superseded history |
| `tests/ssh.zolo` | Binary/incremental push, HTTP/SSH clone, `git fsck`, atomic refs, command/path/option rejection, unregistered keys, public reads, denied unowned writes, and revocation |
| `src/domain.test.zolo` | Repository names, object IDs, and ref validation |
| `src/wal_test.zolo` | Durable publication, idempotency, failed writes, CAS conflicts, and compaction |
| `src/wal.test.zolo` | HTTP failure without a success ACK, lost PUT response recovery, and a compaction race involving a thin pack with an earlier object base |
| `src/monitor.test.zolo` | Accessible controls, HTML/ARIA attributes, initially empty credentials, rendering, and privacy headers |
| `src/monitor_page.test.zolo` | Generated-page equivalence with the monitor source and preserved headers |
| Other tests in `src` | Authentication, protocol framing, packs, ordering, and cache maintenance |

## Test environment

Integration tests retain repositories in the development bucket and private
client state in Docker volumes. Use a dedicated test environment and record its
revision and configuration when collecting results. These suites verify functional
contracts; they are not throughput benchmarks, distributed load tests, or a memory
capacity estimate. Production sizing depends on repository data, disk capacity,
concurrent operations, and the object-storage service.
