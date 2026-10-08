#!/usr/bin/env python3
"""Prepare an isolated, pinned gclient solution; never modify a sibling checkout.

`sync` prepares pristine upstream. `integrate` independently clones that pristine
solution, synchronizes its DEPS, then applies the lock's ordered patch series.
Use a new workspace when the pin or patch series changes. A completed unchanged
invocation verifies the source state and exits without fetching or applying again.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


STAMP = ".applescreen-prepared.json"
INPUT = ".applescreen-input.json"
SHA = re.compile(r"[0-9a-f]{40}")


class PreparationError(Exception):
    pass


def run(args, cwd=None, env=None, capture=False):
    result = subprocess.run(args, cwd=cwd, env=env, check=True,
                            stdout=subprocess.PIPE if capture else None,
                            text=True)
    return result.stdout if capture else None


def git(source, *args):
    return run(["git", "-C", str(source), *args], capture=True).strip()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load_lock(path):
    lock = json.loads(path.read_text())
    if lock.get("version") != 1:
        raise PreparationError("Unsupported dependency lock version")
    upstream = lock["openscreen"]
    for name in ("revision", "previous_revision"):
        if not SHA.fullmatch(upstream[name]):
            raise PreparationError(f"openscreen.{name} must be a full commit SHA")
    if lock["integration"]["expected_upstream_revision"] != upstream["revision"]:
        raise PreparationError("Patch series base does not match the upstream pin")
    for name, library in lock["libraries"].items():
        if not SHA.fullmatch(library["revision"]):
            raise PreparationError(f"{name}.revision must be a full commit SHA")
    return lock


def patches_for(lock, app_root):
    """Validate the entire explicit series before touching a workspace."""
    patches = []
    seen = set()
    for patch in lock["integration"]["patches"]:
        path = (app_root / patch["path"]).resolve()
        if not path.is_relative_to(app_root.resolve()) or path in seen:
            raise PreparationError("Patch paths must be unique and inside the app")
        seen.add(path)
        if digest(path.read_bytes()) != patch["sha256"]:
            raise PreparationError(f"Patch checksum mismatch: {path}")
        patches.append(path)
    return patches


def gclient_configuration(repository):
    # The URL identifies a repository. The immutable revision is passed to sync.
    return "solutions = " + repr([{
        "name": "openscreen", "url": repository,
        "managed": True, "custom_deps": {},
    }]) + "\n"


def check_checkout(source, revision, staged_digest=None, app_root=None):
    if git(source, "rev-parse", "HEAD") != revision:
        raise PreparationError(f"Unexpected HEAD in {source}; use a new workspace")
    if git(source, "diff", "--name-only"):
        raise PreparationError(f"Unstaged source changes in {source}")
    untracked = git(source, "ls-files", "--others", "--exclude-standard").splitlines()
    if app_root is not None:
        link = source / "applescreen"
        if not link.is_symlink() or link.resolve() != app_root.resolve():
            raise PreparationError(f"Unexpected app source reference: {link}")
        untracked = [name for name in untracked if name != "applescreen"]
    if untracked:
        raise PreparationError(f"Untracked source files in {source}: {untracked}")
    staged = run(["git", "-C", str(source), "diff", "--cached", "--binary"],
                 capture=True)
    expected = staged_digest if staged_digest is not None else digest(b"")
    if digest(staged.encode()) != expected:
        raise PreparationError(f"Unexpected staged source changes in {source}")


def prepare(workspace, lock, depot_tools, app_root, pristine=None):
    tool_pin = lock.get("tools", {}).get("depot_tools", {}).get("revision")
    if tool_pin and git(depot_tools, "rev-parse", "HEAD") != tool_pin:
        raise PreparationError("depot_tools does not match the dependency lock")
    workspace = workspace.resolve()
    source = workspace / "openscreen"
    upstream = lock["openscreen"]
    patches = patches_for(lock, app_root) if pristine else []
    desired = {
        "mode": "integration" if pristine else "pristine",
        "repository": upstream["repository"],
        "revision": upstream["revision"],
        "patches": lock["integration"]["patches"] if pristine else [],
    }
    if pristine:
        desired["app_root"] = str(app_root.resolve())
    configuration = gclient_configuration(upstream["repository"])
    config_path = workspace / ".gclient"
    stamp_path = workspace / STAMP
    input_path = workspace / INPUT
    if config_path.exists() and config_path.read_text() != configuration:
        raise PreparationError(f"Refusing to replace an unrelated {config_path}")
    if input_path.exists():
        if json.loads(input_path.read_text()) != desired:
            raise PreparationError("Preparation input changed; use a new workspace")
    elif workspace.exists() and any(workspace.iterdir()):
        raise PreparationError(f"A new solution needs an empty workspace: {workspace}")
    if stamp_path.exists():
        state = json.loads(stamp_path.read_text())
        if state["input"] != desired:
            raise PreparationError("Preparation input changed; use a new workspace")
        check_checkout(source, upstream["revision"], state["staged_sha256"],
                       app_root if pristine else None)
        if git(source, "remote", "get-url", "origin") != upstream["repository"]:
            raise PreparationError(f"Unexpected origin in {source}")
        if not config_path.exists():
            raise PreparationError("Prepared solution is missing .gclient")
        print(f"Already prepared: {workspace}")
        return False

    # Partial clone/sync failures can be retried only while source remains clean.
    if source.exists():
        if not (source / ".git").is_dir():
            raise PreparationError(f"Refusing to overwrite {source}")
        check_checkout(source, upstream["revision"])
        if git(source, "remote", "get-url", "origin") != upstream["repository"]:
            raise PreparationError(f"Unexpected origin in {source}")

    if pristine:
        pristine = pristine.resolve()
        pristine_state = json.loads((pristine / STAMP).read_text())
        if pristine_state["input"]["mode"] != "pristine":
            raise PreparationError("Integration seed must be a pristine solution")
        if pristine == workspace:
            raise PreparationError("Integration must use a separate workspace")
        check_checkout(pristine / "openscreen", upstream["revision"])

    executable = depot_tools.resolve() / "gclient"
    if not executable.is_file():
        raise PreparationError(f"gclient is missing: {executable}")
    workspace.mkdir(parents=True, exist_ok=True)
    input_path.write_text(json.dumps(desired, indent=2) + "\n")
    if not source.exists():
        seed = str(pristine / "openscreen") if pristine else upstream["repository"]
        run(["git", "clone", "--no-hardlinks", "--no-checkout", seed, str(source)])
        if pristine:
            git(source, "remote", "set-url", "origin", upstream["repository"])
        # No shallow history: migration review needs both bases and their ancestry.
        run(["git", "-C", str(source), "fetch", "origin",
             upstream["revision"], upstream["previous_revision"]])
        git(source, "checkout", "--detach", upstream["revision"])
    config_path.write_text(configuration)
    environment = os.environ.copy()
    environment["PATH"] = str(depot_tools.resolve()) + os.pathsep + environment["PATH"]
    environment["DEPOT_TOOLS_UPDATE"] = "0"
    # Only dependency clones may be shallow. Open Screen itself was fetched with
    # complete history above, including the old migration base.
    run([str(executable), "sync", "--nohooks", "--no-history", "--revision",
         "openscreen@" + upstream["revision"]], cwd=workspace, env=environment)
    run([str(executable), "runhooks"], cwd=workspace, env=environment)
    check_checkout(source, upstream["revision"])
    for patch in patches:
        run(["git", "-C", str(source), "apply", "--index", "--check", str(patch)])
        run(["git", "-C", str(source), "apply", "--index", str(patch)])
    staged = run(["git", "-C", str(source), "diff", "--cached", "--binary"],
                 capture=True)
    state = {"input": desired, "staged_sha256": digest(staged.encode())}
    check_checkout(source, upstream["revision"], state["staged_sha256"])
    if pristine:
        (source / "applescreen").symlink_to(app_root.resolve(), target_is_directory=True)
        check_checkout(source, upstream["revision"], state["staged_sha256"], app_root)
    temporary = stamp_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2) + "\n")
    temporary.replace(stamp_path)
    print(f"Prepared {desired['mode']} solution: {workspace}")
    return True


def main():
    app_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("sync", "integrate"))
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--depot-tools", type=Path, required=True)
    parser.add_argument("--lock", type=Path, default=app_root / "dependencies.lock.json")
    parser.add_argument("--pristine", type=Path,
                        help="Previously prepared pristine solution (integrate only)")
    args = parser.parse_args()
    if (args.mode == "integrate") != bool(args.pristine):
        parser.error("integrate requires --pristine; sync does not accept it")
    try:
        prepare(args.workspace, load_lock(args.lock), args.depot_tools,
                args.lock.resolve().parent, args.pristine)
    except (PreparationError, OSError, ValueError, KeyError,
            subprocess.CalledProcessError) as error:
        parser.exit(1, f"Preparation failed: {error}\n")


if __name__ == "__main__":
    main()
