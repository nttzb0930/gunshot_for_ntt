#!/usr/bin/env python3
"""Check jailed dylib deployment targets against the project's build configuration."""
import argparse
from pathlib import Path
import re
import struct


def configured_ios(source):
    targets = re.findall(
        r"^\s*TARGET\s*:?=\s*iphone:clang:[^:\s]+:(\d+(?:\.\d+){0,2})\s*(?:#.*)?$",
        source,
        re.MULTILINE,
    )
    if len(targets) != 1:
        raise ValueError("Expected one explicit iOS deployment target in the Makefile")
    parts = [int(part) for part in targets[0].split(".")]
    return tuple((parts + [0, 0])[:3])


def minimum_ios(data):
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise ValueError("Expected a thin arm64 Mach-O dylib")
    _, cpu, _, kind, count, size, _, _ = struct.unpack_from("<8I", data)
    if cpu != 0x100000C or kind != 6 or 32 + size > len(data):
        raise ValueError("Invalid arm64 dylib header")
    offset, versions = 32, []
    for _ in range(count):
        if offset + 8 > 32 + size:
            raise ValueError("Truncated load command")
        command, length = struct.unpack_from("<2I", data, offset)
        if length < 8 or offset + length > 32 + size:
            raise ValueError("Invalid load command size")
        if command == 0x32:
            if length < 24:
                raise ValueError("Truncated LC_BUILD_VERSION")
            platform, version = struct.unpack_from("<2I", data, offset + 8)
            if platform != 2:
                raise ValueError("Expected an iOS device platform")
            versions.append(version)
        elif command == 0x25:
            if length < 16:
                raise ValueError("Truncated LC_VERSION_MIN_IPHONEOS")
            versions.append(struct.unpack_from("<I", data, offset + 8)[0])
        offset += length
    if not versions or offset != 32 + size:
        raise ValueError("Missing or malformed iOS deployment target")
    value = max(versions)
    return value >> 16, (value >> 8) & 255, value & 255


def verify(data, maximum):
    version = minimum_ios(data)
    if version > maximum:
        raise ValueError(f"Dylib requires iOS {version}, exceeds {maximum}")
    return version


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dylib", type=Path)
    parser.add_argument("--makefile", type=Path, required=True)
    args = parser.parse_args()
    try:
        maximum = configured_ios(args.makefile.read_text(encoding="utf-8"))
        version = verify(args.dylib.read_bytes(), maximum)
    except (ValueError, OSError) as error:
        parser.exit(1, f"FAIL iOS deployment target: {error}\n")
    print(
        f"PASS jailed iOS deployment target: {version}; configured maximum: {maximum}"
    )
