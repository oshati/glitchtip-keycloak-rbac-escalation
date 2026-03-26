FROM us-central1-docker.pkg.dev/bespokelabs/nebula-devops-registry/nebula-devops:1.0.0

ENV DISPLAY_NUM=1
ENV COMPUTER_HEIGHT_PX=768
ENV COMPUTER_WIDTH_PX=1024

ENV SKIP_BLEATER_BOOT=1
ENV ALLOWED_NAMESPACES="glitchtip,keycloak"

# Pull GlitchTip and dependencies during build (internet available, air-gapped after)
RUN mkdir -p /opt/images && \
    apt-get update -qq && \
    apt-get install -y -qq skopeo && \
    skopeo copy --override-os linux --override-arch amd64 docker://docker.io/glitchtip/glitchtip:v4.1 docker-archive:/opt/images/glitchtip.tar:docker.io/glitchtip/glitchtip:v4.1 && \
    skopeo copy --override-os linux --override-arch amd64 docker://docker.io/library/postgres:15-alpine docker-archive:/opt/images/postgres.tar:docker.io/library/postgres:15-alpine && \
    skopeo copy --override-os linux --override-arch amd64 docker://docker.io/library/redis:7-alpine docker-archive:/opt/images/redis.tar:docker.io/library/redis:7-alpine && \
    skopeo copy --override-os linux --override-arch amd64 docker://docker.io/curlimages/curl:8.7.1 docker-archive:/opt/images/curl.tar:docker.io/curlimages/curl:8.7.1 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
