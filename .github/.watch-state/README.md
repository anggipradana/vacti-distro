# watch-engine-apt idempotency markers

Ephemeral state for `.github/workflows/watch-engine-apt.yml`.

After that workflow dispatches `build.yml` + `build-arm64.yml` for a newly
published `vacti-engine` apt version, it commits an empty marker file here:

    dispatched-<version>.marker

Every subsequent 15-minute poll checks for the marker for the current apt
version and no-ops if it exists, so a given version is dispatched **at most
once** (the `images-v<version>` release takes ~1h to land, during which the
poll would otherwise re-dispatch the same build several times). The top-level
`concurrency: watch-engine-apt` group serializes overlapping polls so two runs
can never both pass the check.

These markers carry no meaning once `images-v<version>` has been published (the
apt-vs-release compare then no-ops regardless). The workflow self-prunes to the
newest 5 markers once more than 10 accumulate; they may also be deleted by hand
when old versions deprecate. Safe to remove; they are state, not source.
