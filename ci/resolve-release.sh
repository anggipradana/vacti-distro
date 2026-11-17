#!/usr/bin/env bash
# ci/resolve-release.sh - ONE place that turns a workflow trigger into the release the
# images are stamped with, the engine version they bake, and the publish guard. Used by
# build.yml, build-arm64.yml and build-docker.yml so the three can never disagree.
#
# Inputs (env; all optional, empty = unset):
#   IN_RELEASE        workflow_dispatch inputs.release
#   IN_ENGINE_REF     workflow_dispatch inputs.engine_ref (explicit engine pin override)
#   IN_ALLOW_LEGACY   workflow_dispatch inputs.allow_legacy_release ("true" = override)
#   PAYLOAD_RELEASE   repository_dispatch client_payload.release
#   VAR_ENGINE_REF    repo variable vars.VACTI_ENGINE_REF (operator pin, lowest priority)
#   EVENT_NAME        github.event_name
#   REF_NAME          github.ref_name (tag name on a tag push)
#
# Outputs (KEY=VALUE lines to $GITHUB_OUTPUT, or stdout when unset):
#   release      X.Y.Z the artifacts are stamped/tagged with (leading v stripped)
#   engine_ref   exact vacti-engine version to bake ('' = floating; only possible on a
#                legacy override with no explicit engine_ref)
#   legacy       true when release is not X.Y.Z or is < MIN_RELEASE (0.2.400)
#   publish_latest  true when the moving :latest / HF headline may be advanced
#
# GUARD (item 10): a manual dispatch that kept the placeholder default release=0.1.0
# (or any pre-0.2.400 / non-semver value) OVERWROTE the immutable :0.1.0 image on
# 2026-11-10. A legacy release now FAILS this step (exit 1) unless the operator passes
# allow_legacy_release=true; even then publish_latest=false, so :latest and the HF
# headline are never moved by a legacy build.
set -euo pipefail

MIN_RELEASE="${MIN_RELEASE:-0.2.400}"
strip_v() { local v="${1:-}"; v="${v#images-v}"; v="${v#engine-v}"; printf '%s' "${v#v}"; }
is_semver() { [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
ver_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == "$2" ]]; }  # $1 >= $2

release="$(strip_v "${IN_RELEASE:-}")"
[[ -n "$release" ]] || release="$(strip_v "${PAYLOAD_RELEASE:-}")"
if [[ -z "$release" && "${EVENT_NAME:-}" == "push" ]]; then
  release="$(strip_v "${REF_NAME:-}")"
fi
[[ -n "$release" ]] || release="0.1.0"

legacy=false
if ! is_semver "$release" || ! ver_ge "$release" "$MIN_RELEASE"; then
  legacy=true
fi

engine_ref="$(strip_v "${IN_ENGINE_REF:-}")"
[[ -n "$engine_ref" ]] || engine_ref="$(strip_v "${PAYLOAD_RELEASE:-}")"
if [[ -z "$engine_ref" && "$legacy" == "false" ]]; then
  engine_ref="$release"   # the image is stamped with the engine release it bakes
fi
[[ -n "$engine_ref" ]] || engine_ref="$(strip_v "${VAR_ENGINE_REF:-}")"

allow="${IN_ALLOW_LEGACY:-false}"
if [[ "$legacy" == "true" ]]; then
  if [[ "$allow" != "true" ]]; then
    echo "::error::[resolve-release] release '${release}' is the placeholder default or older than ${MIN_RELEASE}; refusing to build/publish (it would overwrite the immutable :${release} tag). Dispatch with release=<engine X.Y.Z>, or allow_legacy_release=true to override on purpose." >&2
    exit 1
  fi
  echo "::warning::[resolve-release] legacy release '${release}' ALLOWED by allow_legacy_release=true; :latest and the HF headline will NOT be advanced" >&2
fi
publish_latest=true
[[ "$legacy" == "true" ]] && publish_latest=false

out="${GITHUB_OUTPUT:-/dev/stdout}"
{
  echo "release=${release}"
  echo "engine_ref=${engine_ref}"
  echo "legacy=${legacy}"
  echo "publish_latest=${publish_latest}"
} >> "$out"
echo "[resolve-release] release=${release} engine_ref=${engine_ref:-<floating>} legacy=${legacy} publish_latest=${publish_latest}" >&2
