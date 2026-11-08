#!/bin/sh
# Run from the kcmfs folder. Needs sjasmplus (https://github.com/z00m128/sjasmplus), either in
# the PATH or named by SJASMPLUS, eg.
#   SJASMPLUS=/d/user-data/winapps/sjasmplus-1.24.0/sjasmplus-1.24.0.win/sjasmplus.exe sh build.sh
SJASMPLUS=${SJASMPLUS:-sjasmplus}

# Count the build number up. It goes after the version in the menu's title, eg. "KCMFS 3.0.7"
n=$(( $(cat build_number 2>/dev/null || echo 0) + 1 ))
echo $n > build_number
echo "	db	\"$n\"" > build.inc

# menu.rom (16K). Copy it to the root of the SD card.
"$SJASMPLUS" --nologo --msg=war --lst=menu.lst menu.asm || exit 1

# Same menu with a built in list of names and sim-cover.sc2 as every cover (32K), for trying it
# out in an emulator such as openMSX
"$SJASMPLUS" --nologo --msg=war -DSIM menu.asm || exit 1

# The tape part on its own, for ../tools/test_tapes.py to put a .cas in and try in openMSX
"$SJASMPLUS" --nologo --msg=war -DSIMTAPE menu.asm || exit 1
