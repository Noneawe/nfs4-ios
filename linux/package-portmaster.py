"""Build the local ARM64 install ZIP or a source kit, excluding PC data/saves."""
from pathlib import Path
import argparse
import struct
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parent
SOURCE_FILES = (
    "README.md", "build-native.sh", "build-arm64.sh", "setup.sh", "run.sh",
    "prepare-data.py", "patch-runtime.py", "package-portmaster.py", "plat_linux.c",
    "gpu_gles.c", "gpu_gles.h", "gpu_gles_shaders.h", "input_sdl.c", "input_sdl.h", "test_portmaster.py",
)


def check_arm64(binary):
    with binary.open("rb") as file:
        header = file.read(64)
    if (len(header) < 64 or header[:6] != b"\x7fELF\x02\x01"
            or struct.unpack_from("<H", header, 16)[0] not in (2, 3)
            or struct.unpack_from("<H", header, 18)[0] != 183):
        raise ValueError("Wymagany jest ELF ARM64; nie można spakować binarki x86-64 jako aarch64.")


def install_zip(binary, output):
    check_arm64(binary)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".tmp")
    with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.write(ROOT / "portmaster/Need for Speed 4.sh", "Need for Speed 4.sh")
        archive.write(binary, "nfs4/nfs4host.aarch64")
        for name in ("profile.sh", "README.md", "port.json", "gameinfo.xml", "screenshot.png"):
            archive.write(ROOT / "portmaster" / name, "nfs4/" + name)
        archive.write(ROOT / "portmaster/UPSTREAM.txt", "nfs4/licenses/UPSTREAM.txt")
        archive.writestr("nfs4/game/PUT_GAME_FILES_HERE.txt",
                         "Copy the contents of prepared work/game here. See ../README.md.\n")
    temporary.replace(output)


def source_kit(output):
    checkout = ROOT / "work/source"
    if not (checkout / "recomp/gen/nfs4/nfs4_tables.c").is_file():
        raise ValueError("Brakuje wygenerowanych źródeł work/source/recomp/gen.")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".tmp")
    with tarfile.open(temporary, "w:gz") as archive:
        for name in SOURCE_FILES:
            archive.add(ROOT / name, arcname="nfs4-r36s/" + name)
        archive.add(ROOT / "portmaster", arcname="nfs4-r36s/portmaster")
        for name in ("recomp/gen", "recomp/runtime", "README.md", "ci/input-manifest.json"):
            archive.add(checkout / name, arcname="nfs4-r36s/work/source/" + name)
    temporary.replace(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--binary", type=Path)
    group.add_argument("--source-kit", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.binary:
            output = args.output or ROOT / "work/nfs4-r36s-test.zip"
            install_zip(args.binary, output)
        else:
            output = args.output or ROOT / "work/nfs4-r36s-build-kit.tar.gz"
            source_kit(output)
        print(output)
    except (ValueError, OSError) as error:
        parser.exit(2, f"{error}\n")


if __name__ == "__main__":
    main()
