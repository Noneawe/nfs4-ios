#!/bin/bash
nfs4_ports_dir=$(cd -- "$(dirname -- "$0")" && pwd)
XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ -d /opt/system/Tools/PortMaster ]; then
    controlfolder=/opt/system/Tools/PortMaster
elif [ -d /opt/tools/PortMaster ]; then
    controlfolder=/opt/tools/PortMaster
elif [ -d "$XDG_DATA_HOME/PortMaster" ]; then
    controlfolder="$XDG_DATA_HOME/PortMaster"
else
    controlfolder=/roms/ports/PortMaster
fi
if [ ! -f "$controlfolder/control.txt" ]; then
    echo 'Nie znaleziono PortMaster/control.txt.' >&2
    exit 2
fi
source "$controlfolder/control.txt"
[ ! -f "$controlfolder/mod_${CFW_NAME}.txt" ] || source "$controlfolder/mod_${CFW_NAME}.txt"
get_controls
GAMEDIR="$nfs4_ports_dir/nfs4"
cd "$GAMEDIR" || exit 2
exec > >(tee "$GAMEDIR/log.txt") 2>&1
trap 'pm_finish' EXIT
source "$GAMEDIR/profile.sh" || exit 2
export SDL_GAMECONTROLLERCONFIG="${sdl_controllerconfig:-${SDL_GAMECONTROLLERCONFIG:-}}"
export LD_LIBRARY_PATH="$GAMEDIR/libs.aarch64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [ "${DEVICE_ARCH:-$(uname -m)}" != aarch64 ]; then
    echo 'Ta paczka wymaga Linuksa ARM64.'
    exit 2
fi
binary="$GAMEDIR/nfs4host.aarch64"
if [ ! -x "$binary" ]; then
    echo 'Brakuje nfs4host.aarch64. Zbuduj i zainstaluj pełną paczkę ARM64.'
    exit 2
fi
if type pm_platform_helper >/dev/null 2>&1; then pm_platform_helper "$binary"; fi
case "${1:-}" in
    --self-test|--gpu-self-test|--controller-self-test|--profile-self-test)
        "$binary" "$1"
        exit $?
        ;;
    "") ;;
    *) echo 'Nieznany argument.'; exit 2 ;;
esac
if [ ! -f "$GAMEDIR/game/data/text/mam.dat" ]; then
    echo 'Skopiuj zawartość przygotowanego katalogu work/game do nfs4/game.'
    exit 2
fi
mkdir -p "$GAMEDIR/save" || exit 2
"$binary" "$GAMEDIR/game" "$GAMEDIR/save"
