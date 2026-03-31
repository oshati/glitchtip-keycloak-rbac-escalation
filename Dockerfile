FROM us-central1-docker.pkg.dev/bespokelabs/nebula-devops-registry/nebula-devops:1.1.0

ENV DISPLAY_NUM=1
ENV COMPUTER_HEIGHT_PX=768
ENV COMPUTER_WIDTH_PX=1024

ENV SKIP_BLEATER_BOOT=1
ENV ALLOWED_NAMESPACES="glitchtip,keycloak"

# GlitchTip is pre-installed in 1.1.0 base image.
# Only need curl image for CronJob enforcers.
RUN mkdir -p /var/lib/rancher/k3s/agent/images && \
    apt-get update -qq && \
    apt-get install -y -qq skopeo && \
    skopeo copy --override-os linux --override-arch amd64 docker://docker.io/curlimages/curl:8.7.1 docker-archive:/var/lib/rancher/k3s/agent/images/curl.tar:docker.io/curlimages/curl:8.7.1 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
