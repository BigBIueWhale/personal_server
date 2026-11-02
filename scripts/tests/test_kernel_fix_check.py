"""The kernel gate's judgement, on synthetic machine code. Run: python3 -m unittest"""
import io
from pathlib import Path
import platform
import struct
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
import kernel_fix_check as gate  # noqa: E402

FIX = {'cve': 'CVE-TEST', 'functions': ('first', 'second'), 'must_call': 'good_free', 'must_not_call': 'bad_free'}
GOOD, BAD = 0x9000, 0xA000


def calling(base, target, opcode=0xE8):
    """A function of 16 bytes that calls one target."""
    return b'\x90\x90' + bytes([opcode]) + (target - (base + 7)).to_bytes(4, 'little', signed=True) + b'\x90' * 9


def kernel(first_target, second_target):
    table = {'first': 0x1000, 'second': 0x1010, 'after': 0x1020, 'good_free': GOOD, 'bad_free': BAD, 'end': 0xB000}
    code = {0x1000: calling(0x1000, first_target), 0x1010: calling(0x1010, second_target)}
    return table, lambda address, length: code[address][:length]


class Judgement(unittest.TestCase):
    def test_the_fixed_form_passes(self):
        self.assertTrue(gate.check(*kernel(GOOD, GOOD), FIX))

    def test_one_unfixed_function_fails_the_whole_fix(self):
        self.assertFalse(gate.check(*kernel(GOOD, BAD), FIX))

    def test_a_tail_jump_counts_as_a_call(self):
        table = {'first': 0x1000, 'second': 0x1010, 'after': 0x1020, 'good_free': GOOD, 'bad_free': BAD}
        code = {0x1000: calling(0x1000, BAD, 0xE9), 0x1010: calling(0x1010, GOOD)}
        self.assertFalse(gate.check(table, lambda address, length: code[address][:length], FIX))

    def test_calling_both_is_not_fixed(self):
        self.assertFalse(gate.judge(['good_free', 'bad_free'], FIX))

    def test_a_function_that_cannot_be_found_is_not_a_pass(self):
        table, read = kernel(GOOD, GOOD)
        del table['second']
        self.assertFalse(gate.check(table, read, FIX))

    def test_the_lock_on_this_cve_is_stated_exactly(self):
        fix = gate.FIXES[0]
        self.assertEqual(fix['functions'], ('inet_sock_destruct', 'tcp_v4_reqsk_destructor'))
        self.assertEqual((fix['must_call'], fix['must_not_call']), ('kvfree_call_rcu', 'kfree'))


class Verdict(unittest.TestCase):
    def test_the_running_kernel_must_be_fixed(self):
        self.assertTrue(gate.verdict({('a', 'C'): False, ('b', 'C'): True}, 'a', 'b'))

    def test_the_kernel_grub_boots_next_must_be_fixed(self):
        self.assertTrue(gate.verdict({('a', 'C'): True, ('b', 'C'): False}, 'a', 'b'))

    def test_an_older_kernel_alone_does_not_stop_the_host(self):
        self.assertEqual(gate.verdict({('old', 'C'): False, ('a', 'C'): True, ('b', 'C'): True}, 'a', 'b'), [])


class Parsing(unittest.TestCase):
    def test_versions_sort_as_numbers(self):
        self.assertEqual(sorted(['7.0.0-9-generic', '7.0.0-10-generic'], key=gate.version_key), ['7.0.0-9-generic', '7.0.0-10-generic'])

    def test_only_text_symbols_are_kept(self):
        self.assertEqual(gate.symbols_from(['ffff0001 T one\n', 'ffff0002 t two\n', 'ffff0003 D data\n', 'junk\n']),
                         {'one': 0xffff0001, 'two': 0xffff0002})

    def test_elf_segments_map_addresses_to_the_file(self):
        header = bytearray(64)
        header[:4] = b'\x7fELF'
        struct.pack_into('<Q', header, 32, 64)
        struct.pack_into('<HH', header, 54, 56, 1)
        program = struct.pack('<IIQQQQQQ', 1, 0, 120, 0x1000, 0, 4, 4, 0)
        stream = io.BytesIO(bytes(header) + program + b'CODE')
        self.assertEqual(gate.read_segments(stream), [(0x1000, 4, 120)])
        self.assertEqual(gate.reader(stream, gate.read_segments(stream))(0x1000, 4), b'CODE')

    def test_a_file_that_is_not_elf_is_refused(self):
        with self.assertRaises(ValueError):
            gate.read_segments(io.BytesIO(b'not an elf' + bytes(64)))


class RealMachine(unittest.TestCase):
    def test_the_script_is_valid_shell(self):
        script = Path(__file__).resolve().parents[1] / '14_verify_kernel_fixes.sh'
        self.assertEqual(subprocess.run(['bash', '-n', script], check=False).returncode, 0)

    def test_taking_the_public_address_goes_through_the_gate(self):
        script = (Path(__file__).resolve().parents[1] / '13_set_static_ip.sh').read_text()
        gate_at = script.index('lib/kernel_fix_check.py')
        self.assertLess(gate_at, script.index('phase 2'), 'The gate must run before anything is changed.')
        self.assertIn('ALLOW_UNFIXED_KERNEL', script)

    @unittest.skipUnless(Path('/proc/kcore').exists() and __import__('os').geteuid() == 0, 'needs root')
    def test_this_machine_passes(self):
        self.assertTrue(gate.check_live(gate.FIXES[0]), platform.release())


if __name__ == '__main__':
    unittest.main()
