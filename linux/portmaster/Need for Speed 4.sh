#!/bin/bash

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi

source $controlfolder/control.txt
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

GAMEDIR=/$directory/ports/nfs4
BINARY=nfs4host.${DEVICE_ARCH}

cd $GAMEDIR

> "$GAMEDIR/log.txt" && exec > >(tee "$GAMEDIR/log.txt") 2>&1

source "$GAMEDIR/profile.sh"
export LD_LIBRARY_PATH="$GAMEDIR/libs.${DEVICE_ARCH}:$LD_LIBRARY_PATH"
export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"

case "${1:-}" in
  --self-test|--gpu-self-test|--controller-self-test|--profile-self-test)
    ./$BINARY "$1"
    exit $?
    ;;
esac

if [ ! -f "$GAMEDIR/game/data/text/mam.dat" ]; then
  pm_show_error "Copy the contents of the prepared game folder (lowercase file names, NFS4 Modern Patch applied) to ports/nfs4/game/ and launch the game again." --title "Game files missing" --type warning
  exit 1
fi

mkdir -p "$GAMEDIR/save"

$GPTOKEYB2 "$BINARY" > /dev/null 2>&1 &

pm_platform_helper "$GAMEDIR/$BINARY"

./$BINARY "$GAMEDIR/game" "$GAMEDIR/save"

pm_finish
