FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip python3 binutils-mipsel-linux-gnu \
        libgl1 libegl1 libx11-6 libxext6 libxrandr2 libxcursor1 libxi6 libxinerama1 libfontconfig1 \
        libgpg-error0 libfribidi0 libharfbuzz0b \
    && rm -rf /var/lib/apt/lists/*

# Redux dev channel build. Pass REDUX_URL to pin a specific one; the sha256 of what was used
# is kept in /opt/redux.sha256 so both players can check they run the same referee.
ARG REDUX_URL=https://distrib.app/pub/org/pcsx-redux/project/dev-linux-x64/latest
RUN mkdir -p /opt/redux && cd /opt/redux \
    && curl -sfL -o redux.zip "$REDUX_URL" && unzip -q redux.zip && rm redux.zip \
    && sha256sum PCSX-Redux-*.AppImage > /opt/redux.sha256 \
    && ./PCSX-Redux-*.AppImage --appimage-extract > /dev/null && rm PCSX-Redux-*.AppImage

COPY duel referee.lua server.py /opt/duel/

ENV DUEL_REDUX=/opt/redux/squashfs-root/AppRun \
    DUEL_BIOS=/opt/redux/squashfs-root/usr/share/pcsx-redux/resources/openbios.bin \
    DUEL_AS=mipsel-linux-gnu-as \
    DUEL_OBJCOPY=mipsel-linux-gnu-objcopy \
    DUEL_SECRET=/secret/secret.s \
    DUEL_TOKENS=/config/tokens \
    DUEL_STATE=/state \
    HOME=/tmp

EXPOSE 8080
CMD ["python3", "/opt/duel/server.py"]
