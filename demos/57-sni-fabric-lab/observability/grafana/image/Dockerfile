# Grafana with the VictoriaLogs datasource plugin baked in at build time: the lab's networks
# have no internet, so Grafana could not fetch a plugin when it starts.
FROM docker.io/library/alpine:3.24.2 AS plugin

ARG PLUGIN_VERSION=v0.32.0
# GitHub's SHA-256 digest of the release asset. The release's checksums file publishes a SHA-1
# (40 hex digits), so that is checked too; a mismatch with either fails the build.
ARG PLUGIN_SHA256=e100b767f19cd614ac8ac3860458a3fb33f5aa7a876e924d0340010e40d1c0d4
WORKDIR /plugin
RUN set -eu; \
    base="https://github.com/VictoriaMetrics/victorialogs-datasource/releases/download/${PLUGIN_VERSION}"; \
    asset="victoriametrics-logs-datasource-${PLUGIN_VERSION}.tar.gz"; \
    wget -q -O "${asset}" "${base}/${asset}"; \
    wget -q -O checksums.txt "${base}/victoriametrics-logs-datasource-${PLUGIN_VERSION}_checksums_tar.gz.txt"; \
    echo "${PLUGIN_SHA256}  ${asset}" | sha256sum -c -; \
    published="$(awk -v name="dist/${asset}" '$2 == name { print $1 }' checksums.txt)"; \
    echo "${published}  ${asset}" | sha1sum -c -; \
    tar -xzf "${asset}"; \
    rm "${asset}" checksums.txt

FROM docker.io/grafana/grafana:12.4.12
# Outside /var/lib/grafana, which the grafdata volume covers. The plugin is signed by its
# vendor, so no unsigned plugin is allowed.
ENV GF_PATHS_PLUGINS=/usr/share/grafana/fabric-plugins
COPY --from=plugin /plugin/victoriametrics-logs-datasource /usr/share/grafana/fabric-plugins/victoriametrics-logs-datasource
