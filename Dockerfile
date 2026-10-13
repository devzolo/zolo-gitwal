# syntax=docker/dockerfile:1
# Must match the Rust sysroot used by the distributed static Zolo runtime.
FROM rust:1.97.1-trixie AS toolchain
ARG TARGETARCH
RUN test "$TARGETARCH" = "amd64" || { echo "This pinned Zolo distribution requires linux/amd64" >&2; exit 1; }
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang lld git ca-certificates curl libssl-dev \
    && rm -rf /var/lib/apt/lists/*
# Distribution source: ccdb88bc3db1b47d2ea47e56c98ed40a438a384d.
# The digest is checked before any compiler executable is used.
RUN curl -fL --retry 3 \
      https://github.com/devzolo/zolo-releases/releases/download/v0.1.8-alpha/zolo-lang-0.1.8-alpha-linux-x64.tar.gz \
      -o /tmp/zolo.tar.gz && \
    echo '558c9a7acc9c4de528a70a018c8887c1813e3eef4c9eebd61e4b75adbab937d5  /tmp/zolo.tar.gz' | sha256sum -c - && \
    mkdir -p /opt/zolo && tar -xzf /tmp/zolo.tar.gz -C /opt/zolo && \
    chmod 0755 /opt/zolo/zolo && rm /tmp/zolo.tar.gz
ENV PATH="/opt/zolo:${PATH}"

FROM toolchain AS build
WORKDIR /workspace/zolo-gitwal
COPY zolo.toml zolo.lock ./
RUN /opt/zolo/zolo install
COPY src/ src/
COPY tools/ tools/
RUN /opt/zolo/zolo run tools/render_monitor.zolo
RUN /opt/zolo/zolo build src/main.zolo --release --emit native --plugins static \
    -o /usr/local/bin/zolo-gitwal && strip /usr/local/bin/zolo-gitwal

FROM debian:trixie-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git libssl3t64 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home --shell /bin/sh gitwal \
    && mkdir -p /var/lib/gitwal && chown 10001:10001 /var/lib/gitwal
COPY --from=build /usr/local/bin/zolo-gitwal /usr/local/bin/zolo-gitwal
ENV GITWAL_DATA=/var/lib/gitwal GITWAL_PORT=8080
USER 10001:10001
WORKDIR /var/lib/gitwal
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/zolo-gitwal"]

FROM runtime AS ssh
USER root
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/* && rm -f /etc/ssh/ssh_host_* \
    && passwd -d gitwal
COPY --chmod=0755 docker/ssh-entrypoint.sh docker/ssh-command.sh /usr/local/lib/gitwal/
COPY docker/sshd_config /etc/ssh/gitwal_sshd_config
EXPOSE 2222
ENTRYPOINT ["/usr/local/lib/gitwal/ssh-entrypoint.sh"]

FROM build AS development
RUN apt-get update && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*
COPY tests/*.zolo tests/
ENTRYPOINT ["/opt/zolo/zolo"]
CMD ["test", "src"]

FROM development AS test-build
RUN /opt/zolo/zolo build tests/http.zolo --release --emit native --plugins static -o /usr/local/bin/gitwal-test-http && \
    /opt/zolo/zolo build tests/storage.zolo --release --emit native --plugins static -o /usr/local/bin/gitwal-test-storage && \
    /opt/zolo/zolo build tests/ssh.zolo --release --emit native --plugins static -o /usr/local/bin/gitwal-test-ssh

FROM runtime AS tests
USER root
RUN apt-get update && apt-get install -y --no-install-recommends openssh-client \
    && rm -rf /var/lib/apt/lists/*
COPY --from=test-build /usr/local/bin/gitwal-test-* /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/gitwal-test-http"]
CMD ["create"]
