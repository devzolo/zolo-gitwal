#!/bin/sh
set -eu

: "${GITWAL_SSH_PUBLIC_KEY:?Set GITWAL_SSH_PUBLIC_KEY to one approved SSH public key}"
: "${GITWAL_SSH_TOKEN:?Set GITWAL_SSH_TOKEN to the principal's Gitwal token}"
: "${GITWAL_S3_ENDPOINT:?Set GITWAL_S3_ENDPOINT}"
: "${GITWAL_S3_BUCKET:?Set GITWAL_S3_BUCKET}"
: "${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY}"

case "$GITWAL_SSH_TOKEN" in
    zgw_*|nwl_*) token_hex=${GITWAL_SSH_TOKEN#????} ;;
    *) echo 'GITWAL_SSH_TOKEN must be a valid Gitwal token' >&2; exit 1 ;;
esac
case "$token_hex" in
    *[!0-9a-f]*|'') echo 'GITWAL_SSH_TOKEN must contain 64 lowercase hexadecimal digits' >&2; exit 1 ;;
esac
[ "${#token_hex}" -eq 64 ] || { echo 'GITWAL_SSH_TOKEN must contain 64 lowercase hexadecimal digits' >&2; exit 1; }

umask 077
mkdir -p /run/sshd /run/gitwal /var/lib/gitwal /etc/ssh/host-keys
chown root:gitwal /run/gitwal
chmod 0750 /run/gitwal
chown gitwal:gitwal /var/lib/gitwal
chmod 0700 /var/lib/gitwal

# Reject authorized_keys options and multiple keys before OpenSSH validates the key.
cr=$(printf '\r')
case "$GITWAL_SSH_PUBLIC_KEY" in
    *'
'*|*"$cr"*) echo 'GITWAL_SSH_PUBLIC_KEY must contain exactly one line' >&2; exit 1 ;;
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *) ;;
    *) echo 'GITWAL_SSH_PUBLIC_KEY must be a public key without authorized_keys options' >&2; exit 1 ;;
esac
printf '%s\n' "$GITWAL_SSH_PUBLIC_KEY" > /run/gitwal/key.pub
ssh-keygen -l -f /run/gitwal/key.pub >/dev/null
printf 'restrict,command="/usr/local/lib/gitwal/ssh-command.sh" %s\n' "$GITWAL_SSH_PUBLIC_KEY" > /run/gitwal/authorized_keys
chmod 0644 /run/gitwal/authorized_keys
rm /run/gitwal/key.pub

# Save only administrator-provided settings, safely quoted as shell literals.
# This root-owned file cannot be changed by an authenticated SSH principal.
GITWAL_DATA=/var/lib/gitwal
GITWAL_CREDENTIAL_PROVIDER=environment
GITWAL_SSH_LAUNCHER='["/usr/local/bin/zolo-gitwal"]'
GITWAL_SSH_TOKEN_HASH=$(printf '%s' "$GITWAL_SSH_TOKEN" | sha256sum | cut -d ' ' -f 1)
export GITWAL_DATA GITWAL_CREDENTIAL_PROVIDER GITWAL_SSH_LAUNCHER GITWAL_SSH_TOKEN_HASH
trusted=/run/gitwal/environment
: > "$trusted"
for name in GITWAL_DATA GITWAL_CREDENTIAL_PROVIDER GITWAL_SSH_LAUNCHER GITWAL_SSH_TOKEN_HASH \
    GITWAL_S3_ENDPOINT GITWAL_S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION \
    GITWAL_CACHE_BYTES GITWAL_CACHE_IDLE_SECONDS GITWAL_CACHE_LOCK_TIMEOUT_MS \
    GITWAL_MULTIPART_THRESHOLD GITWAL_OBJECT_FORMAT GITWAL_COMPACT_AFTER \
    GITWAL_MAX_PUSH_BYTES GITWAL_MAX_FETCH_BYTES; do
    # name comes exclusively from the fixed list above, never from the client.
    eval 'present=${'"$name"'+yes}'
    if [ "$present" = yes ]; then
        eval 'value=${'"$name"'}'
        escaped=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
        printf "export %s='%s'\n" "$name" "$escaped" >> "$trusted"
    fi
done
chown root:gitwal "$trusted"
chmod 0640 "$trusted"
unset GITWAL_SSH_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

if [ ! -f /etc/ssh/host-keys/ssh_host_ed25519_key ]; then
    ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/host-keys/ssh_host_ed25519_key
fi
chmod 0700 /etc/ssh/host-keys
chmod 0600 /etc/ssh/host-keys/ssh_host_ed25519_key
/usr/sbin/sshd -t -f /etc/ssh/gitwal_sshd_config
exec /usr/sbin/sshd -D -e -f /etc/ssh/gitwal_sshd_config
