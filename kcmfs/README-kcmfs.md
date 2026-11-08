KCMFS
=====

Native MSX based file selector that interacts with the kernelcrash msx-rom-and-floppy
emulator to let you choose rom or disk images. Runs on MSX1 and MSX2.

Keys, the folder handling and the protocol are in the KCMFS section of ../README.md.

Assembly and Setup
==================

Requires sjasmplus (https://github.com/z00m128/sjasmplus). From this folder:

    sh build.sh

or, if sjasmplus is not in the PATH,

    SJASMPLUS=/path/to/sjasmplus sh build.sh

That gives

 - menu.rom (16K). Copy it to the root of the SD card.
 - menu-sim.rom (32K), the same menu with a made up list built in, for trying it out in an
   emulator (eg. `openmsx -carta menu-sim.rom`). ENTER only shows what it would start. Every
   cover in it is sim-cover.sc2 (any cover made with ../tools/make_covers.ps1 will do), and every
   song sim-song.vgm (any .vgm of 4K or less, eg. made with ../tools/mid2vgm.py).
 - menu-simtape.rom, only the tape part, for ../tools/test_tapes.py to put a .cas into and
   load in openMSX.

Each build counts build_number up; it is the last part of the version on the menu's top line.
