#!/usr/bin/env python3
"""Prove from the kernels' own machine code that known fixes are present.

A version number only says what a package claims. This reads the code that actually runs: the
live kernel through /proc/kcore, and each other installed kernel from its image and System.map.

Exit 0 when the running kernel and the newest installed kernel, which GRUB boots by default, are
both fixed. Exit 1 otherwise. An older kernel only warns, because it boots only if chosen by hand.

Run as root, with python3 -I -B. Read-only. See README section 20.
"""
from pathlib import Path
import platform
import re
import struct
import subprocess
import sys

FIXES = (
    {'cve': 'CVE-2026-98432', 'summary': 'IPv4 options freed without waiting for RCU, reachable from TCP',
     'functions': ('inet_sock_destruct', 'tcp_v4_reqsk_destructor'), 'must_call': 'kvfree_call_rcu', 'must_not_call': 'kfree'},
)


def version_key(release):
    return [int(number) for number in re.findall(r'\d+', release)]


def call_targets(base, code, names):
    """Direct calls and tail jumps out of a function's machine code that land exactly on a symbol."""
    found = []
    for offset in range(len(code) - 4):
        if code[offset] in (0xE8, 0xE9):
            name = names.get(base + offset + 5 + struct.unpack_from('<i', code, offset + 1)[0])
            if name:
                found.append(name)
    return found


def judge(called, fix):
    return fix['must_call'] in called and fix['must_not_call'] not in called


def read_segments(stream, offset=0):
    """(virtual address, size, file offset) of each ELF load segment, for kcore or a vmlinux."""
    stream.seek(offset)
    header = stream.read(64)
    if header[:4] != b'\x7fELF':
        raise ValueError('not an ELF file')
    phoff = struct.unpack_from('<Q', header, 32)[0]
    phentsize, phnum = struct.unpack_from('<HH', header, 54)
    segments = []
    for index in range(phnum):
        stream.seek(offset + phoff + index * phentsize)
        kind, _, file_offset, vaddr, _, filesz = struct.unpack('<IIQQQQ', stream.read(40))
        if kind == 1:
            segments.append((vaddr, filesz, file_offset))
    return segments


def symbols_from(lines):
    table = {}
    for line in lines:
        parts = line.split()
        if len(parts) == 3 and parts[1] in 'tT':
            table.setdefault(parts[2], int(parts[0], 16))
    return table


def check(table, read, fix):
    """True when every function in the fix calls the fixed form. A missing symbol isn't a pass."""
    names, starts = {}, sorted(set(table.values()))
    following = dict(zip(starts, starts[1:]))
    for name, address in table.items():
        names.setdefault(address, name)
    for function in fix['functions']:
        if function not in table:
            return False
        start = table[function]
        if not judge(call_targets(start, read(start, following[start] - start), names), fix):
            return False
    return True


def reader(stream, segments):
    def read(address, length):
        for vaddr, filesz, offset in segments:
            if vaddr <= address and address + length <= vaddr + filesz:
                stream.seek(offset + address - vaddr)
                return stream.read(length)
        raise LookupError(hex(address))
    return read


def check_live(fix):
    with open('/proc/kallsyms') as lines, open('/proc/kcore', 'rb') as core:
        return check(symbols_from(lines), reader(core, read_segments(core)), fix)


def decompressed_image(release):
    image = Path(f'/boot/vmlinuz-{release}').read_bytes()
    for magic, command in ((b'\x28\xb5\x2f\xfd', ['zstd', '-dcq']), (b'\x1f\x8b\x08', ['gzip', '-dcq'])):
        start = image.find(magic)
        while start >= 0:
            output = subprocess.run(command, input=image[start:], capture_output=True, check=False).stdout
            if output[:4] == b'\x7fELF':
                return output
            start = image.find(magic, start + 1)
    raise LookupError('no kernel inside the image of ' + release)


def check_on_disk(release, fix):
    import io
    with open(f'/boot/System.map-{release}') as lines:
        table = symbols_from(lines)
    stream = io.BytesIO(decompressed_image(release))
    return check(table, reader(stream, read_segments(stream)), fix)


def installed_releases():
    return sorted((path.name[len('vmlinuz-'):] for path in Path('/boot').glob('vmlinuz-*')), key=version_key)


def verdict(results, running, newest):
    """results maps (release, cve) to fixed or not. Returns the list of what must stop the host."""
    return [f'{cve} is not fixed in {release}' for (release, cve), fixed in sorted(results.items())
            if not fixed and release in (running, newest)]


def main():
    running = platform.release()
    releases = installed_releases()
    newest = releases[-1] if releases else running
    results = {}
    for fix in FIXES:
        for release in sorted({running, *releases}, key=version_key):
            try:
                fixed = check_live(fix) if release == running else check_on_disk(release, fix)
            except (OSError, ValueError, LookupError, struct.error) as error:
                print(f'[warn] cannot read {release}: {error}', file=sys.stderr)
                fixed = False  # Unproven is not fixed.
            results[(release, fix['cve'])] = fixed
            where = 'live memory' if release == running else 'image on disk'
            print(f'[info] {fix["cve"]} in {release} ({where}): {"fixed" if fixed else "NOT FIXED"}')
    problems = verdict(results, running, newest)
    for (release, cve), fixed in sorted(results.items()):
        if not fixed and release not in (running, newest):
            print(f'[warn] {cve} is not fixed in {release}. It boots only if chosen by hand: remove it.', file=sys.stderr)
    for problem in problems:
        print(f'[fatal] {problem}', file=sys.stderr)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
