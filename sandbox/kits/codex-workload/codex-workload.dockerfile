FROM docker/sandbox-templates:codex-docker

USER root

# Accidental host execution prevention marker
RUN mkdir -p /etc/agent-harness \
 && touch /etc/agent-harness/docker-sandbox \
 && chmod 0644 /etc/agent-harness/docker-sandbox

# Pre-populate Codex configuration and authentication sentinel in image layers.
# This setup is strictly image-contained and never touches host paths or host auth.
RUN mkdir -p /home/agent/.codex /etc/skel/.codex \
 && chown -R 1000:1000 /home/agent/.codex

COPY --chown=1000:1000 config.toml /home/agent/.codex/config.toml
COPY --chown=1000:1000 auth.json /home/agent/.codex/auth.json
COPY config.toml /etc/skel/.codex/config.toml
COPY auth.json /etc/skel/.codex/auth.json

RUN chmod 0600 /home/agent/.codex/config.toml /home/agent/.codex/auth.json /etc/skel/.codex/config.toml /etc/skel/.codex/auth.json \
 && chmod 0700 /home/agent/.codex /etc/skel/.codex

USER agent
ENTRYPOINT ["codex", "--dangerously-bypass-approvals-and-sandbox"]
CMD []
