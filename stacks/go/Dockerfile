# Go layer: the latest stable Go at build time. The toolchain each go.mod
# pins is downloaded on demand (GOTOOLCHAIN=auto).
ARG BASE
FROM ${BASE}

USER root
RUN ver="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)" \
    && curl -fsSL "https://go.dev/dl/${ver}.linux-$(dpkg --print-architecture).tar.gz" \
      | tar -C /usr/local -xz

# Module and build caches live in the shared /cache volume, so every Go
# sandbox reuses what the others downloaded
ENV GOPATH=/cache/go \
    GOMODCACHE=/cache/go/mod \
    GOCACHE=/cache/go/build \
    GOTOOLCHAIN=auto
ENV PATH=/usr/local/go/bin:/cache/go/bin:${PATH}

USER claude
