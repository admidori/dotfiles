# Local test harness for the dotfiles installer on a clean Debian system.
# Build & run via `make test`.
FROM debian:bookworm-slim

ENV LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive

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
