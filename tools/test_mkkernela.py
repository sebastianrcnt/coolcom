#!/usr/bin/env python3
"""Byte-preserving platform selection and generated-header regression checks."""
import re
import unittest

from mkkernela import ROOT, SRC, project


class KernelHeaderTests(unittest.TestCase):
    def test_non_utf8_bytes_and_line_endings(self):
        shared = b'// legacy bytes: \xe3\x80\xff\r\n#define X "\x85"\r\n'
        source = shared + b'#ifdef COOLCOM_KERNEL\r\nkernel\r\n#else\r\nhost\r\n#endif\r\n'
        self.assertEqual(project(source), shared + b'kernel\r\n')
        self.assertEqual(project(source, False), shared + b'host\r\n')

    def test_nested_target_conditions_are_preserved(self):
        source = (b'#ifdef TARGET_AARCH64\n'
                  b'#ifndef COOLCOM_KERNEL\nimport U0 Host();\n#else\nextern U0 Kernel();\n#endif\n'
                  b'#else\n#ifdef COOLCOM_KERNEL\nkernel_other\n#endif\n#endif\n')
        self.assertEqual(project(source), b'#ifdef TARGET_AARCH64\nextern U0 Kernel();\n#else\nkernel_other\n#endif\n')
        self.assertEqual(project(source, False), b'#ifdef TARGET_AARCH64\nimport U0 Host();\n#else\n#endif\n')

    def test_target_conditions_in_discarded_branch(self):
        source = (b'#ifdef COOLCOM_KERNEL\nkernel\n#else\n'
                  b'#if TARGET_X86\nhost_x86\n#elif TARGET_AARCH64\nhost_arm\n#else\nhost_other\n#endif\n'
                  b'#endif\n')
        self.assertEqual(project(source), b'kernel\n')
        self.assertEqual(project(source, False), source.split(b'#else\n', 1)[1].rsplit(b'#endif\n', 1)[0])

    def test_bad_conditions_fail_instead_of_silently_dropping_bytes(self):
        for source in (b'#endif\n', b'#else\n', b'#ifdef COOLCOM_KERNEL\n',
                       b'#if defined(COOLCOM_KERNEL)\n#endif\n',
                       b'#ifdef COOLCOM_KERNEL\n#elif X\n#endif\n',
                       b'#ifdef X\n#else\n#else\n#endif\n'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                project(source)

    def test_kernel_layout_and_host_isolation(self):
        source = SRC.read_bytes()
        kernel, host = project(source), project(source, False)
        for field in (b'term_size_seq', b'(*exit_hook)', b'*exit_data', b'*stack_guard', b'*shell_ctx'):
            self.assertIn(field, kernel)
            self.assertNotIn(field, host)
        self.assertNotRegex(kernel, rb'(?m)^\s*(?:public\s+)?(?:import|_import)\b')
        self.assertRegex(host, rb'(?m)^public class CCPU\b')
        self.assertNotRegex(kernel, rb'(?m)^public class CCPU\b')
        self.assertIn(b'#define CDIR_FILENAME_LEN 766', kernel)
        self.assertRegex(host, rb'#define CDIR_FILENAME_LEN\s+38\b')
        # The OS build must actually consume this projection, including its
        # task layout and Spawn exit-hook declaration, rather than a stale copy.
        generated = (ROOT / 'os/Kernel/KernelA.coolh').read_bytes()
        self.assertEqual(generated.split(b'\n', 1)[1], kernel)
        spawn = re.search(rb'^extern CTask \*Spawn\([^\n]+', kernel, re.M)[0]
        self.assertIn(b'(*exit_hook)(U8 *payload) = NULL', spawn)
        self.assertIn(b'U8 *exit_data = NULL', spawn)


if __name__ == '__main__':
    unittest.main()
