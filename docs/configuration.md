# Configuration

Gitwal reads configuration from environment variables. Docker Compose loads
`.env` from the project directory; for a standalone executable or VM run, set
the variables in its process environment. Start with `.env.example` when using
the supplied development stack.

## Storage and runtime settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `GITWAL_S3_ENDPOINT` | required | HTTP/HTTPS endpoint, path-style access |
| `GITWAL_S3_BUCKET` | required | Existing bucket |
| `AWS_REGION` | `us-east-1` | Signing region |
| `AWS_ACCESS_KEY_ID` | provider-dependent | S3 access key |
| `AWS_SECRET_ACCESS_KEY` | provider-dependent | S3 secret key |
| `AWS_SESSION_TOKEN` | unset | Optional temporary credential |
| `GITWAL_CREDENTIAL_PROVIDER` | `environment` | `environment`, `aws`, or `process` |
| `AWS_PROFILE` | default profile | Profile for the `aws` provider |
| `GITWAL_CREDENTIAL_PROCESS` | unset | JSON with `program`, `args`, and `timeout_ms` for the `process` provider |
| `GITWAL_PORT` | `8080` | HTTP port |
| `GITWAL_DATA` | `.data` | Local directory shareable by processes |
| `GITWAL_WORKERS` | `1` | HTTP workers, from 1 to 64 |
| `GITWAL_OBJECT_FORMAT` | `sha1` | New repositories: `sha1` or `sha256` |
| `GITWAL_COMPACT_AFTER` | `32` | Entry count; `0` disables compaction |
| `GITWAL_MAX_PUSH_BYTES` | `1073741824` | Received pack limit, 1 GiB by default |
| `GITWAL_MAX_FETCH_BYTES` | `10737418240` | HTTP fetch spool limit, 10 GiB by default |
| `GITWAL_MULTIPART_THRESHOLD` | `67108864` | S3 multipart uploads from 64 MiB |
| `GITWAL_CACHE_BYTES` | `10737418240` | Idle repository budget, 10 GiB; `0` disables it |
| `GITWAL_CACHE_IDLE_SECONDS` | `1800` | Idle expiration; `0` disables it |
| `GITWAL_CACHE_LOCK_TIMEOUT_MS` | `30000` | Maximum wait for a repository lock |

Workers and processes on the same machine can share `GITWAL_DATA`: OS locks
protect each repository cache. Across machines, CAS on the S3 index coordinates
publication. The cache is swept after operations; `gc` forces maintenance without
requiring S3 credentials. Active repositories are protected. The budget excludes
transfers and does not impose a hard disk limit.

The `aws` provider uses the mechanism documented by
[zolo-object-store](https://github.com/devzolo/zolo-object-store). The `process`
provider receives a program and separate argv, without a shell. Expiring credentials
are refreshed before expiration. Repository access tokens do not belong in the
S3 credential configuration.

## Repository access tokens

S3 credentials authorize access to the storage bucket. Repository tokens
authorize Git operations and use a separate access-control list.

Generate a repository token with `zolo-gitwal token`, or use
`docker compose exec -T gitwal zolo-gitwal token`. To obtain its ACL hash,
set `GITWAL_TOKEN` and run `zolo-gitwal hash-token`. The application stores
SHA-256 hashes rather than plaintext repository tokens.

The first valid push claims a new repository as private. Owners can change
visibility and authorized token hashes through the [HTTP API](api.md).

## Deployment

Use an existing S3-compatible bucket with conditional create and update support.
The supplied Compose stack initializes a development bucket and checks these
operations before startup. Keep the bucket and SSH server identity backed up;
the local Git cache is reconstructible.

Configure private storage credentials and HTTPS for exposed deployments.
Reserve disk space for incoming packs, fetch spools, caches, and compaction.
Cache settings control maintenance rather than a hard filesystem quota.

`GITWAL_OBJECT_FORMAT` applies to newly created repositories. Existing
repositories keep their stored format. `GITWAL_MAX_FETCH_BYTES` applies to
HTTP fetch and compaction; SSH fetch streams directly to its client.
Git subprocesses have a five-minute timeout.

See [Docker and operations](docker.md), [SSH](ssh.md), and
[architecture](architecture.md) for deployment and persistence details.
