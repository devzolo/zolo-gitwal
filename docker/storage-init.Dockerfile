FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --chmod=0755 docker/s3-init.sh /usr/local/bin/s3-init
ENTRYPOINT ["/usr/local/bin/s3-init"]
