#!/usr/bin/env bash
# Uruchamia binarkę ARM64 w QEMU (Docker), okno na lokalnym pulpicie X11.
# Użycie: ./run-arm64-qemu.sh [--gles]   (domyślnie renderer programowy)
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$here"
[[ -x work/nfs4host.aarch64 ]] || { echo 'Brak work/nfs4host.aarch64. Uruchom ./build-arm64.sh.' >&2; exit 2; }
[[ -f work/game/data/text/mam.dat ]] || { echo 'Brak work/game. Uruchom ./setup.sh.' >&2; exit 2; }
docker image inspect nfs4-arm64-builder:20.04 >/dev/null 2>&1 || { echo 'Brak obrazu. Uruchom ./build-arm64.sh.' >&2; exit 2; }
: "${DISPLAY:?Brak DISPLAY. Uruchom z sesji graficznej (X11/XWayland).}"
soft=1; [[ ${1:-} == --gles ]] && soft=
mkdir -p work/save
xhost +local: >/dev/null
trap 'xhost -local: >/dev/null' EXIT
docker run --rm -it --network none --user "$(id -u):$(id -g)" \
    -v /tmp/.X11-unix:/tmp/.X11-unix -v "$here:/project" -w /project \
    -e DISPLAY="$DISPLAY" -e HOME=/tmp ${soft:+-e NFS4_SOFTWARE=1} \
    -e QEMU_LD_PREFIX=/usr/aarch64-linux-gnu \
    -e LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu \
    nfs4-arm64-builder:20.04 \
    qemu-aarch64 work/nfs4host.aarch64 work/game work/save
