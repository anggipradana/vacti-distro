# Minimal image for the kiosk-runtime test. Matches the distro base (Debian 13).
# The ONLY reason this is a build and not a bare `docker run debian:13-slim` is to
# add three tiny tools the stubs need (`patch` to apply the revert, `setsid` to
# detach the firstboot writer, `pkill` to reap it between scenarios). The build is
# the only step allowed network; the TEST RUN is invoked with `--network none`.
FROM debian:13-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends patch procps util-linux \
 && rm -rf /var/lib/apt/lists/*
# Scripts and the activate source are bind-mounted read-only at run time (so the
# test always exercises the CURRENT file), not copied in.
CMD ["bash", "/test/incontainer.sh"]
