# Getting started: VACTI with Docker

This guide runs VACTI as a container instead of a full VM. It assumes you can use
Docker but not that you know anything about VACTI.

As with the VM, the image ships with no secret baked in. You supply an
**enrollment token** (your license key) at `docker run` time; you mint that token
yourself in the VACTI control plane (the web dashboard your operator gave you).

## 1. Prerequisites

- **Docker 24+** (for native multi-arch pulls; Docker picks amd64 or arm64 for
  your host automatically).
- A **Linux host** is recommended so `--net=host` works for scanning. Host
  networking is limited on Docker Desktop for macOS/Windows.
- The pentest tools need raw sockets, so run with `--cap-add=NET_RAW
  --cap-add=NET_ADMIN` (or `--privileged` if your environment requires it).
- Outbound HTTPS (443) from the host to your control-plane URL.

## 2. Pull the image

```bash
docker pull ghcr.io/anggipradana/vacti-distro:latest
```

> Note: the GHCR package may be private. If the pull is denied, authenticate
> first with `docker login ghcr.io` using an account/token your operator
> authorized.

## 3. Verify the image

Confirm you pulled the right architecture and record the digest:

```bash
docker image inspect ghcr.io/anggipradana/vacti-distro:latest \
  --format '{{.Architecture}} {{.Id}}'
```

To see the full multi-arch manifest (amd64 + arm64):

```bash
docker buildx imagetools inspect ghcr.io/anggipradana/vacti-distro:latest
```

## 4. Run with your license key

```bash
docker run -d --name vacti \
  --net=host --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -e VACTI_URL=https://your-cp.example.com \
  -e VACTI_ENROLL_TOKEN=<your-key> \
  -v vacti-data:/var/lib/vacti-engine \
  ghcr.io/anggipradana/vacti-distro:latest
```

Mint the single-use enrollment token in your control-plane dashboard first; it is
valid for about 3 hours and only works once.
`TODO: confirm the exact dashboard location once the control-plane UX copy is
finalized (reported to be Settings > Engine, "enroll an engine").`
On start the container exchanges it
for scoped engine tokens and persists them to the `vacti-data` volume, so a
restart within the token's lifetime comes back enrolled without re-minting.

## 5. Other ways to supply the key

- **Environment variable** (shown above): `VACTI_ENROLL_TOKEN` or its alias
  `ENROLL_TOKEN`. If you already hold a long-lived **producer token**, pass
  `VACTI_TOKEN` instead and the container skips the enrollment exchange.
- **Env file** (keeps the token out of your shell history and `docker inspect`):

  ```bash
  printf 'VACTI_URL=https://your-cp.example.com\nVACTI_ENROLL_TOKEN=<your-key>\n' \
    > vacti.env
  chmod 600 vacti.env
  docker run -d --name vacti --env-file vacti.env \
    --net=host --cap-add=NET_ADMIN --cap-add=NET_RAW \
    -v vacti-data:/var/lib/vacti-engine \
    ghcr.io/anggipradana/vacti-distro:latest
  ```

- **Secret file mount** (`/etc/vacti/secrets/token`, Docker/Swarm/BuildKit
  secrets): `TODO: not yet supported by the entrypoint, which currently reads the
  token only from the environment or the persisted volume. Use --env-file above
  until the entrypoint learns to read a secret file.`

## 6. Verify enrollment

```bash
docker logs vacti
```

Look for the enrolling line and then the runner starting:

```text
[vacti-docker] enrolling engine_id=<id> at https://your-cp.example.com/api/pentest/enroll (token not logged)
[vacti-docker] starting vacti-engine runner
```

Then open your control-plane dashboard; the engine should appear as **enrolled
and online**.

## 7. Updates

Docker does **not** auto-update, by design (unlike the VM, which self-updates on
an idle-gated timer). To move to a newer image:

```bash
docker pull ghcr.io/anggipradana/vacti-distro:latest
docker rm -f vacti
# re-run the "docker run" command from section 4
```

Because the scoped tokens live in the `vacti-data` volume, the new container
comes back enrolled without a fresh token (as long as you keep the volume).

## 8. Troubleshooting

- **Permission / raw-socket errors** during scans: add `--cap-add=NET_RAW
  --cap-add=NET_ADMIN`, or run with `--privileged`.
- **Auth failure at enrollment**: the log ends with `enroll failed (HTTP ...)`.
  The token is single-use with a ~3 hour lifetime - mint a fresh one and retry.
- **Pull is denied**: run `docker login ghcr.io` (section 2).
- **Missing variable**: the container exits with
  `set VACTI_URL=https://<control-plane>` or `no engine token available`. Provide
  `VACTI_URL` plus `VACTI_ENROLL_TOKEN` (or `VACTI_TOKEN`).
- **Container exits immediately**: run `docker logs vacti`; a `[vacti-docker]
  [FATAL]` line names the cause.

## 9. Volume and data persistence

The `vacti-data` volume is mounted at `/var/lib/vacti-engine` and holds the
engine configuration, including `engine.env` with the scoped tokens (mode 0600)
and engine state. Keep this volume to avoid re-enrolling on every run.

Back it up with a throwaway helper container:

```bash
docker run --rm -v vacti-data:/data -v "$PWD":/backup busybox \
  tar czf /backup/vacti-data.tgz -C /data .
```

Restore by extracting the archive back into a fresh `vacti-data` volume the same
way before starting the container.
