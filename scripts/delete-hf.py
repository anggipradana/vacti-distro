#!/usr/bin/env python3
"""Delete named artifacts from the Hugging Face images dataset, safely.

The delete-hf workflow used to hand the operator-supplied ``paths`` straight to
``HfApi.delete_files(delete_patterns=...)``. Those arguments are treated as GLOB
patterns, so a stray ``*`` / ``?`` / ``[`` in the input would silently
over-delete every matching file under the version prefix.

This helper sanitises every target BEFORE anything is deleted:

  * reject glob metacharacters (``*``, ``?``, ``[``)
  * reject path traversal (``..``) and absolute paths
  * require a known-safe prefix (``v0.``, ``v1.`` or ``chromium-``)
  * expand a directory target (one ending in ``/``) to its exact file list via
    ``list_repo_files`` and delete those literally -- never as a glob
  * log each file's sha/size BEFORE it is removed

Deletes run as exact ``CommitOperationDelete`` operations (no glob expansion).
Raw glob semantics are only used when the operator explicitly opts in with the
``allow_glob`` workflow input (env ``ALLOW_GLOB`` truthy), which is off by
default. The run is idempotent: already-absent targets are skipped.
"""

from __future__ import annotations

import os
import sys

REPO_ID = "anggipradana/vacti-distro-images"
REPO_TYPE = "dataset"

# A sanitised target must start with one of these. v0./v1. cover the versioned
# appliance folders; chromium- covers the browser bundle artifacts.
ALLOWED_PREFIXES = ("v0.", "v1.", "chromium-")
GLOB_CHARS = ("*", "?", "[")


class PathRejected(ValueError):
    """A supplied target failed input sanitation."""


def validate_target(path: str) -> str:
    """Return the cleaned path, or raise PathRejected with a clear reason.

    Operates on a FULL target path (e.g. ``v0.1.12/foo.ova`` or
    ``chromium-1254_arm64.deb``), after any version prefix has been applied.
    """
    if path is None or not str(path).strip():
        raise PathRejected("empty path")
    p = str(path).strip()

    for ch in GLOB_CHARS:
        if ch in p:
            raise PathRejected(
                f"glob metacharacter {ch!r} not allowed in {p!r} "
                f"(set allow_glob=true to intentionally use glob patterns)"
            )
    if ".." in p:
        raise PathRejected(f"path traversal '..' not allowed in {p!r}")
    # POSIX absolute, or a Windows drive/UNC style absolute.
    if p.startswith("/") or p.startswith("\\") or (len(p) >= 2 and p[1] == ":"):
        raise PathRejected(f"absolute path not allowed: {p!r}")
    if not p.startswith(ALLOWED_PREFIXES):
        raise PathRejected(
            f"path {p!r} does not start with a known-safe prefix {ALLOWED_PREFIXES}"
        )
    return p


def is_directory(path: str) -> bool:
    """A target that denotes a directory (so it must be expanded, not globbed)."""
    return str(path).strip().endswith("/")


def build_targets(names, version: str):
    """Turn operator-supplied names into full target paths.

    A bare name (``foo.ova``) is placed under ``v<version>/`` -- the original
    behaviour. A name that already carries a known-safe prefix or a ``/`` is
    treated as a full path and used verbatim (validation still applies).
    """
    prefix = f"v{version}/"
    targets = []
    for raw in names:
        n = str(raw).strip()
        if not n:
            continue
        if n.startswith(ALLOWED_PREFIXES) or "/" in n:
            targets.append(n)
        else:
            targets.append(prefix + n)
    return targets


def expand_directory(path: str, repo_files):
    """Exact files under a directory target -- never a glob.

    ``repo_files`` is the full file list from ``list_repo_files``. Returns the
    sorted list of concrete files whose path sits under ``path``.
    """
    prefix = str(path).strip()
    return sorted(
        f for f in repo_files if f.startswith(prefix) and not f.endswith("/")
    )


