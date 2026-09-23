# Renders demo.gif with vhs. Run via `make demo`; the plugin is bind-mounted at /plugin.
FROM archlinux:base

RUN echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist \
    && sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 8/' /etc/pacman.conf \
    && pacman -Syu --noconfirm --needed --disable-download-timeout ffmpeg neovim git ttf-jetbrains-mono \
    && pacman -Scc --noconfirm

# vhs drives a headless browser via rod; a system chromium spares the runtime download.
# Docker's seccomp profile blocks its namespace sandbox, so the wrapper turns it off.
RUN pacman -S --noconfirm --needed --disable-download-timeout chromium && pacman -Scc --noconfirm \
    && printf '#!/bin/sh\nexec /usr/bin/chromium --no-sandbox "$@"\n' > /usr/local/bin/chromium \
    && chmod +x /usr/local/bin/chromium

# Upstream release binaries: Arch's ttyd bundles an xterm.js without the canvas
# renderer vhs screenshots, and vhs 0.12.0 runs ffmpeg under an already-cancelled
# context (no output, exit 0).
RUN curl -fsSL https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64 -o /usr/local/bin/ttyd \
    && chmod +x /usr/local/bin/ttyd \
    && curl -fsSL https://github.com/charmbracelet/vhs/releases/download/v0.11.0/vhs_0.11.0_Linux_x86_64.tar.gz \
    | tar xz -C /usr/local/bin --strip-components=1 --wildcards '*/vhs'

RUN curl -fsSL https://github.com/Wilfred/difftastic/releases/download/0.71.0/difft-0.71.0-x86_64-unknown-linux-gnu.tar.gz \
    | tar xz -C /usr/local/bin difft

RUN git clone --depth 1 https://github.com/lewis6991/gitsigns.nvim /opt/gitsigns.nvim \
    && git clone --depth 1 https://github.com/EdenEast/nightfox.nvim /opt/nightfox.nvim

# Chromium refuses to run as root; uid 1000 also keeps the output owned by the host user.
RUN useradd -m -u 1000 demo && mkdir /out /work && chown demo /out /work
USER demo
COPY --chown=demo init.lua /home/demo/.config/nvim/init.lua
COPY --chown=demo sync.before.ts sync.after.ts /tmp/

# A repo with one committed file and an uncommitted edit that reindents a block
# and changes one call inside it.
RUN git config --global user.name demo && git config --global user.email demo@example.invalid \
    && git config --global init.defaultBranch main \
    && mkdir -p /work/src && cd /work && git init -q \
    && cp /tmp/sync.before.ts src/sync.ts && git add -A && git commit -qm initial \
    && cp /tmp/sync.after.ts src/sync.ts

WORKDIR /out
ENTRYPOINT ["vhs"]
