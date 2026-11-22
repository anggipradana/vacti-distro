#!/usr/bin/env python3
"""Delete named tags from a GHCR container package, safely.

Mirrors scripts/delete-hf.py. Every target tag is sanitised BEFORE anything is
deleted:

  * reject glob/substring metacharacters (``*``, ``?``, ``[``) unless ALLOW_GLOB
  * refuse any tag in the hardcoded PROTECTED keep-set
  * refuse the vacti-connector package entirely (go-forward connector image)
  * resolve each tag -> GHCR version id, log tag/version_id/digest/size BEFORE delete
  * delete by EXACT version id (never a glob):
      DELETE /users/<OWNER>/packages/container/<image>/versions/<version_id>

Auth: GH_TOKEN must be a classic PAT with read:packages + delete:packages. The
built-in GITHUB_TOKEN cannot delete user-owned GHCR packages. Idempotent:
already-absent tags are skipped. No git history is touched.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

OWNER = "anggipradana"
ALLOWED_IMAGES = ("vacti-distro",)          # vacti-connector is refused
PROTECTED = {"latest", "0.2.492", "0.2.491", "0.2.490", "0.2.487", "0.1.0"}
GLOB_CHARS = ("*", "?", "[")


class TagRejected(ValueError):
    """A supplied tag failed input sanitation."""


def validate_tag(tag: str, allow_glob: bool) -> str:
    if tag is None or not str(tag).strip():
        raise TagRejected("empty tag")
    t = str(tag).strip()
    if not allow_glob:
        for ch in GLOB_CHARS:
            if ch in t:
                raise TagRejected(
                    f"glob metacharacter {ch!r} not allowed in {t!r} "
                    f"(set allow_glob=true to intentionally use patterns)"
                )
    if "/" in t or ".." in t:
        raise TagRejected(f"illegal character in tag {t!r}")
    if t in PROTECTED:
        raise TagRejected(f"tag {t!r} is PROTECTED (keep-set) and will not be deleted")
    return t


def gh_api(path: str, method: str = "GET"):
    """Call the GitHub REST API via gh, returning parsed JSON (or None)."""
    cmd = ["gh", "api", "-X", method, path]
    if method == "GET":
        cmd += ["--paginate"]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"gh api {method} {path} failed: {out.stderr.strip()}")
    txt = out.stdout.strip()
    if not txt:
        return None
    # --paginate concatenates JSON arrays; normalise to a single list.
    try:
        return json.loads(txt)
    except json.JSONDecodeError:
        merged = []
        for chunk in txt.replace("][", "]\x00[").split("\x00"):
            merged.extend(json.loads(chunk))
        return merged


def list_versions(image: str):
    """All versions of the package: [{id, tags:[...], digest, size?}, ...]."""
    raw = gh_api(f"/users/{OWNER}/packages/container/{image}/versions") or []
    out = []
    for v in raw:
        meta = (v.get("metadata") or {}).get("container") or {}
        out.append({
            "id": v.get("id"),
            "tags": meta.get("tags", []),
            "name": v.get("name"),  # the sha256 digest
            "updated_at": v.get("updated_at"),
        })
    return out


def main() -> int:
    if not os.environ.get("GH_TOKEN"):
        print("GH_TOKEN not set; cannot delete.", file=sys.stderr)
        return 1

    image = os.environ.get("IN_IMAGE", "vacti-distro").strip() or "vacti-distro"
    if image not in ALLOWED_IMAGES:
        print(f"image {image!r} not allowed (allowed: {ALLOWED_IMAGES})", file=sys.stderr)
        return 1

    allow_glob = os.environ.get("ALLOW_GLOB", "").strip().lower() in (
        "1", "true", "yes", "on",
    )
    raw = os.environ.get("IN_TAGS", "")
    names = [p.strip() for p in raw.split(",") if p.strip()]
    if not names:
        print("no tags provided", file=sys.stderr)
        return 1

    wanted = sorted({validate_tag(t, allow_glob) for t in names})  # raises on unsafe

    print("[delete] image     :", image)
    print("[delete] allow_glob:", allow_glob)
    print("[delete] protected :", sorted(PROTECTED))
    print("[delete] requested :", wanted)

    versions = list_versions(image)
    tag_to_version = {}
    for v in versions:
        for t in v["tags"]:
            tag_to_version[t] = v

    present, absent = [], []
    for t in wanted:
        (present if t in tag_to_version else absent).append(t)

    for t in absent:
        print(f"[delete] skip (already absent): {t}")
    if not present:
        print("[delete] nothing to delete (idempotent no-op).")
        return 0

    # Log tag -> version_id -> digest BEFORE deleting.
    print(f"[delete] removing {len(present)} tag(s):")
    to_delete = []
    for t in present:
        v = tag_to_version[t]
        # Guard: never delete a version that ALSO carries a protected tag.
        shared_protected = set(v["tags"]) & PROTECTED
        if shared_protected:
            print(f"[delete] SKIP {t}: shares version id {v['id']} with protected {shared_protected}")
            continue
        print(f"          - {t}  version_id={v['id']}  digest={v['name']}  updated={v['updated_at']}")
        to_delete.append((t, v["id"]))

    failed = []
    for t, vid in to_delete:
        try:
            gh_api(
                f"/users/{OWNER}/packages/container/{image}/versions/{vid}",
                method="DELETE",
            )
            print(f"[delete] OK removed {t} (version {vid})")
        except Exception as e:
            print(f"[delete] FAILED {t} (version {vid}): {e}", file=sys.stderr)
            failed.append(t)

    # Verify.
    remaining = {t for v in list_versions(image) for t in v["tags"]}
    still = [t for t, _ in to_delete if t in remaining]
    if still or failed:
        print(f"[delete] FAILED - still present: {still} / errors: {failed}", file=sys.stderr)
        return 1
    print("[delete] OK - all requested tags removed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
