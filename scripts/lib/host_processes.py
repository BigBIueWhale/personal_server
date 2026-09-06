"""Strictly scope Linux process operations to the caller's PID namespace."""

from __future__ import annotations

import os
import pathlib


class HostProcessScopeError(RuntimeError):
    """The caller's host-process boundary could not be established safely."""


def _namespace_identity(path: pathlib.Path) -> tuple[int, int]:
    """Return the stable nsfs identity behind a /proc/PID/ns/* handle."""
    stat = path.stat()
    return stat.st_dev, stat.st_ino


def host_process_dirs(proc: pathlib.Path = pathlib.Path("/proc")) -> list[pathlib.Path]:
    """Return numeric /proc entries in the caller's own PID namespace.

    A host can see processes in descendant PID namespaces, including Docker
    containers.  Comparing the nsfs device/inode pair scopes callers to their
    own process domain without relying on cgroup names, command-line paths, or
    container-runtime-specific metadata.

    Processes that exit during the snapshot and inaccessible processes owned by
    another user are skipped.  Failure to classify one of the caller's own
    processes is an error so per-user cleanup cannot silently miss a candidate.
    """
    if not proc.is_dir():
        raise HostProcessScopeError(f"{proc}: process filesystem is unavailable")

    try:
        host_namespace = _namespace_identity(proc / "self" / "ns" / "pid")
        entries = list(proc.iterdir())
    except OSError as error:
        raise HostProcessScopeError(
            f"cannot establish host PID namespace from {proc}: {error}"
        ) from error

    host_entries: list[pathlib.Path] = []
    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            namespace = _namespace_identity(entry / "ns" / "pid")
        except (FileNotFoundError, ProcessLookupError):
            continue  # the process exited during the snapshot
        except PermissionError as error:
            try:
                owned_by_caller = entry.stat().st_uid == os.geteuid()
            except (FileNotFoundError, PermissionError, ProcessLookupError):
                continue
            if owned_by_caller:
                raise HostProcessScopeError(
                    f"cannot classify caller-owned process pid={entry.name}: {error}"
                ) from error
            continue
        except OSError as error:
            raise HostProcessScopeError(
                f"cannot classify process pid={entry.name}: {error}"
            ) from error

        if namespace == host_namespace:
            host_entries.append(entry)

    return host_entries
