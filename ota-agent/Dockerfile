FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y \
        podman \
        curl \
        jq \
        iproute2 \
        netcat-openbsd \
        ca-certificates \
        uidmap \
        slirp4netns \
        fuse-overlayfs && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

ENV _CONTAINERS_USERNS_CONFIGURED=1

RUN mkdir -p /app /in /out
WORKDIR /app

COPY agent.sh /app/agent.sh
RUN chmod +x /app/agent.sh

ENV IN_TAR="" \
    LISTEN_PORT=8080 \
    TEST_IMG=""

ENTRYPOINT ["/app/agent.sh"]

