FROM debian:bookworm

# Pinned: upstream master restructured layers (rpi-user-credentials removed) and breaks our config.
ARG RPI_IMAGE_GEN_REF=816afbfbaa7d3ce2fd943ffc2335fb3eecd7ca51

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    e2fsprogs \
    fdisk \
    git \
    mtools \
    sudo \
    util-linux \
    xz-utils \
    zstd \
  && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/raspberrypi/rpi-image-gen.git /opt/rpi-image-gen \
  && cd /opt/rpi-image-gen \
  && if [ "$RPI_IMAGE_GEN_REF" != "master" ]; then \
    git fetch --depth 1 origin "$RPI_IMAGE_GEN_REF" \
    && git checkout FETCH_HEAD; \
  fi \
  && apt-get update \
  && ./install_deps.sh \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /work
