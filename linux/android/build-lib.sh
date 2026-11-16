#!/usr/bin/env bash
# Kompiluje libmain.so (gra + warstwa SDL2/GLES) dla Androida. Użycie: build-lib.sh <abi> <katalog SDL2 src> <katalog sdl build> <out>
set -euo pipefail
abi=$1 sdlsrc=$2 sdlbuild=$3 out=$4
here=$(cd -- "$(dirname -- "$0")/.." && pwd)
ndk=${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/28.2.13676358}
tc=$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
case $abi in arm64-v8a) triple=aarch64-linux-android24;; x86_64) triple=x86_64-linux-android24;; *) exit 2;; esac
export CC=$tc/$triple-clang
root=$here/work/source/recomp/..
root=$(cd "$root" && pwd)
python3 "$here/patch-runtime.py" "$root"
obj=$root/recomp/build/android-$abi
mkdir -p "$obj" "$(dirname "$out")"
src=("$root"/recomp/gen/*/*.c "$root"/recomp/runtime/*.c "$here/plat_linux.c" "$here/gpu_gles.c" "$here/input_sdl.c" "$here/input_touch.c")
export root obj sdlsrc
compile() {
    local s=$1 module file opt=-O2
    module=$(basename "$(dirname "$s")"); file=$(basename "$s" .c)
    "$CC" -std=gnu11 $opt -fPIC -fno-strict-aliasing -fwrapv -w \
        -I"$root/recomp/runtime" -I"$root/recomp/gen/nfs4" -I"$root/recomp/gen/v2a" -I"$root/recomp/gen/eacsnd" \
        -I"$sdlsrc/include" -pthread -c "$s" -o "$obj/${module}_${file}.o"
}
export -f compile
printf '%s\0' "${src[@]}" | xargs -0 -r -P "${JOBS:-6}" -n 1 bash -c 'compile "$1"' _
"$CC" -shared -o "$out" "$obj"/*.o -L"$sdlbuild" -lSDL2 -lGLESv3 -lEGL -llog -landroid -lm -pthread \
    -Wl,-z,max-page-size=16384 -Wl,--no-undefined
