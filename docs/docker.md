# Docker Compose with RustFS

## Start

Requires Docker with Linux containers and Docker Compose. On Windows, use Docker
Desktop. The supplied build targets Linux x86-64, downloads Zolo 0.1.8-alpha with
SHA-256 verification, and resolves the public library at the pinned revision.

```sh
git clone https://github.com/devzolo/zolo-gitwal.git
cd zolo-gitwal
docker compose up -d --build --wait
docker compose ps
```

Copy `.env.example` to `.env` to change ports and credentials. The final runtime
contains the compiled application; source and build tools are unnecessary at runtime.

| Address | Service |
| --- | --- |
| <http://localhost:8080> | Monitor and Git Smart HTTP |
| <http://localhost:8080/healthz> | Gitwal process health |
| <http://localhost:9000> | RustFS S3 API |
| <http://localhost:9001> | RustFS console |

The local console uses `gitwal-local` / `gitwal-local-development-secret`.
Ports bind to loopback by default. Configure your own credentials and TLS before
exposing the service. Repository tokens and S3 credentials are separate.

## Initialization

`rustfs` uses the official image pinned by digest. `storage-init` creates the
bucket if missing and verifies GET, ETag, `If-None-Match: *`, and `If-Match`.
Gitwal starts after successful initialization. Bootstrap can be repeated without
deleting repositories and does not grant anonymous access to the bucket.

Gitwal runs as an unprivileged user with a read-only image and dedicated writable
areas for cache and temporary files. Its healthcheck verifies the process;
it does not guarantee continuous S3 availability.

## Your first push

In PowerShell, inside a Git repository with at least one commit:

```powershell
$token = (docker compose exec -T gitwal zolo-gitwal token).Trim()
git -c "http.extraHeader=Authorization: Bearer $token" push http://localhost:8080/demo.git HEAD:refs/heads/main
git -c "http.extraHeader=Authorization: Bearer $token" clone http://localhost:8080/demo.git
```

In a POSIX shell:

```sh
token=$(docker compose exec -T gitwal zolo-gitwal token)
git -c "http.extraHeader=Authorization: Bearer $token" push http://localhost:8080/demo.git HEAD:refs/heads/main
git -c "http.extraHeader=Authorization: Bearer $token" clone http://localhost:8080/demo.git
```

Generate the token from the Compose root before changing directories, or pass
`docker compose -f PATH/compose.yaml`. The first valid push creates a private
repository; only the token hash is persisted. Keep the secret and use the same
token in the monitor.

## Persistence

| Volume | Contents |
| --- | --- |
| `rustfs-data` | Source of truth: packs, WAL, and metadata |
| `gitwal-cache` | Reconstructible cache and working files |
| `ssh-host-keys` | Optional SSH server identity |
| `smoke-state` | Test clients' private credentials and state |

```sh
docker compose logs -f gitwal
docker compose restart gitwal
docker compose down
docker compose up -d --wait
```

`down` preserves volumes. **`docker compose down -v` deletes volumes and all
repositories in this environment.** A single RustFS volume does not provide
redundancy; back up important data.

## Integration tests

```sh
docker compose --profile test run --rm --build --no-deps unit
docker compose --profile test run --rm --build smoke
docker compose --profile test run --rm --no-deps --entrypoint /usr/local/bin/gitwal-test-storage smoke
```

`unit` runs `zolo test src` in the development image. `smoke` uses the native
`gitwal-test-http` client and real Git, creating a uniquely named repository.
It verifies the CLI, push, clone/fetch, binary data, refs, ACLs, and monitor.
It saves state in `/state/smoke.json` on `smoke-state` for later verification.

`gitwal-test-storage` inspects RustFS packs and the WAL, verifies sizes and
SHA-256 hashes, and tests conditional writes and contention on the same ETag.
Test repositories remain in the development bucket.

After restarting or recreating the services:

```sh
docker compose restart rustfs gitwal
docker compose up -d --wait
docker compose --profile test run --rm smoke verify
```

To require multipart ETags and a compacted snapshot, configure the test with
`GITWAL_COMPACT_AFTER=1` and `GITWAL_MULTIPART_THRESHOLD=5242880` in `.env`,
recreate Gitwal, and run a new smoke test. Then:

```sh
docker compose --profile test run --rm --no-deps --entrypoint /usr/local/bin/gitwal-test-storage smoke strict
```

For new SHA-256 repositories, set `GITWAL_OBJECT_FORMAT=sha256` in `.env`,
recreate the services, and run a new test. Existing repositories retain their
object format. See [testing](validation.md) for test coverage and environment details.

## Optional SSH

Set an approved public key and a valid Gitwal token in `.env`:

```dotenv
GITWAL_SSH_PUBLIC_KEY="ssh-ed25519 AAAA... approved-key"
GITWAL_SSH_TOKEN="zgw_..."
GITWAL_SSH_PORT=2222
```

```sh
docker compose --profile ssh up -d --build --wait ssh
git -c core.sshCommand="ssh -p 2222" clone gitwal@localhost:demo.git
```

OpenSSH authenticates the key and runs the command associated with the token hash.
Shell access, PTYs, forwarding, and client-supplied configuration variables are
blocked. The server identity persists in `ssh-host-keys`.

The first SSH push creates a private repository owned by the same HTTP principal.
Use flat names: `gitwal@host:demo.git`; paths such as `/demo.git` are rejected.
Remove the hash from the ACL to revoke access. Changing the container token does
not transfer ownership of existing repositories.

For the integration test, generate keys inside Docker:

```sh
docker compose --profile test run --rm --build --no-deps --entrypoint /usr/local/bin/gitwal-test-ssh -v ./target/ssh-proof:/proof smoke prepare
docker compose --env-file target/ssh-proof/ssh.env --profile ssh up -d --build --wait ssh
docker compose --profile test run --rm --entrypoint /usr/local/bin/gitwal-test-ssh smoke verify
```

Credentials remain in private files in `smoke-state` and
`target/ssh-proof/ssh.env`; the client does not print them. To repeat after restart:

```sh
docker compose --env-file target/ssh-proof/ssh.env restart rustfs gitwal ssh
docker compose --env-file target/ssh-proof/ssh.env --profile ssh up -d --wait ssh
docker compose --profile test run --rm --entrypoint /usr/local/bin/gitwal-test-ssh smoke verify-repeat
```

The [SSH guide](ssh.md) describes the forced command, client modes, and revocation
test through the HTTP API.

## References

- [Official RustFS container](https://docs.rustfs.com/en/installation/container)
- [RustFS health and readiness](https://docs.rustfs.com/en/operations/status-check)
