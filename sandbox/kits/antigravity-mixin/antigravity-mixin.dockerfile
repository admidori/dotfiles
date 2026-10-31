# syntax=docker/dockerfile:1
FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    tar \
 && rm -rf /var/lib/apt/lists/*

# Install official Antigravity CLI via HTTPS vendor installer fetched into a temporary file.
# Note: The vendor installer dynamically resolves and downloads the floating latest release.
RUN tmp_installer="$(mktemp)" \
 && curl -fsSL "https://antigravity.google/cli/install.sh" -o "$tmp_installer" \
 && mkdir -p /out/usr/local/bin \
 && bash "$tmp_installer" --dir /out/usr/local/bin \
 && rm -f "$tmp_installer"

# Root-owned sanity check marker preventing accidental host execution
RUN mkdir -p /out/etc/agent-harness \
 && touch /out/etc/agent-harness/docker-sandbox \
 && chmod 0644 /out/etc/agent-harness/docker-sandbox

# Full-access Antigravity settings disabling native terminal sandbox
RUN mkdir -p /out/home/agent/.gemini/antigravity-cli /out/etc/skel/.gemini/antigravity-cli
COPY settings.json /out/home/agent/.gemini/antigravity-cli/settings.json
COPY settings.json /out/etc/skel/.gemini/antigravity-cli/settings.json

RUN chown -R 1000:1000 /out/home/agent \
 && chmod 0644 /out/home/agent/.gemini/antigravity-cli/settings.json /out/etc/skel/.gemini/antigravity-cli/settings.json

FROM scratch
COPY --from=build /out/ /
