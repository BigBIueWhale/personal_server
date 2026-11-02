"""Exercises scripts/06's verifier against stubbed package tools. Run: python3 -m unittest"""
import os
from pathlib import Path
import shlex
import stat
import subprocess
import tempfile
import textwrap
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / '06_install_nvidia_driver.sh'
OLD, RUNNING, NEW = '7.0.0-42-generic', '7.0.0-43-generic', '7.0.0-44-generic'
GOOD_STATUS = 'nvidia/595.99.02, %s, x86_64: installed'


def verify(images, *, prebuilt='', dkms_package='installed', audit='', headers=None, status=GOOD_STATUS, version='595.99.02',
           path='/lib/modules/%s/updates/dkms/nvidia.ko.zst', running=RUNNING):
    """Run verify_kernel_modules with stubs. /lib/modules is redirected by a private copy of the function's path."""
    headers = set(images) if headers is None else set(headers)
    with tempfile.TemporaryDirectory() as root:
        bin_dir = Path(root) / 'bin'
        bin_dir.mkdir()
        for release in headers:
            build = Path(root) / 'modules' / release / 'build'
            build.mkdir(parents=True)
            (build / 'Makefile').write_text('')
        listing = '\n'.join(f'{state} linux-image-{release}' for release, state in images.items())

        def stub(name, body):
            target = bin_dir / name
            target.write_text('#!/bin/bash\n' + textwrap.dedent(body))
            target.chmod(target.stat().st_mode | stat.S_IEXEC)

        stub('dpkg-query', f'''
            case "$*" in
              *linux-image-*) printf '%s\\n' {shlex.quote(listing)};;
              *linux-modules-nvidia-*) [ -n {shlex.quote(prebuilt)} ] && printf '%s\\n' {shlex.quote(prebuilt)}; exit 0;;
              *Status*nvidia-dkms-595-open) printf %s {dkms_package};;
              *Version*nvidia-dkms-595-open) printf %s 595.99.02-0ubuntu0.24.04.1;;
              *) exit 1;;
            esac
            ''')
        stub('dpkg', f'printf %s {shlex.quote(audit)}\n')
        stub('uname', f'echo {running}\n')
        stub('modinfo', f'''
            rel=$2; case "$4" in
              filename) printf "{path}\\n" "$rel";;
              version) echo {version};;
              vermagic) echo "$rel SMP preempt mod_unload modversions ";;
            esac
            ''')
        stub('dkms', f'printf "{status}\\n" "$7"\n')
        source = SCRIPT.read_text().replace('"/lib/modules/$release/build/Makefile"', f'"{root}/modules/$release/build/Makefile"')
        copy = SCRIPT.parent / f'.test-{os.getpid()}.sh'
        copy.write_text(source)
        try:
            env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}')
            return subprocess.run(['bash', '-c', f'. {shlex.quote(str(copy))}; verify_kernel_modules'], env=env,
                                  capture_output=True, text=True, cwd='/', check=False)
        finally:
            copy.unlink()


class Verifier(unittest.TestCase):
    def healthy(self):
        return {OLD: 'installed', RUNNING: 'installed'}

    def test_healthy(self):
        self.assertEqual(verify(self.healthy()).returncode, 0)

    def test_half_configured_newest_kernel_fails(self):
        result = verify(dict(self.healthy(), **{NEW: 'half-configured'}), headers=[OLD, RUNNING])
        self.assertEqual(result.returncode, 1, result.stderr)

    def test_dpkg_audit_fails(self):
        result = verify(self.healthy(), audit='linux-image half-configured')
        self.assertEqual(result.returncode, 1)
        self.assertIn('unfinished', result.stderr)

    def test_half_configured_prebuilt_fails(self):
        self.assertEqual(verify(self.healthy(), prebuilt='half-configured linux-modules-nvidia-595-open-x').returncode, 1)

    def test_installed_prebuilt_fails(self):
        self.assertEqual(verify(self.healthy(), prebuilt='installed linux-modules-nvidia-595-open-x').returncode, 1)

    def test_older_kernel_without_headers_only_warns(self):
        result = verify(self.healthy(), headers=[RUNNING])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('older kernel', result.stderr)

    def test_newest_kernel_without_headers_fails(self):
        self.assertEqual(verify(dict(self.healthy(), **{NEW: 'installed'}), headers=[OLD, RUNNING]).returncode, 1)

    def test_prebuilt_path_fails(self):
        self.assertEqual(verify(self.healthy(), path='/lib/modules/%s/kernel/nvidia-595-open/nvidia.ko.zst').returncode, 1)

    def test_stale_version_fails(self):
        self.assertEqual(verify(self.healthy(), version='595.91.07').returncode, 1)

    def test_built_only_fails(self):
        self.assertEqual(verify(self.healthy(), status='nvidia/595.99.02, %s, x86_64: built').returncode, 1)

    def test_dkms_3_0_difference_fails(self):
        text = 'nvidia/595.99.02, %s, x86_64: installed (WARNING! Diff between built and installed module!)'
        self.assertEqual(verify(self.healthy(), status=text).returncode, 1)

    def test_dkms_3_4_difference_fails(self):
        text = 'nvidia/595.99.02, %s, x86_64: installed (Differences between built and installed modules)'
        self.assertEqual(verify(self.healthy(), status=text).returncode, 1)


if __name__ == '__main__':
    unittest.main()
