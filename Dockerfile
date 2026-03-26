FROM us-central1-docker.pkg.dev/bespokelabs/nebula-devops-registry/nebula-devops:1.0.3

ENV DISPLAY_NUM=1
ENV COMPUTER_HEIGHT_PX=768
ENV COMPUTER_WIDTH_PX=1024

ENV SKIP_BLEATER_BOOT=1
ENV ALLOWED_NAMESPACES="glitchtip,keycloak"

# Place holder for operations