def resolve_delete_set(names, version, repo_files):
    """Validate + expand operator input into a concrete, literal file list.

    Returns a de-duplicated, sorted list of exact repo paths to delete. Raises
    PathRejected on the first unsafe input, naming the offending path.
    """
    resolved = set()
    for target in build_targets(names, version):
        validate_target(target)  # raises on anything unsafe
        if is_directory(target):
            expanded = expand_directory(target, repo_files)
            print(f"[delete] directory {target!r} expands to {len(expanded)} file(s):")
            for f in expanded:
                print("          +", f)
            resolved.update(expanded)
        else:
            resolved.add(target)
    return sorted(resolved)


def _sha_and_size(info):
    """Best-effort (sha, size) from a RepoFile, preferring the LFS sha256."""
    size = getattr(info, "size", None)
    lfs = getattr(info, "lfs", None)
    if lfs is not None:
        sha = getattr(lfs, "sha256", None) or getattr(lfs, "oid", None)
        if size is None:
            size = getattr(lfs, "size", None)
    else:
        sha = getattr(info, "blob_id", None)
    return sha, size


def main() -> int:
    token = os.environ.get("HF_TOKEN")
    if not token:
        print("HF_TOKEN not set; cannot delete.", file=sys.stderr)
        return 1

    version = os.environ.get("IN_VERSION", "").strip()
    raw = os.environ.get("IN_PATHS", "")
    allow_glob = os.environ.get("ALLOW_GLOB", "").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )

    names = [p.strip() for p in raw.split(",") if p.strip()]
    if not names:
        print("no paths provided", file=sys.stderr)
        return 1

    # Lazy import so the pure validation helpers (and their tests) do not need
    # huggingface_hub installed.
    from huggingface_hub import CommitOperationDelete, HfApi

    api = HfApi(token=token)

    print("[delete] repo      :", REPO_ID)
    print("[delete] version   :", version)
    print("[delete] allow_glob:", allow_glob)

    if allow_glob:
        # Explicit opt-in: preserve the original glob-expansion semantics.
        targets = build_targets(names, version)
        print("[delete] GLOB patterns (operator opted in):")
        for t in targets:
            print("          -", t)
        api.delete_files(
            repo_id=REPO_ID,
            repo_type=REPO_TYPE,
            delete_patterns=targets,
            commit_message=f"chore: delete artifacts (glob) under v{version}",
        )
    else:
        repo_files = api.list_repo_files(repo_id=REPO_ID, repo_type=REPO_TYPE)
        wanted = resolve_delete_set(names, version, repo_files)

        existing = set(repo_files)
        present = [t for t in wanted if t in existing]
        absent = [t for t in wanted if t not in existing]

        for t in absent:
            print(f"[delete] skip (already absent): {t}")

        if not present:
            print("[delete] nothing to delete (idempotent no-op).")
            return 0

        # Log sha/size BEFORE deleting, so the run log records exactly what went.
        try:
            infos = api.get_paths_info(
                repo_id=REPO_ID, repo_type=REPO_TYPE, paths=present, expand=True
            )
            meta = {getattr(i, "path", None): _sha_and_size(i) for i in infos}
        except Exception as e:  # never let logging block a valid delete
            print(f"[delete] WARN could not fetch file metadata: {e}")
            meta = {}

        print(f"[delete] removing {len(present)} exact file(s):")
        for t in present:
            sha, size = meta.get(t, (None, None))
            print(f"          - {t}  sha={sha}  size={size}")

        ops = [CommitOperationDelete(path_in_repo=t) for t in present]
        api.create_commit(
            repo_id=REPO_ID,
            repo_type=REPO_TYPE,
            operations=ops,
            commit_message=f"chore: delete obsolete artifacts under v{version}",
        )

    # Verify + print the resulting listing as proof.
    remaining = sorted(
        api.list_repo_files(repo_id=REPO_ID, repo_type=REPO_TYPE)
    )
    prefix = f"v{version}/"
    under_prefix = [f for f in remaining if f.startswith(prefix)]
    print(f"[delete] remaining files under {prefix} ({len(under_prefix)}):")
    for f in under_prefix:
        print("          -", f)

    remaining_set = set(remaining)
    if allow_glob:
        targets = build_targets(names, version)
        still = [t for t in targets if t in remaining_set]
    else:
        still = [t for t in present if t in remaining_set]
    if still:
        print(f"[delete] FAILED - targets still present: {still}", file=sys.stderr)
        return 1
    print("[delete] OK - all targets removed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
