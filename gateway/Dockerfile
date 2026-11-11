FROM alpine:latest AS fetch
ARG MIHOMO_VERSION=v1.19.33
RUN apk add --no-cache curl gzip && \
    curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-amd64-${MIHOMO_VERSION}.gz" \
      -o /tmp/mihomo.gz && \
    gzip -d /tmp/mihomo.gz && chmod +x /tmp/mihomo && /tmp/mihomo -v

FROM alpine:latest
RUN apk add --no-cache iproute2 iptables python3 py3-yaml
COPY --from=fetch /tmp/mihomo /usr/bin/mihomo
