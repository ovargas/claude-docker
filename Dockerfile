FROM ubuntu:24.04

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Costa_Rica

# ─────────────────────────────────────────
# Base tools
# ─────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    # Core utilities
    curl \
    wget \
    git \
    git-lfs \
    unzip \
    zip \
    jq \
    vim \
    nano \
    htop \
    tree \
    tmux \
    less \
    bash-completion \
    ca-certificates \
    gnupg \
    lsb-release \
    software-properties-common \
    apt-transport-https \
    openssh-client \
    # Build tools (needed by some Claude tasks)
    build-essential \
    make \
    # Network tools (nc tunnels SSH through the proxy, socat relays it to nested containers)
    dnsutils \
    iputils-ping \
    netcat-openbsd \
    socat \
    # Process tools
    procps \
    # Python (useful for scripts)
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────
# Node.js (LTS via NodeSource). System-wide for plugin hooks and MCP servers;
# projects get their pinned Node from the `node` stack.
# ─────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────
# GitHub CLI (gh)
# ─────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────
# Docker CLI + compose (talks to the sandbox's own dind daemon, never the host)
# ─────────────────────────────────────────
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y docker-ce-cli docker-compose-plugin docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/*

# ─────────────────────────────────────────
# Non-root user. Its home is a host folder mounted at runtime,
# so nothing the image needs may live under /home/claude.
# ─────────────────────────────────────────
RUN userdel -r ubuntu \
    && useradd --create-home --uid 1000 --shell /bin/bash claude \
    # Mount point of the shared cache volume; a new volume copies this owner
    && install -d -o claude -g claude /cache

# ─────────────────────────────────────────
# Claude Code — native installer, then moved out of $HOME
# ─────────────────────────────────────────
USER claude
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root
RUN cp -L /home/claude/.local/bin/claude /usr/local/bin/claude \
    && rm -rf /home/claude/.local /home/claude/.claude /home/claude/.claude.json
# Updates come from rebuilding the image (`dclaude rebuild`)
ENV DISABLE_AUTOUPDATER=1

# ─────────────────────────────────────────
# Git: system-level config, because ~/.gitconfig is mounted read-only
# ─────────────────────────────────────────
RUN git config --system core.editor "vim" \
    && git config --system init.defaultBranch main \
    && git config --system pull.rebase false \
    # Repo files are owned by the host user, not by `claude`
    && git config --system --add safe.directory '*' \
    # HTTPS pushes authenticate with the scoped GH_TOKEN
    && git config --system credential.https://github.com.helper '!gh auth git-credential'

# ─────────────────────────────────────────
# SSH: tunnel through the egress proxy and trust GitHub's host keys up front,
# so git never stops at an interactive host-key prompt
# ─────────────────────────────────────────
RUN printf 'Host *\n    ProxyCommand nc -X connect -x proxy:3128 %%h %%p\n' \
      > /etc/ssh/ssh_config.d/10-proxy.conf \
    && ssh-keyscan -t ed25519,rsa,ecdsa github.com >> /etc/ssh/ssh_known_hosts 2>/dev/null

# ─────────────────────────────────────────
# Docker client config outside $HOME. `proxies` makes the CLI inject the
# proxy into builds and containers it creates inside dind.
# ─────────────────────────────────────────
ENV DOCKER_CONFIG=/etc/docker-client
COPY docker-client-config.json /etc/docker-client/config.json
RUN chown -R claude:claude /etc/docker-client

# ─────────────────────────────────────────
# Shell quality of life (system-wide: ~/.bashrc lives on the mounted home)
# ─────────────────────────────────────────
RUN echo 'export PS1="\[\033[01;32m\][claude-docker]\[\033[00m\] \[\033[01;34m\]\w\[\033[00m\]\$ "' >> /etc/bash.bashrc \
    && echo 'alias ll="ls -la"' >> /etc/bash.bashrc \
    && echo 'alias gs="git status"' >> /etc/bash.bashrc \
    && echo 'alias gd="git diff"' >> /etc/bash.bashrc

USER claude
WORKDIR /home/claude

# Containers started inside dind can't resolve `proxy`, but they can reach
# dind's default bridge gateway (172.17.0.1). This container shares dind's
# network namespace, so listening here exposes the proxy on that address.
CMD ["socat", "TCP-LISTEN:3128,fork,reuseaddr", "TCP:proxy:3128"]
