import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location(
    "minimum", Path(__file__).with_name("verify-ios-minimum.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MinimumTests(unittest.TestCase):
    def test_reads_deployment_target_from_makefile(self):
        self.assertEqual(
            module.configured_ios("TARGET := iphone:clang:latest:15.0\n"), (15, 0, 0)
        )
        self.assertEqual(
            module.configured_ios("TARGET = iphone:clang:latest:17.2.1 # supported\n"),
            (17, 2, 1),
        )
        for source in ("", "TARGET := iphone:clang:latest\n", "TARGET := $(OTHER)\n"):
            with self.assertRaises(ValueError):
                module.configured_ios(source)

    def test_checks_binary_against_configured_target(self):
        maximum = module.configured_ios("TARGET := iphone:clang:latest:15.0\n")
        self.assertEqual(module.verify(self.binary(15 << 16), maximum), (15, 0, 0))
        with self.assertRaises(ValueError):
            module.verify(self.binary(16 << 16), maximum)

    def binary(self, version, platform=2):
        command = struct.pack("<6I", 0x32, 24, platform, version, 0, 0)
        return struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 6, 1, 24, 0, 0) + command

    def test_accepts_ios_15(self):
        self.assertEqual(module.minimum_ios(self.binary(15 << 16)), (15, 0, 0))

    def test_rejects_newer_ios_or_wrong_platform(self):
        for data in (self.binary(26 << 16), self.binary(15 << 16, platform=1)):
            with self.assertRaises(ValueError):
                module.verify(data, (16, 1, 0))

    def test_rejects_missing_or_truncated_commands(self):
        for data in (b"", self.binary(15 << 16)[:-2]):
            with self.assertRaises(ValueError):
                module.minimum_ios(data)


if __name__ == "__main__":
    unittest.main()
