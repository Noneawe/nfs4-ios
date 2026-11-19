#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 2 ]]; then
    echo "Użycie: $0 <katalog z kodem recomp/> <plik wynikowy>" >&2
    exit 2
fi
root=$(cd -- "$1" && pwd)
output=$(realpath -m -- "$2")
here=$(cd -- "$(dirname -- "$0")" && pwd)
python3 "$here/patch-runtime.py" "$root"
export CC="${CC:-gcc}"
target=$("$CC" -dumpmachine)
obj="$root/recomp/build/$target${OBJ_SUFFIX:-}"
mkdir -p -- "$obj" "$(dirname -- "$output")"
src=("$root"/recomp/gen/*/*.c "$root"/recomp/runtime/*.c "$here/plat_linux.c" "$here/gpu_gles.c" "$here/input_sdl.c" "$here/input_touch.c")
if [[ ! -f ${src[0]} ]]; then
    echo 'Brakuje wygenerowanego kodu C.' >&2
    exit 2
fi
pkg_config=${PKG_CONFIG:-pkg-config}
export root obj sdl_cflags="${SDL_CFLAGS:-$("$pkg_config" --cflags sdl2)} ${GLES_CFLAGS:-$("$pkg_config" --cflags glesv2 egl)}"
export gen_opt=${GEN_OPT:--O0}
[[ $target != aarch64* ]] || gen_opt=${GEN_OPT:--O2}
read -r -a sdl_libs <<< "${SDL_LIBS:-$("$pkg_config" --libs sdl2)} ${GLES_LIBS:-$("$pkg_config" --libs glesv2 egl)}"
compile() {
    local source=$1 module file opt
    local -a cflags
    module=$(basename -- "$(dirname -- "$source")")
    file=$(basename -- "$source" .c)
    opt=-O2
    [[ $source != "$root"/recomp/gen/* ]] || opt=$gen_opt
    read -r -a cflags <<< "$sdl_cflags"
    "$CC" -std=gnu11 "$opt" -fno-strict-aliasing -fwrapv \
        -I"$root/recomp/runtime" -I"$root/recomp/gen/nfs4" \
        -I"$root/recomp/gen/v2a" -I"$root/recomp/gen/eacsnd" \
        "${cflags[@]}" ${EXTRA_CFLAGS:-} -pthread -c "$source" -o "$obj/${module}_${file}.o"
}
export -f compile
printf '%s\0' "${src[@]}" | xargs -0 -r -P "${JOBS:-4}" -n 1 bash -c 'compile "$1"' _
"$CC" -o "$output" "$obj"/*.o "${sdl_libs[@]}" -lm -pthread
