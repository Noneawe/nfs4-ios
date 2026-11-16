#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$here"
compiler=${AARCH64_CC:-aarch64-linux-gnu-gcc}
if [[ $(uname -m) == aarch64 && -z ${AARCH64_CC:-} ]]; then compiler=gcc; fi
if [[ $# -gt 1 || ${1:-} != "" && ${1:-} != --inside ]]; then
    echo "Użycie: $0 [--inside]" >&2
    exit 2
fi
if [[ ${1:-} != --inside ]] && ! command -v "$compiler" >/dev/null; then
    if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
        echo 'Brakuje kompilatora aarch64-linux-gnu-gcc i dostępnego Dockera. Uruchom skrypt na komputerze z Dockerem.' >&2
        exit 2
    fi
    if [[ ! -f work/source/recomp/gen/nfs4/nfs4_tables.c ]]; then
        NFS4_SOURCE_ONLY=1 ./setup.sh --build-only
    fi
    docker build -f portmaster/Dockerfile.arm64 -t nfs4-arm64-builder:20.04 portmaster
    exec docker run --rm --network none --user "$(id -u):$(id -g)" \
        -v "$here:/project" -w /project -e JOBS="${JOBS:-2}" \
        nfs4-arm64-builder:20.04 bash ./build-arm64.sh --inside
fi
if [[ ! -f work/source/recomp/gen/nfs4/nfs4_tables.c ]]; then
    NFS4_SOURCE_ONLY=1 ./setup.sh --build-only
fi
export CC=$compiler
if [[ $("$CC" -dumpmachine) != aarch64* ]]; then
    echo 'Wybrany kompilator nie jest kompilatorem ARM64.' >&2
    exit 2
fi
export PKG_CONFIG_LIBDIR=${PKG_CONFIG_LIBDIR:-/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig}
export GEN_OPT=${GEN_OPT:--O2}
./build-native.sh work/source work/nfs4host.aarch64
readelf -h work/nfs4host.aarch64 > work/arm64-elf.txt
readelf -V work/nfs4host.aarch64 >> work/arm64-elf.txt
if command -v qemu-aarch64 >/dev/null; then
    SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software qemu-aarch64 work/nfs4host.aarch64 --self-test
    qemu-aarch64 work/nfs4host.aarch64 --profile-self-test
else
    echo 'Brak QEMU: pominięto wykonanie testu ARM64. Testy na R36S pozostają konieczne.'
fi
python3 ./package-portmaster.py --binary work/nfs4host.aarch64
