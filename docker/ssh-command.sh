#!/bin/sh
set -eu

# The daemon's environment and any SSH client variables are discarded. Only the
# requested Git operation crosses this boundary; Gitwal parses it without a shell.
if [ "${1-}" != --trusted ]; then
    exec /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/var/lib/gitwal \
        SSH_ORIGINAL_COMMAND="${SSH_ORIGINAL_COMMAND-}" \
        /bin/sh /usr/local/lib/gitwal/ssh-command.sh --trusted
fi
. /run/gitwal/environment
cd /var/lib/gitwal
exec /usr/local/bin/zolo-gitwal ssh --token-hash "$GITWAL_SSH_TOKEN_HASH"
