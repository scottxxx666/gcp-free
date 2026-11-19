# Wraps any agent image so it runs as uid/gid 1000 and owns /data.
# A new named volume copies the owner of the image's /data, so without this the
# volume is root-owned and the agent (user 1000:1000 in compose) can't write to it.
# The base image needs a shell with mkdir/chown; for distroless images, use a
# multi-stage build that copies a pre-owned /data in with COPY --chown=1000:1000.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
RUN mkdir -p /data && chown 1000:1000 /data
USER 1000:1000
