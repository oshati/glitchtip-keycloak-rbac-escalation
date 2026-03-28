FROM us-central1-docker.pkg.dev/bespokelabs/nebula-devops-registry/nebula-devops:1.0.0

ENV DISPLAY_NUM=1
ENV COMPUTER_HEIGHT_PX=768
ENV COMPUTER_WIDTH_PX=1024

ENV SKIP_BLEATER_BOOT=1
ENV ALLOWED_NAMESPACES="glitchtip,keycloak"

# Pull images NOT in base image and place in k3s auto-import directory
# k3s automatically imports tarballs from /var/lib/rancher/k3s/agent/images/ on startup
RUN mkdir -p /var/lib/rancher/k3s/agent/images && \
    apt-get update -qq && \
    apt-get install -y -qq skopeo && \
    skopeo copy --override-os linux --override-arch amd64 docker://docker.io/glitchtip/glitchtip:v4.1 docker-archive:/var/lib/rancher/k3s/agent/images/glitchtip.tar:docker.io/glitchtip/glitchtip:v4.1 && \
    skopeo copy --override-os linux --override-arch amd64 docker://docker.io/curlimages/curl:8.7.1 docker-archive:/var/lib/rancher/k3s/agent/images/curl.tar:docker.io/curlimages/curl:8.7.1 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
