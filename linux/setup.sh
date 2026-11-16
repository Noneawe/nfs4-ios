#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "Użycie: $0 <folder z DATA gry | --build-only> [nfs4_modern_patch.7z]" >&2
    exit 2
fi
if [[ $(uname -s) != Linux || ! $(uname -m) =~ ^(x86_64|aarch64)$ ]]; then
    echo 'Budowanie wymaga Linuksa x86-64 lub ARM64.' >&2
    exit 2
fi
here=$(cd -- "$(dirname -- "$0")" && pwd)
if [[ ${NFS4_SOURCE_ONLY:-0} == 1 && -e $here/work/source ]]; then
    echo 'Katalog work/source już istnieje; użyj istniejących źródeł do budowy ARM64.' >&2
    exit 2
fi
original=$1
if [[ $original != --build-only ]]; then
    original=$(cd -- "$original" && pwd)
    if [[ -z $(find "$original" -mindepth 1 -maxdepth 1 -type d -iname data -print -quit) ]]; then
        echo 'Wskaż katalog główny kopii gry, zawierający podkatalog DATA.' >&2
        exit 2
    fi
fi
seven_zip=$(command -v 7zz || command -v 7z || command -v 7za || true)
if [[ -z $seven_zip ]]; then
    echo 'Zainstaluj 7zip lub p7zip-full.' >&2
    exit 2
fi
if [[ ${NFS4_SOURCE_ONLY:-0} != 1 ]]; then
    if ! pkg-config --exists glesv2 egl || ! command -v "${CC:-gcc}" >/dev/null ||
        { [[ -z ${SDL_CFLAGS:-} || -z ${SDL_LIBS:-} ]] && ! pkg-config --exists sdl2; }; then
        echo 'Zainstaluj build-essential pkg-config libsdl2-dev libgles2-mesa-dev libegl1-mesa-dev.' >&2
        exit 2
    fi
fi
work="$here/work"
mkdir -p -- "$work"
temp=$(mktemp -d "$work/setup.XXXXXX")
trap 'rm -rf -- "$temp"' EXIT
commit=e318f058b5086d7820f6881a76f35d0dc2f03cec
patch_sha=cb4d34ff0e8be17c4b236ac58857f89442dd9a937235e2c1bb4397fa1bd6e015
if [[ $# == 2 ]]; then
    patch=$(realpath -- "$2")
else
    patch="$work/nfs4_modern_patch.7z"
    if [[ ! -f $patch ]]; then
        curl -fLsS --retry 2 --max-time 90 https://veg.by/files/nfs4/nfs4_modern_patch.7z -o "$temp/veg.7z"
        mv -- "$temp/veg.7z" "$patch"
    fi
fi
printf '%s  %s\n' "$patch_sha" "$patch" | sha256sum --check --status || {
    echo 'Archiwum nie odpowiada wersji VEG Modern Patch v0.1.0 użytej do testu.' >&2
    exit 2
}
if [[ ! -f $work/upstream.tar.gz ]]; then
    curl -fLsS --retry 2 --max-time 90 "https://codeload.github.com/avoseed/nfs4-ios/tar.gz/$commit" -o "$temp/upstream.tar.gz"
    mv -- "$temp/upstream.tar.gz" "$work/upstream.tar.gz"
fi
mkdir -p -- "$temp/veg" "$temp/upstream"
"$seven_zip" x -y "-o$temp/veg" "$patch" >/dev/null
tar -xzf "$work/upstream.tar.gz" -C "$temp/upstream" --strip-components=1
python3 "$here/prepare-data.py" "$temp/veg" "$temp/upstream" "$temp/game" "$original"
if [[ $original != --build-only && ! -f $temp/game/data/text/mam.dat ]]; then
    echo 'Brakuje DATA/Text/mam.dat. Wskaż kompletną kopię danych pecetowej gry.' >&2
    exit 2
fi
if [[ ! -x $work/venv/bin/python ]]; then
    python3 -m venv "$work/venv"
fi
"$work/venv/bin/python" -m pip install --disable-pip-version-check pefile==2024.8.26 capstone==5.0.7
if ! "$work/venv/bin/python" -B "$temp/upstream/tools/recompile.py"; then
    cat "$temp/upstream"/logs/*-recompile.log >&2
    exit 1
fi
if [[ ${NFS4_SOURCE_ONLY:-0} == 1 ]]; then
    mv -- "$temp/upstream" "$work/source"
    echo 'Źródła i wygenerowany C gotowe w work/source.'
    exit 0
fi
"$here/build-native.sh" "$temp/upstream" "$temp/nfs4host"
SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software "$temp/nfs4host" --self-test
mkdir -p -- "$work/save"
if [[ $original != --build-only || ! -d $work/game ]]; then
    rm -rf -- "$work/game"
    mv -- "$temp/game" "$work/game"
fi
mv -- "$temp/nfs4host" "$work/nfs4host"
cp -- "$temp/upstream"/logs/*-recompile.log "$work/"
if [[ $original == --build-only ]]; then
    printf 'Gotowe. Test hosta: ./run.sh --self-test\n'
else
    printf 'Gotowe. Uruchom ./run.sh\n'
fi
