FROM eclipse-temurin:25.0.1_8-jre-ubi10-minimal

LABEL maintainer="Cappy Ishihara <cappy@cappuchino.xyz>" \
      org.opencontainers.image.title="Hytale Dedicated Server" \
      org.opencontainers.image.description="Containerized Hytale dedicated server with automatic updates" \
      org.opencontainers.image.source="https://github.com/kessokunet/hytale-docker" \
      org.opencontainers.image.licenses="Unlicense"

# Environment variables with defaults
ENV HYTALE_PATCHLINE=release \
    HYTALE_DATA_DIR=/data/state \
    HYTALE_BIND=0.0.0.0:5520 \
    HYTALE_BACKUP_FREQUENCY=30 \
    HYTALE_AUTH_MODE=authenticated \
    HYTALE_TRANSPORT=QUIC \
    HYTALE_PERSIST_AUTH=true \
    EXTRA_JVM_ARGS="" \
    HYTALE_EXTRA_ARGS="" \
    HYTALE_BOOT_CMDS="" \
    CONSOLE_PORT=5521

ADD https://downloader.hytale.com/hytale-downloader.zip /tmp/hytale-downloader.zip
RUN --mount=type=cache,target=/var/cache \
 microdnf install -y unzip socat numactl-libs && microdnf clean all


# First we download the Hytale downloader binaries
# The game itself is gated behind DRM so we need to use their official downloader
RUN unzip /tmp/hytale-downloader.zip -d /tmp/hytale-downloader && \
    mv /tmp/hytale-downloader/hytale-downloader-linux-amd64 /usr/bin/hytale-downloader && \
    rm -rf /tmp/hytale-downloader /tmp/hytale-downloader.zip
RUN chmod +x /usr/bin/hytale-downloader


COPY server.sh /opt/hytale/server.sh
RUN chmod +x /opt/hytale/server.sh
# mutable data volume for server binaries and saves
VOLUME [ "/data" ]

# Expose game server port (UDP)
EXPOSE 5520/udp
# Expose telnet console port (TCP)
EXPOSE 5521/tcp

WORKDIR /data

CMD [ "/opt/hytale/server.sh" ]
