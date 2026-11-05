# syntax=docker/dockerfile:1
FROM docker.io/sbx/shell-docker-image:latest

USER root

# Root-owned sanity check marker preventing accidental host execution
RUN mkdir -p /etc/agent-harness \
 && touch /etc/agent-harness/docker-sandbox \
 && chmod 0644 /etc/agent-harness/docker-sandbox

# Ensure required runtime tools are explicitly installed:
# - python3
# - jq
# - util-linux (provides flock and setsid)
# - coreutils (provides timeout)
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    jq \
    util-linux \
    coreutils \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /home/agent/workspace \
 && chown -R 1000:1000 /home/agent/workspace

USER agent
WORKDIR /home/agent/workspace
ENTRYPOINT ["agy", "--dangerously-skip-permissions", "--settings", "{\"enableTerminalSandbox\":false}"]
CMD []
