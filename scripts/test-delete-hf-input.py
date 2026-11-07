#!/usr/bin/env python3
"""Unit tests for the delete-hf input sanitation (scripts/delete-hf.py).

Pure-Python: exercises the validation / expansion helpers only, so it runs
without huggingface_hub installed and performs NO network calls.

Run: python scripts/test-delete-hf-input.py
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# Load scripts/delete-hf.py by path (hyphenated filename isn't importable).
_spec = importlib.util.spec_from_file_location(
    "delete_hf", os.path.join(HERE, "delete-hf.py")
)
delete_hf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(delete_hf)

validate_target = delete_hf.validate_target
is_directory = delete_hf.is_directory
expand_directory = delete_hf.expand_directory
resolve_delete_set = delete_hf.resolve_delete_set
PathRejected = delete_hf.PathRejected

_failures = []


def ok(cond, msg):
    if cond:
        print(f"  PASS: {msg}")
    else:
        print(f"  FAIL: {msg}")
        _failures.append(msg)


def expect_pass(path):
    try:
        out = validate_target(path)
        ok(out == path, f"valid path accepted: {path!r}")
    except PathRejected as e:
        ok(False, f"valid path WRONGLY rejected: {path!r} ({e})")


def expect_reject(path, label):
    try:
        validate_target(path)
        ok(False, f"{label} should be rejected: {path!r}")
    except PathRejected:
        ok(True, f"{label} rejected: {path!r}")


print("== valid paths ==")
expect_pass("v0.1.12/foo.ova")
expect_pass("chromium-1234_arm64.deb")
expect_pass("v1.0.0/vacti-distro-1.0.0-amd64-gui.vbox.ova")

print("== rejections ==")
expect_reject("v0.1.12/*.ova", "glob *")
expect_reject("v0.1.12/img-?.ova", "glob ?")
expect_reject("v0.1.12/img[0-9].ova", "glob [")
expect_reject("v0.1.12/../v0.2.423/arm64.ova", "path traversal ..")
expect_reject("/etc/passwd", "absolute path")
expect_reject("C:/Windows/system32", "windows absolute path")
expect_reject("secrets/token.txt", "outside known prefixes")
expect_reject("v2.0.0/foo.ova", "version prefix not in allowlist")
expect_reject("", "empty path")

print("== directory expansion (list + exact, no glob) ==")
repo_files = [
    "v0.1.0/SHA256SUMS",
    "v0.1.0/vacti-distro-0.1.0-amd64-gui.vbox.ova",
    "v0.1.0/vacti-distro-0.1.0-amd64-gui.vmware.ova",
    "v0.2.423/SHA256SUMS",
    "v0.2.423/vacti-distro-0.2.423-amd64-gui.vbox.ova",
    "chromium/vacti-engine-chromium_1254_amd64.deb",
]
dir_target = "v0.1.0/"
ok(is_directory(dir_target), f"detected as directory: {dir_target!r}")
# A directory target still passes sanitation (safe prefix, no glob/traversal).
ok(validate_target(dir_target) == dir_target, "directory target passes validation")
expanded = expand_directory(dir_target, repo_files)
ok(
    expanded
    == [
        "v0.1.0/SHA256SUMS",
        "v0.1.0/vacti-distro-0.1.0-amd64-gui.vbox.ova",
        "v0.1.0/vacti-distro-0.1.0-amd64-gui.vmware.ova",
    ],
    "directory expands to exact files under it (no cross-prefix match)",
)
ok(
    all("*" not in f and "?" not in f and "[" not in f for f in expanded),
    "expanded entries are literal paths, not globs",
)
ok(
    "v0.2.423/SHA256SUMS" not in expanded,
    "expansion does not leak into a sibling version folder",
)

print("== resolve_delete_set: bare names get the v<version>/ prefix ==")
resolved = resolve_delete_set(
    ["vacti-distro-0.1.0-amd64-gui.vbox.ova"], "0.1.0", repo_files
)
ok(
    resolved == ["v0.1.0/vacti-distro-0.1.0-amd64-gui.vbox.ova"],
    "bare name resolved under v0.1.0/",
)

print("== resolve_delete_set: directory input expands, no glob ==")
resolved_dir = resolve_delete_set(["v0.1.0/"], "0.1.0", repo_files)
ok(
    resolved_dir
    == [
        "v0.1.0/SHA256SUMS",
        "v0.1.0/vacti-distro-0.1.0-amd64-gui.vbox.ova",
        "v0.1.0/vacti-distro-0.1.0-amd64-gui.vmware.ova",
    ],
    "directory input resolves to exact file list",
)

print("== resolve_delete_set: unsafe input raises PathRejected ==")
try:
    resolve_delete_set(["v0.1.0/*.ova"], "0.1.0", repo_files)
    ok(False, "glob input should raise in resolve_delete_set")
except PathRejected:
    ok(True, "glob input raises PathRejected in resolve_delete_set")

print()
if _failures:
    print(f"RESULT: {len(_failures)} FAILURE(S)")
    sys.exit(1)
print("RESULT: all tests passed")
