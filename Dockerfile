# Local test harness for the dotfiles installer on a clean Debian system.
# Build & run via `make test`.
FROM debian:bookworm-slim

ENV LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

# The slim image ships a dpkg path-exclude for /usr/share/doc/*, but dpkg
# still creates the excluded directories. Software that reads its own docs
# back then sees a directory with the file missing: the oh-my-zsh fzf plugin
# probes for /usr/share/doc/fzf/examples, finds it, and its unguarded source
# of key-bindings.zsh fails. Re-including the path (this file sorts after
# dpkg.cfg.d/docker, and the last match wins) makes the container behave like
# a real Debian box, which is what this harness is meant to prove.
RUN printf 'path-include /usr/share/doc/*\n' > /etc/dpkg/dpkg.cfg.d/zz-restore-docs

# Only the bootstrap minimum. The installer itself pulls in zsh/tmux/etc.,
# so this proves install.sh works on a near-clean Debian box.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      sudo make git curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Non-root user that mirrors a real interactive account (install must not
# need to run as root). sudo NOPASSWD lets the installer apt-get packages.
ARG USER=tester
RUN useradd --create-home --shell /bin/bash "$USER" \
 && echo "$USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$USER" \
 && chmod 0440 /etc/sudoers.d/"$USER"

USER ${USER}
WORKDIR /home/${USER}/dotfiles

COPY --chown=${USER}:${USER} . /home/${USER}/dotfiles

CMD ["bash", "installer/test.sh"]
