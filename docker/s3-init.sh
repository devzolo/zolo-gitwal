#!/bin/sh
set -eu

: "${GITWAL_S3_ENDPOINT:?S3 endpoint is required}"
: "${GITWAL_S3_BUCKET:?S3 bucket is required}"
: "${AWS_ACCESS_KEY_ID:?S3 access key is required}"
: "${AWS_SECRET_ACCESS_KEY:?S3 secret key is required}"
AWS_REGION=${AWS_REGION:-us-east-1}
case "$GITWAL_S3_BUCKET" in
  *[!a-z0-9.-]*|'') echo 'Invalid S3 bucket name' >&2; exit 1 ;;
esac
endpoint=${GITWAL_S3_ENDPOINT%/}/$GITWAL_S3_BUCKET
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

request() {
  method=$1 url=$2 payload=$3
  shift 3
  printf '%s' "$payload" > "$work/request"
  digest=$(sha256sum "$work/request" | cut -d ' ' -f 1)
  if [ "$method" = HEAD ]; then
    set -- "$@" --head
  else
    set -- "$@" --request "$method"
  fi
  if [ "$method" = PUT ]; then set -- "$@" --data-binary "@$work/request"; fi
  curl --silent --show-error --connect-timeout 5 --max-time 30 \
    --aws-sigv4 "aws:amz:$AWS_REGION:s3" \
    --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
    --header "x-amz-content-sha256: $digest" \
    --output "$work/body" --dump-header "$work/headers" \
    --write-out '%{http_code}' "$@" "$url"
}

status=$(request HEAD "$endpoint" '')
case "$status" in
  200) echo "S3 bucket already exists: $GITWAL_S3_BUCKET" ;;
  404)
    # AWS-compatible bucket creation outside the default region needs a location.
    if [ "$AWS_REGION" = us-east-1 ]; then
      status=$(request PUT "$endpoint" '')
    else
      status=$(request PUT "$endpoint" \
        "<CreateBucketConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><LocationConstraint>$AWS_REGION</LocationConstraint></CreateBucketConfiguration>")
    fi
    [ "$status" = 200 ] || { echo "Bucket creation failed (HTTP $status)" >&2; exit 1; }
    echo "Created S3 bucket: $GITWAL_S3_BUCKET" ;;
  *) echo "Cannot access S3 bucket (HTTP $status)" >&2; exit 1 ;;
esac

# Refuse to start Gitwal against a provider that ignores its WAL preconditions.
key="$endpoint/.gitwal-bootstrap-$(cat /proc/sys/kernel/random/uuid)"
status=$(request PUT "$key" first --header 'If-None-Match: *')
[ "$status" = 200 ] || { echo "Conditional create failed (HTTP $status)" >&2; exit 1; }
etag=$(sed -n 's/^[Ee][Tt][Aa][Gg]: *\(.*\)\r$/\1/p' "$work/headers")
[ -n "$etag" ] || { echo 'S3 did not return an ETag' >&2; exit 1; }
status=$(request PUT "$key" rejected --header 'If-None-Match: *')
[ "$status" = 412 ] || { echo 'S3 did not enforce If-None-Match' >&2; exit 1; }
status=$(request PUT "$key" rejected --header 'If-Match: "stale-etag"')
[ "$status" = 412 ] || { echo 'S3 did not enforce If-Match' >&2; exit 1; }
status=$(request PUT "$key" updated --header "If-Match: $etag")
[ "$status" = 200 ] || { echo "Conditional update failed (HTTP $status)" >&2; exit 1; }
status=$(request GET "$key" '')
[ "$status" = 200 ] && [ "$(cat "$work/body")" = updated ] || { echo 'S3 read-after-write failed' >&2; exit 1; }
status=$(request DELETE "$key" '')
[ "$status" = 204 ] || { echo "S3 probe cleanup failed (HTTP $status)" >&2; exit 1; }
echo 'S3 conditional writes and read-after-write verified; Gitwal can start.'
