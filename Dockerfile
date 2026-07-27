# Self-contained Ente photo backup image.
#
# Uses Ente's own released binary on a current Wolfi base, rather than
# compiling the CLI or layering onto a months-old published image. That
# means: no Go toolchain in CI, a current glibc, and the CLI version is
# yours to choose.
#
# Everything the backup loop needs is installed at BUILD time. Nothing is
# fetched at container start, so a restart cannot be broken by an
# unreachable package repo.

# Must match a release tag at https://github.com/ente-io/ente/releases
ARG ENTE_RELEASE=cli-v0.2.3

# Strongly recommended. See README for how to obtain it. Left empty the
# build still works, but warns - you are then trusting the download.
ARG ENTE_SHA256=""

# ---- fetch the released binary ---------------------------------------------

FROM cgr.dev/chainguard/wolfi-base AS fetch
ARG ENTE_RELEASE
ARG ENTE_SHA256
# Provided automatically by buildx; defaulted for plain `docker build`.
ARG TARGETARCH=amd64

RUN apk add --no-cache curl gnutar

RUN set -eu; \
    ver="${ENTE_RELEASE#cli-}"; \
    url="https://github.com/ente-io/ente/releases/download/${ENTE_RELEASE}/ente-cli-${ver}-linux-${TARGETARCH}.tar.gz"; \
    echo ">> fetching ${url}"; \
    curl -fsSL --retry 3 -o /tmp/ente.tgz "${url}"; \
    if [ -n "${ENTE_SHA256}" ]; then \
        echo "${ENTE_SHA256}  /tmp/ente.tgz" | sha256sum -c -; \
    else \
        echo ">> WARNING: ENTE_SHA256 empty, skipping checksum verification"; \
        echo ">> actual sha256: $(sha256sum /tmp/ente.tgz | cut -d' ' -f1)"; \
    fi; \
    mkdir -p /out; \
    tar -xzf /tmp/ente.tgz -C /out; \
    bin="$(find /out -type f -name ente | head -n1)"; \
    if [ -z "${bin}" ]; then \
        echo "FATAL: no 'ente' binary in the tarball. Contents:"; \
        find /out; \
        exit 1; \
    fi; \
    cp "${bin}" /ente; \
    chmod 0755 /ente

# ---- runtime ---------------------------------------------------------------

FROM cgr.dev/chainguard/wolfi-base
ARG ENTE_RELEASE

# curl comes from the same package snapshot as this base, so it links
# correctly. ca-certificates-bundle arrives as a curl dependency.
# The version check fails the BUILD if curl cannot execute - this is what
# catches a glibc mismatch before it can reach production and silently
# disable monitoring.
RUN apk add --no-cache curl && curl --version

COPY --from=fetch /ente /usr/bin/ente
COPY ente-backup.sh /usr/local/bin/ente-backup

RUN chmod +x /usr/local/bin/ente-backup \
    && mkdir -p /cli-data /cli-export \
    && out="$(/usr/bin/ente --help 2>&1 || true)"; \
       case "${out}" in \
         *"not found"*|*"cannot open shared object"*|*"No such file or directory"*) \
           echo "${out}"; \
           echo "FATAL: the ente binary cannot run on this base image"; \
           exit 1 ;; \
       esac; \
       echo ">> ente binary runs OK"

ENV ENTE_CLI_CONFIG_DIR=/cli-data \
    ENTE_CLI_SECRETS_PATH=/cli-data/.secrets \
    INTERVAL=3600

# Deliberately NO `VOLUME` declarations. If someone forgets to bind-mount
# /cli-export, a VOLUME would silently create an anonymous volume and the
# backup would appear to work while writing into a throwaway layer.

# Deliberately runs as root. QNAP shares are created root-owned and a
# non-root container cannot write to them without a manual chown. To run
# unprivileged, set `user: "65532:65532"` in compose and chown the host
# directories to match.

LABEL org.opencontainers.image.title="Ente Backup" \
      org.opencontainers.image.description="Ente CLI with a scheduled export loop and Healthchecks pings" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      io.ente.cli.release="${ENTE_RELEASE}"

ENTRYPOINT ["/usr/local/bin/ente-backup"]
