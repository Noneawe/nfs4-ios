import hashlib
import json
import shutil
import sys
from pathlib import Path


def copy_tree(source, target):
    target.mkdir(parents=True, exist_ok=True)
    for entry in source.iterdir():
        dest = target / entry.name.lower()
        if entry.is_dir():
            copy_tree(entry, dest)
        elif entry.is_file():
            shutil.copyfile(entry, dest)


def main():
    patch, upstream, data, original = map(Path, sys.argv[1:])
    modules = {
        "nfs4.exe": patch / "nfs4.exe",
        "eacsnd.dll": patch / "eacsnd.dll",
        "voodoo2a.dll": patch / "drivers/glide3x/voodoo2a.dll",
    }
    manifest = json.loads((upstream / "ci/input-manifest.json").read_text())
    for name, path in modules.items():
        payload = path.read_bytes()
        expected = manifest[name]
        if len(payload) != expected["size"] or hashlib.sha256(payload).hexdigest() != expected["sha256"]:
            sys.exit(f"{name}: inna wersja niż obsługiwana przez rekompilator.")
        shutil.copyfile(path, upstream / "binaries" / name)
    if original != Path("--build-only"):
        folders = {p.name.lower(): p for p in original.iterdir() if p.is_dir()}
        copy_tree(folders["data"], data / "data")
        if "savedata" in folders:
            copy_tree(folders["savedata"], data / "savedata")
    copy_tree(patch / "data", data / "data")
    for name in ("nfs4.exe", "nfs4.ini", "eacsnd.dll"):
        shutil.copyfile(patch / name, data / name)
    driver = data / "drivers/glide3x"
    driver.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(modules["voodoo2a.dll"], driver / "voodoo2a.dll")
    shutil.copyfile(patch / "drivers/glide3x/thrash.ini", driver / "thrash.ini")


if __name__ == "__main__":
    main()
