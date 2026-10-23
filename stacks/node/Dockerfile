# Node layer. The base image's system Node stays for plugins; this adds the
# exact Node each project pins (.nvmrc, .node-version, .tool-versions) through
# mise shims, and its exact package manager (packageManager field) through
# corepack. Shims resolve the version per directory, so concurrent sandboxes
# sharing /cache don't fight over a global default.
ARG BASE
FROM ${BASE}

USER root
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && corepack enable

ENV MISE_DATA_DIR=/cache/mise \
    MISE_CACHE_DIR=/cache/mise/cache \
    MISE_IDIOMATIC_VERSION_FILE_ENABLE_TOOLS=node \
    MISE_NODE_COREPACK=true \
    MISE_TRUSTED_CONFIG_PATHS=/ \
    MISE_USE_VERSIONS_HOST=false \
    MISE_YES=1 \
    COREPACK_HOME=/cache/corepack \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    npm_config_store_dir=/cache/pnpm-store
ENV PATH=/cache/mise/shims:${PATH}

USER claude
