"""Run with python3 test_portmaster.py; fixtures are not runnable ARM binaries."""
from pathlib import Path
import json
import struct
import tempfile
import zipfile
import runpy

package = runpy.run_path(str(Path(__file__).with_name("package-portmaster.py")))
check_arm64, install_zip, ROOT = (package[name] for name in ("check_arm64", "install_zip", "ROOT"))


def main():
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        header = bytearray(64)
        header[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", header, 16, 3)
        struct.pack_into("<H", header, 18, 62)
        binary = root / "fixture"
        binary.write_bytes(header)
        try:
            check_arm64(binary)
        except ValueError:
            pass
        else:
            raise AssertionError("x86-64 accepted as ARM64")
        struct.pack_into("<H", header, 18, 183)
        binary.write_bytes(header)
        binary.chmod(0o755)
        output = root / "test.zip"
        install_zip(binary, output)
        with zipfile.ZipFile(output) as archive:
            names = set(archive.namelist())
            assert "Need for Speed 4.sh" in names and "nfs4/nfs4host.aarch64" in names
            assert not any(n.startswith("nfs4/save/") for n in names)
            assert {n for n in names if n.startswith("nfs4/game/")} == {"nfs4/game/PUT_GAME_FILES_HERE.txt"}
            assert (archive.getinfo("Need for Speed 4.sh").external_attr >> 16) & 0o111
            metadata = json.loads(archive.read("nfs4/port.json"))
            assert metadata["attr"]["arch"] == ["aarch64"]
            assert metadata["items"] == ["Need for Speed 4.sh", "nfs4"]
        png = (ROOT / "portmaster/screenshot.png").read_bytes()
        assert png[:8] == b"\x89PNG\r\n\x1a\n"
        assert struct.unpack_from(">II", png, 16) == (640, 480)
    print("PortMaster packaging self-test OK")


if __name__ == "__main__":
    main()
