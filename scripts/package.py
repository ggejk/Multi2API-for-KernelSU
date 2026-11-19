#!/usr/bin/env python3
"""Build a KernelSU ZIP from an explicit allowlist (never include local config)."""

import argparse
from pathlib import Path
import re
import struct
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
FILES = (
    "module.prop", "skip_mount", "customize.sh", "boot-completed.sh", "ctl.sh",
    "backends/opencode2api.sh", "configs/opencode2api.example.json",
    "licenses/README.md", "licenses/opencode2api-GPL-3.0.txt",
)


def elf_interpreter(path):
    """Return PT_INTERP for an AArch64 ELF64 binary, or None if static."""
    with path.open("rb") as f:
        header = f.read(64)
        if (len(header) != 64 or header[:6] != b"\x7fELF\x02\x01"
                or struct.unpack_from("<H", header, 18)[0] != 183):
            raise ValueError(f"Expected an arm64 ELF binary: {path}")
        phoff = struct.unpack_from("<Q", header, 32)[0]
        entsize, count = struct.unpack_from("<HH", header, 54)
        for i in range(count):
            f.seek(phoff + entsize * i)
            kind, _, offset, _, _, size, _, _ = struct.unpack("<II6Q", f.read(56))
            if kind == 3:  # PT_INTERP
                if not 0 < size <= 256:
                    raise ValueError(f"Invalid ELF interpreter: {path}")
                f.seek(offset)
                return f.read(size).rstrip(b"\x00")
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "dist/opencode2api-android-arm64",
                        help="Android arm64 binary")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    binary = args.binary
    props = dict(line.split("=", 1) for line in (ROOT / "module.prop").read_text().splitlines()
                 if line and not line.startswith("#"))
    for key in ("id", "version"):
        if not re.fullmatch(r"[a-zA-Z0-9._-]+", props.get(key, "")):
            parser.error(f"invalid {key} in module.prop")

    try:
        interpreter = elf_interpreter(binary)
    except FileNotFoundError:
        parser.error(f"missing {binary}; build it with scripts/build-android.sh first")
    except (ValueError, struct.error, OSError) as exc:
        parser.error(str(exc))
    if interpreter != b"/system/bin/linker64":
        parser.error("expected an Android binary linked against bionic; see scripts/build-android.sh")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = args.output_dir / f"{props['id']}-{props['version']}-android-arm64.zip"
    with ZipFile(output, "w", compression=ZIP_DEFLATED) as archive:
        for name in FILES:
            archive.write(ROOT / name, name)
        archive.write(binary, "bin/opencode2api")
    print(output)


if __name__ == "__main__":
    main()
