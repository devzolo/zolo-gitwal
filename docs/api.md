# HTTP API

Gitwal exposes Git Smart HTTP endpoints, repository metadata, and a read-only
monitor. Repository names are flat names, such as `demo.git`; filesystem paths
are not accepted.

## Authentication

Use `Authorization: Bearer <token>` or HTTP Basic authentication with the
token as the password. A private repository requires an authorized token for
reads and writes. Public repositories allow anonymous reads; writes and
configuration changes require a token in the repository ACL.

The first valid push creates a private repository. Generate a token with
`zolo-gitwal token` or the corresponding Docker Compose command.

## Endpoints

| Route | Contract |
| --- | --- |
| `GET /` | Web monitor, repository selection, and an in-memory token |
| `GET /healthz` | Process health without an S3 request |
| `GET /<repo>.git/info/refs?service=git-upload-pack` | Fetch/clone discovery with a fresh read |
| `GET /<repo>.git/info/refs?service=git-receive-pack` | Push discovery from the index |
| `POST /<repo>.git/git-upload-pack` | Fetch/clone using Git v0/v2 |
| `POST /<repo>.git/git-receive-pack` | Atomic push with report-status and sideband |
| `GET /<repo>.git/monitor` | Current index, references, and superseded history |
| `GET /<repo>.git/config` | Metadata; requires push permission |
| `PUT /<repo>.git/config` | Replace visibility and ACL using CAS |

The Git endpoints are designed for standard Git clients. The health endpoint
checks the running process without making a storage request. Monitor and
configuration responses are JSON with `Cache-Control: no-store`.

## Repository configuration

GET `/<repo>.git/config` returns the repository metadata. PUT replaces its
visibility and authorized token hashes:

```json
{
  "visibility": "public",
  "push_tokens": ["<sha256-token-hash>"]
}
```

Visibility may be `private` or `public`. At least one token hash must remain
in the ACL. Generate a hash by setting `GITWAL_TOKEN` and running
`zolo-gitwal hash-token`. With the source toolchain in a POSIX shell:

```sh
GITWAL_TOKEN="$token" zolo run src/main.zolo -- hash-token
```

Successful updates return `204 No Content`. Conditional-update conflicts
return `409`; reread metadata before retrying. Invalid JSON returns `400`,
and a configuration body larger than 64 KiB returns `413`.

Removing a token hash revokes its access, including subsequent SSH fetch
and push sessions. Keep an authorized owner hash when changing the ACL.

## Monitor

GET `/<repo>.git/monitor` returns the durable index: object format, HEAD,
references, active WAL entries, and superseded entries. Reads follow the same
repository visibility rules as clone and fetch. The web interface at `/`
uses this endpoint and keeps its access token in page memory.

See [architecture](architecture.md) for durable publication and fresh-read
semantics, and [SSH](ssh.md) for the shared access-control model.
