#!/usr/bin/env python3
"""Regression tests for host PID-namespace process scoping."""

from __future__ import annotations

import os
import pathlib
import sys
import tempfile
import unittest


SCRIPT_DIR = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from lib.host_processes import HostProcessScopeError, host_process_dirs


class HostProcessDirsTests(unittest.TestCase):
    def make_proc(self, root: pathlib.Path) -> pathlib.Path:
        proc = root / "proc"
        (proc / "self" / "ns").mkdir(parents=True)
        (proc / "self" / "ns" / "pid").write_text("host namespace")
        return proc

    def add_process(
        self,
        proc: pathlib.Path,
        pid: int,
        *,
        host_namespace: bool,
    ) -> pathlib.Path:
        entry = proc / str(pid)
        (entry / "ns").mkdir(parents=True)
        namespace = entry / "ns" / "pid"
        if host_namespace:
            os.link(proc / "self" / "ns" / "pid", namespace)
        else:
            namespace.write_text("nested namespace")
        return entry

    def test_returns_only_processes_in_callers_pid_namespace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            proc = self.make_proc(pathlib.Path(directory))
            host = self.add_process(proc, 101, host_namespace=True)
            self.add_process(proc, 202, host_namespace=False)
            (proc / "not-a-pid").mkdir()

            self.assertEqual(host_process_dirs(proc), [host])

    def test_skips_process_that_exits_during_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            proc = self.make_proc(pathlib.Path(directory))
            (proc / "303").mkdir()

            self.assertEqual(host_process_dirs(proc), [])

    def test_refuses_when_host_namespace_cannot_be_established(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            proc = pathlib.Path(directory) / "proc"
            proc.mkdir()

            with self.assertRaisesRegex(
                HostProcessScopeError,
                "cannot establish host PID namespace",
            ):
                host_process_dirs(proc)


    def add_unreadable_process(self, proc: pathlib.Path, pid: int) -> pathlib.Path:
        """A caller-owned process whose namespace link cannot be read (as for a
        non-dumpable process of the same user, such as systemd --user)."""
        entry = self.add_process(proc, pid, host_namespace=True)
        (entry / "ns").chmod(0)
        return entry

    def test_unreadable_own_process_refuses_without_a_predicate(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("root reads through a 000 directory")
        with tempfile.TemporaryDirectory() as directory:
            proc = self.make_proc(pathlib.Path(directory))
            self.add_unreadable_process(proc, 404)

            with self.assertRaisesRegex(HostProcessScopeError, "cannot classify caller-owned process pid=404"):
                host_process_dirs(proc)

    def test_unreadable_own_process_skipped_when_not_relevant(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("root reads through a 000 directory")
        with tempfile.TemporaryDirectory() as directory:
            proc = self.make_proc(pathlib.Path(directory))
            host = self.add_process(proc, 101, host_namespace=True)
            self.add_unreadable_process(proc, 404)

            self.assertEqual(host_process_dirs(proc, relevant=lambda entry: False), [host])

    def test_unreadable_own_process_refuses_when_relevant(self) -> None:
        if os.geteuid() == 0:
            self.skipTest("root reads through a 000 directory")
        with tempfile.TemporaryDirectory() as directory:
            proc = self.make_proc(pathlib.Path(directory))
            self.add_unreadable_process(proc, 404)

            with self.assertRaisesRegex(HostProcessScopeError, "cannot classify caller-owned process pid=404"):
                host_process_dirs(proc, relevant=lambda entry: entry.name == "404")


if __name__ == "__main__":
    unittest.main()
