# Git over SSH

SSH uses OpenSSH authentication and a forced command on a POSIX filesystem.
The optional Compose profile runs it in Linux containers; no host SSH daemon or
personal key files need to change.

## Configure an approved key

Set an administrator-approved public key and a Gitwal token in `.env`:

```dotenv
GITWAL_SSH_PUBLIC_KEY="ssh-ed25519 AAAA... approved-key"
GITWAL_SSH_TOKEN="zgw_..."
GITWAL_SSH_PORT=2222
```

```sh
docker compose --profile ssh up -d --build --wait
git -c core.sshCommand="ssh -p 2222" push gitwal@localhost:demo.git HEAD:refs/heads/main
git -c core.sshCommand="ssh -p 2222" clone gitwal@localhost:demo.git
```

The first valid push creates a private repository owned by the configured token
hash. The same token can authenticate Smart HTTP. Existing repositories retain
their ACLs when the container token changes; update the repository configuration
to transfer or revoke access.

Use a flat repository name and scp-style remote, `gitwal@host:demo.git`.
The accepted request grammar is `git-upload-pack NAME` or
`git-receive-pack NAME`, with optional single quotes and a `.git` suffix.
Paths, extra arguments, options, escapes and shell metacharacters are rejected.
The remote command is never executed through a shell.

## Forced-command contract

Outside Compose, associate the approved key with an administrator-selected
SHA-256 token hash:

```text
restrict,command="/opt/gitwal/ssh-wrapper --token-hash TOKEN_SHA256" ssh-ed25519 PUBLIC_KEY
```

The wrapper loads administrator-owned S3 and cache settings and executes
`zolo-gitwal ssh --token-hash TOKEN_SHA256`. Preserve
`SSH_ORIGINAL_COMMAND` only as the requested operation. Credentials, launcher
arguments, cache paths and S3 settings must come from administrator configuration.
Use a dedicated account without an unrestricted shell, forwarding or PTYs.

The compiled application uses its executable as the hook launcher. A VM launcher
can be configured as a JSON array of trusted, fixed arguments:

```text
GITWAL_SSH_LAUNCHER=["/opt/zolo/zolo","run","/opt/gitwal/src/main.zolo","--"]
```

Each connection reconstructs a disposable bare repository from the S3 WAL and
reads fresh ACL metadata. Revoking the configured hash affects subsequent fetch
and push sessions. Receive-pack uses a fixed pre-receive hook, validates the
complete ref transaction and quarantine location, copies the pack into its own
spool, and publishes through the shared durable path. Upload or CAS failure
rejects the push; the disposable repository is never a source of truth.

SHA-1 and SHA-256 follow stored metadata. Pushes are limited by
`receive.maxInputSize` and the pack spool. Each Git child has a five-minute
timeout. Fetch streams directly to SSH; `GITWAL_MAX_FETCH_BYTES` caps HTTP
fetch and compaction packs, not SSH fetch output.

## Integration test

The native Zolo client creates its own keys inside Docker. It saves private state
in `smoke-state` and writes only the approved public key and token to the Compose
environment file. From the project root:

```sh
docker compose --profile test run --rm --build --no-deps --entrypoint /usr/local/bin/gitwal-test-ssh -v ./target/ssh-proof:/proof smoke prepare
docker compose --env-file target/ssh-proof/ssh.env --profile ssh up -d --build --wait ssh
docker compose --profile test run --rm --entrypoint /usr/local/bin/gitwal-test-ssh smoke verify
```

`prepare` defaults to `/state/ssh` and `/proof/ssh.env`; override them with
`GITWAL_SSH_TEST_STATE` and `GITWAL_SSH_TEST_ENV`. Keys and tokens are kept in
private fixture files and are not printed. Protect `target/ssh-proof/ssh.env`
as a credential file.

The test checks binary and incremental pushes, atomic ref creation/deletion,
SSH and HTTP clones, latest-commit equality, object format and `git fsck`.
It rejects arbitrary commands, options, extra arguments, traversal, absolute
paths and an unregistered key. A separate ACL repository exercises public reads,
denied public writes, private access, immediate SSH revocation and restoration
through the HTTP API.

After restarting the services, repeat the read and rejection checks:

```sh
docker compose --env-file target/ssh-proof/ssh.env restart rustfs gitwal ssh
docker compose --env-file target/ssh-proof/ssh.env --profile ssh up -d --wait ssh
docker compose --profile test run --rm --entrypoint /usr/local/bin/gitwal-test-ssh smoke verify-repeat
```

`verify-repeat` reuses the saved test state and creates new clone directories. It
does not push again or repeat ACL mutations. Host keys persist in
`ssh-host-keys`, so strict host-key checking remains effective across restarts.
See [Testing](validation.md) for WAL failure and compaction regression coverage.
