# Magic Stick CLI — Docker Image
# Reproduit la stack logicielle CLI du chroot live-build (sans GUI)
# Cible : conteneur de job GitHub Actions pour IA (Ollama Cloud)

FROM ubuntu:24.04

LABEL maintainer="cheroliv"
LABEL description="Magic Stick CLI — Stack portable pour jobs CI/CD et Ollama Cloud"
LABEL version="0.1.11"

ARG DEBIAN_FRONTEND=noninteractive

# === Base system ===
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    jq \
    ripgrep \
    fd-find \
    fzf \
    htop \
    nano \
    vim \
    less \
    bash-completion \
    unzip \
    zip \
    p7zip-full \
    pciutils \
    usbutils \
    lsb-release \
    lshw \
    dmidecode \
    net-tools \
    iproute2 \
    bridge-utils \
    dnsutils \
    nmap \
    iperf3 \
    tcpdump \
    ethtool \
    socat \
    screen \
    tmux \
    zsh \
    ffmpeg \
    xz-utils \
    zstd \
    build-essential \
    libssl-dev \
    zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    llvm \
    libncursesw5-dev \
    tk-dev \
    libxml2-dev \
    libxmlsec1-dev \
    libffi-dev \
    liblzma-dev \
    && rm -rf /var/lib/apt/lists/*

# === Ollama ===
RUN curl -fsSL https://ollama.com/install.sh | sh

# === Docker CE (client only, pour docker buildx/buildkit dans les jobs) ===
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# === Podman ===
RUN apt-get update && apt-get install -y --no-install-recommends podman && rm -rf /var/lib/apt/lists/*

# === Python 3.14.4 + uv ===
ARG PYTHON_VERSION=3.14.4
RUN curl -fsSL https://pyenv.run | bash \
    && export PATH="$HOME/.pyenv/bin:$PATH" \
    && eval "$(pyenv init -)" \
    && pyenv install ${PYTHON_VERSION} \
    && pyenv global ${PYTHON_VERSION} \
    && curl -LsSf https://astral.sh/uv/install.sh | sh

ENV PATH="/root/.pyenv/shims:/root/.pyenv/bin:/root/.local/bin:$PATH"

# === NVM + Node.js + pnpm ===
ENV NVM_DIR="/root/.nvm"
ENV NODE_VERSION=22
RUN curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash \
    && . "$NVM_DIR/nvm.sh" \
    && nvm install ${NODE_VERSION} \
    && nvm use ${NODE_VERSION} \
    && nvm alias default ${NODE_VERSION} \
    && npm install -g pnpm@10.33.2

ENV PATH="$NVM_DIR/versions/node/v${NODE_VERSION}/bin:$PATH"

# === SDKMAN + JDK 25 Temurin ===
RUN curl -s "https://get.sdkman.io" | bash \
    && bash -c 'export SDKMAN_DIR="/root/.sdkman" && . "$SDKMAN_DIR/bin/sdkman-init.sh" && sdk install java 25-tem && sdk default java 25-tem'

ENV SDKMAN_DIR="/root/.sdkman"
ENV PATH="$SDKMAN_DIR/candidates/java/current/bin:$PATH"
ENV JAVA_HOME="$SDKMAN_DIR/candidates/java/current"

# === Lazygit ===
RUN LAZYGIT_VERSION=$(curl -s https://api.github.com/repos/jesseduffield/lazygit/releases/latest | jq -r '.tag_name' | sed 's/^v//') \
    && curl -fsSL -o lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" \
    && tar xf lazygit.tar.gz -C /usr/local/bin lazygit \
    && rm lazygit.tar.gz

# === xh (HTTPie-like) ===
RUN XH_VERSION=$(curl -s https://api.github.com/repos/ducaale/xh/releases/latest | jq -r '.tag_name' | sed 's/^v//') \
    && curl -fsSL -o xh.tar.gz "https://github.com/ducaale/xh/releases/download/v${XH_VERSION}/xh-v${XH_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    && mkdir -p /tmp/xh-extract && tar xf xh.tar.gz -C /tmp/xh-extract \
    && find /tmp/xh-extract -type f -name xh -exec cp {} /usr/local/bin/xh \; \
    && rm -rf xh.tar.gz /tmp/xh-extract

# === HTTPie ===
RUN uv pip install --system httpie

# === just ===
RUN JUST_VERSION=$(curl -s https://api.github.com/repos/casey/just/releases/latest | jq -r '.tag_name') \
    && curl -fsSL -o just.tar.gz "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
    && mkdir -p /tmp/just-extract && tar xf just.tar.gz -C /tmp/just-extract \
    && find /tmp/just-extract -type f -name just -exec cp {} /usr/local/bin/just \; \
    && rm -rf just.tar.gz /tmp/just-extract

# === starship ===
RUN curl -sS https://starship.rs/install.sh | sh -s -- -y

# === Flatpak ===
RUN apt-get update && apt-get install -y --no-install-recommends flatpak && rm -rf /var/lib/apt/lists/*

# === Final env ===
ENV SHELL=/bin/zsh
ENV TERM=xterm-256color
ENV LC_ALL=fr_FR.UTF-8
ENV LANG=fr_FR.UTF-8

WORKDIR /workspace

CMD ["/bin/zsh"]
