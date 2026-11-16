#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
work="$here/work"
if [[ ! -x $work/nfs4host ]]; then
    echo 'Najpierw uruchom ./setup.sh <folder gry>.' >&2
    exit 2
fi
if [[ ${1:-} == --self-test && $# == 1 ]]; then
    exec env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software "$work/nfs4host" --self-test
fi
if [[ ${1:-} == --gpu-self-test && $# == 1 ]]; then
    exec "$work/nfs4host" --gpu-self-test
fi
if [[ ${1:-} == --controller-self-test && $# == 1 ]]; then
    exec env SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software "$work/nfs4host" --controller-self-test
fi
if [[ ${1:-} == --profile-self-test && $# == 1 ]]; then
    exec "$work/nfs4host" --profile-self-test
fi
if [[ $# != 0 ]]; then
    echo "Użycie: $0 [--self-test | --gpu-self-test | --controller-self-test | --profile-self-test]" >&2
    exit 2
fi
if [[ ! -f $work/game/data/text/mam.dat ]]; then
    echo 'Brakuje DATA/Text/mam.dat z gry. Uruchom ./setup.sh ze ścieżką do kopii PC.' >&2
    exit 2
fi
"$work/nfs4host" "$work/game" "$work/save" 2>&1 | tee "$work/nfs4host.log"
