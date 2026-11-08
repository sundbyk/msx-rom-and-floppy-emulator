msx-rom-and-floppy-emulator
===========================

This is a continuation of kernelcrash's MSX rom and floppy emulator:
https://github.com/kernelcrash/msx-rom-and-floppy-emulator (MIT licence, see LICENSE).
More about the original at https://www.kernelcrash.com/blog/emulating-roms-and-floppy-drives-in-msx/

New in this version (firmware 2.0, KCMFS 3):

- Bug fixes in the firmware, and the version shown in the menu with a build number.
- Upgrading from the SD card: a bootloader flashes upgrade.bin.
- KCMFS 3: folders, disk sets, search, file sizes, and runs on both MSX1 and MSX2.
- Roms from 128K up to 512K run from the STM32's flash.
- Tapes (.cas) load from the SD card, and snapshots (.msxsnap) for the 64K tapes that can not.
- Covers (SCREEN 2 pictures) in the menu, and a music player for .vgm files made from MIDI.
- tools/: organise_sd.py builds a tidy SD card from a collection, and test_roms.py,
  test_disks.py, test_tapes.py and test_snapshots.py try everything in openMSX.

All of it has been tested in openMSX. Little of it has been tried on a real MSX yet, so
the releases are marked as pre-releases.

The rest of this file is kernelcrash's original text, brought up to date.

Overview
--------

- Take a cheap STM32F407 board (US$10 or so). Wire it into an MSX cartridge slot..
- Make a FAT32 partition on a micro SD card and put rom and dsk images on it.
- Plug the micro SD into the STM32F4 board.
- The STM32F4 board presents a rom image in real time to the MSX/MSX2 computer such that it thinks a rom cartridge is attached.
- It also emulates a WD2793 floppy disk controller such that you can load disk images off the SD card. Two floppy drives are supported; A: and B:
- It also (optionally) partially emulates a RP5C01 RTC chip (enough of it to make an MSX2 computer boot if you don't have that chip). This is only really of use to me! Comment out the
 ENABLE_RTC_RAM_BANK_EMULATION line in the Makefile if you don't need this emulation.
- The code is still really 'proof of concept'. There is one button that allows you to cycle to the next rom or disk in a directory. Another button takes you to the previous rom or disk. However, I've added a simple boot menu mechanism where an MSX native program (kcmfs) presents a menu of files from the SD card and lets you boot from one of them.

I used an Omega MSX2 computer to test this. I have not tested it on any other MSX or MSX2 computers.
As I've discovered with this project there is quite a bit of variation with MSX and MSX2 systems, so
it helps to have 'low expectations'. My goal with this project was to do something 'technically 
interesting' and to 'run a few games' and then move on to some other project.

And yes you have to compile the firmware. It helps me enormously in terms of troubleshooting if you can 
set things up to compile the firmware from the source. Otherwise it's really hard to help people
diagnose issues. 

Wiring it
---------

Using a STM32F407VET6 or STM32F407VGT6 board ('B' means the buffered pin on the slot connector)
```
   PA1         - wire a button between it and GND. No need for a pullup. This is 'NEXT'
   PA2         - wire a button between it and GND. No need for a pullup. This is 'PREV'
   PE0 to PE15 - BA0 to BA15
   PD8 to PD15 - BD0 to BD7
   PC0         - _B_IORQ
   PC1         - _SLTSL1 or SLTSL2
   PC2         - _B_MREQ

   PC3         - _B_RD
   PC4         - _BUSDIR1 or 2 (only required if you are emulating the RP5C01 chip)

   GND         - GND
```
If you get a board with a microSD card slot, then this 'standard' wiring of the SD adapter
is fine.

I realise this is quite difficult as MSX has an edge connector socket, so you need to
either solder wires directly to the slot pins, or make up some kind of adapter with
an edge connector on it. I got around this by not soldering an edge connector at all 
in to my Omega MSX2 computer

Setting up the micro SD card
----------------------------

I tend to format a micro SD card with a smallish partition (less than 1GB) with 
FAT32. Create an msx directory in the root and add rom images and disk images 
to that directory. The order in which you copy the files to this directory
determines the order in which you can cycle through them (ie. its not 
alphabetical). 

Some limitations:

 - MSX has lots of different 'megarom mappers' in cartridges. I have only 
   implemented Konami4 (ie. Konami without an SCC), Konami5 (again without the SCC),
   Ascii8, Ascii16 and what I would call 'generic' 16K and 32K carts (ie. no mapper)
 - You have to rename the ROMs to include the mapper type (yep, I don't have
   any fancy database lookup). So something like this won't work:

     Treasure-of-Usas.rom

   But this will:

     Treasure-of-usas.konami4

   So the rules are:

     - ends in .konami4 then the rom is treated as Konami4
     - ends in .konami5 then the rom is treated as Konami5 (though there is no SCC emulated. This format is purely for carts that are in the KonamiWithSCC format and can operate with a PSG)
     - ends in .ascii8  then the rom is treated as Ascii8
     - ends in .ascii16 then the rom is treated as Ascii16
     - anything else is treated as a generic 16 or 32K rom.

  - Carts up to 128KB are loaded to RAM on the stm32f407 board. Bigger ones (up to 512KB) run
    from its flash instead, which needs the STM32F407VGT6 (1MB of flash); the VET6 (512KB)
    has no room for them. See "Roms over 128K" below.

Disk images should end in .dsk and should be either 737280 or 368640 bytes
in size. Normally you just copy .dsk images to the msx directory on the SD card.
You can mix these freely with the rom images.

However, the two drive support allows for some other options. If you 
create a subdirectory under the msx directory instead of just plonking a .dsk file
in, the subdirectory is treated as a collection of disk images. The subdirectory can
be called anything you like. Its name will show up in the kcmfs menu. If say you have a 
game and it has 'Game disk 1.dsk' and 'Game disk 2.dsk' then just copy them with their
original names into the subdirectory you made. Now when you select that subdirectory
from kcmfs, it will auto load the 'Game disk 1.dsk' into the A: drive as it is looking for
the text 'disk 1' or 'Disk 1' or 'disk1' or 'Disk1' in the text of the filename. The 2nd disk
'Game disk 2.dsk' isn't actually loaded in to the B: drive. I found most msx games don't seem
to want to look at the B: drive. Anyway, when the game asks for the 2nd disk, hit the NEXT button
and it will put 'Game disk 2.dsk' into the A: drive. Pressing PREV will switch it back to 
'Game Disk 1.dsk' . If you actually want to put something in to the B: drive it just has to be a 
file ending in '.dsk2'. If you had a 2 disk game and you had 'Game disk 2.dsk' in the A: drive, 
and then pressed NEXT, it will actually pop you out of the subdirectory and select the next
thing in the main list you see in kcmfs.

If all that sounded too complicated, just copy disk and rom files in to the msx directory. That
still works the same as previous versions.

Folders (version 2.0 of the firmware)

The msx directory can now be sorted into folders, eg. msx/ROMs/Konami, msx/DSKs/MSX 2 and so on.
A folder that holds .dsk files and nothing else that can be started (no folders, no roms) is
one game on several disks, as above. KCMFS shows it as a disk (cyan, with two disks on the marker)
and starts it on disk 1. Any other folder is a folder you can open in KCMFS.

 - Only .rom, .mx1, .mx2, .ri, .konami4, .konami5, .ascii8, .ascii16 (roms) and .dsk (disks) are
   used. Other files (.txt, pictures ...) can be left next to them. Hidden files and anything
   starting with a '.' (such as the ._ files macOS leaves behind) are skipped.
 - NEXT and PREV step through the roms, disks and disk sets in the folder you last started
   something from. In a disk set they step through its disks first.
 - Press NEXT and PREV together to get back to KCMFS. It starts when you reset the MSX.
 - A rom bigger than 128K runs from flash (below). Over 512K, or on a board with 512K of flash,
   it is not loaded (the one before stays).
 - 180K and 360K images are one sided (9 sectors a track), 720K two sided. Note that disk roms for
   3.5" drives, such as the NMS 8250 one, can not read 40 track (180K) disks at all. Copy their
   files to a 720K image instead (tools/organise_sd.py does this).
 - An 8K or 16K rom is put at 0x4000, or at 0x8000 if its header points there (eg. a BASIC
   rom). The rest of the slot reads 0xFF.
 - A rom without a mapper can be at most 32K: its first 16K is at 0x4000, the next 16K at 0x8000,
   and all of it again at 0x0000 and 0xC000 (the board does not look at A15). A 48K or 64K one
   that needs 0x0000-0xFFFF does not work. A few roms want another layout, such as their start at
   0x8000; tools/organise_sd.py rearranges the ones known (BOARD_LAYOUT).
 - tools/test_roms.py starts every rom in openMSX the way the board shows it, and with --reference
   the way openMSX' own database has it, so a wrong extension or layout shows up.

In order to use disks at all, you need a diskrom. Put one disk rom in the root
of the SD card called 'disk.rom'. I have only tested with the NMS8250 disk rom with MD5
0ed6dbd654da55b56dfb331dd3df82f0 . 

The disk ROM is technically a 'Disk BASIC ROM' so it means you need to get to BASIC
first. A lot of MSX machines boot straight to BASIC, so it's not an issue. But some machines
will boot to a menu first. You need to find the option to get to BASIC. As an example, the
Panasonic FS-A1 requires you to press F8 (shift F3) to get to BASIC, but it will let you
bypass this 'Deskpack' menu if you hold down DEL when the machine is booting.

Also, this project was mainly intended for MSX machines that did not have an internal
floppy drive controller already, but a recent reader indicated that holding down CTRL on
their MSX machine disables the use of the internal floppy disk controller, hence handing
over control to the disk ROM in the stm32f4 board.

The WD2793 floppy disk controller support was based on WD1793.c in fMSX by Marat Fayzullin. Note that:

 - Not all the chip is implemented. But most of the stuff you want is.
 - I haven't worked out how to make it think the disk has changed after a warm
   boot, so you need to power off /on to get a new image to load. However, in
   a multi-disk game it generally works OK if you press NEXT while the computer 
   is running.

There is also now a native MSX program (kcmfs) that presents a list of files on the
SD card, lets you select one and boot it. To use kcmfs you need to copy the menu.rom
file to the root of the SD card. After a reset of the STM32F4 board it will load
menu.rom instead of the first file in the msx directory. See the section on KCMFS 
for more information.

Here's an example of a mix of games on the SD card
```
  msx/SomeSimple32K.rom
  msx/AKomani4Rom.konami4
  msx/somegame.dsk
  msx/AKonami5Rom.konmai5
  msx/SomeGameDirectory
  msx/SomeGameDirectory/Blah Disk 1.dsk
  msx/SomeGameDirectory/Blah Disk 2.dsk
  msx/AnAscii8Rom.ascii8
  msx/SomeOtherGameDirectory
  msx/SomeOtherGameDirectory/Thing Disk1.dsk
  msx/SomeOtherGameDirectory/Thing Disk2.dsk
  msx/SomeOtherGameDirectory/Thing Disk3.dsk
  msx/SomeOtherGameDirectory/Thing Disk4.dsk
  msx/someinfocomgame
  msx/someinfocomgame/game.dsk
  msx/someinfocomgame/savedisk.dsk2
```

Making the SD card from a collection
------------------------------------

tools/organise_sd.py builds a whole SD card from an MSX collection (a folder of roms, disk
images, zips of BIN games and tapes, as found on many old CDs), without changing the collection:

    python tools/organise_sd.py --src <collection> --out <sd folder> --report <report folder> \
        --db <openMSX>/share/softwaredb.xml --diskrom nms8250_disk.rom --menu kcmfs/menu.rom \
        --msxdos <a disk with MSXDOS.SYS and COMMAND.COM>

It makes msx/MSX1/ROM, msx/MSX1/Disk, msx/MSX1/Kassett, msx/MSX2/ROM and msx/MSX2/Disk, and for
games that need an MSX2+ or a turbo R msx/MSX+ and msx/TurboR (test_disks.py and test_roms.py
start those on a Panasonic FS-A1WSX and FS-A1GT):

- Roms are looked up by SHA1 in openMSX's softwaredb.xml. That gives the name and the mapper,
  and so the extension (.rom .konami4 .konami5 .ascii8 .ascii16). One dump per game, the best one
  the firmware can run. Mappers it can not do (8kB, R-Type, Game Master 2, Koei) are left out.
- 180K disks are copied file by file to 720K. Images of several 720K disks in one file, .ddi
  (DiskDupe) and disks called .1, .2 ... are made plain .dsk. A game on several disks becomes a
  folder with Disk 1.dsk, Disk 2.dsk and so on (NEXT/PREV change disk).
- Compressed .xsa images are unpacked by openMSX: the first run writes xsa_to_dsk.tcl to the
  report folder. Run it (openmsx -script xsa_to_dsk.tcl) and then organise_sd.py again.
- BIN games (a BASIC loader and its BLOAD files) become a 720K disk with an AUTOEXEC.BAS that
  RUNs the loader (or BLOADs the program). .COM games get MSX-DOS and an AUTOEXEC.BAT. "CAS:" is
  taken out of loaders that ask for the tape. Games there is a rom or disk of already are left out.
- Covers: the cassette fronts in the tape zips and the pictures in covers/ (boxes and inlays) and
  Flyers/ (adverts) are matched to the games by name. Every version of a game (rom, disk, tape)
  gets one: Game.sc2 next to it, or cover.sc2 in a folder. tools/make_covers.ps1 makes them, and
  organise_sd.py runs it on Windows. Name matches it can not work out go in COVER_ALIASES.
- The report folder gets organise.csv (where everything went, and why things were left out),
  bin_disks.txt, covers.csv (which picture went with which game) and covers/ (the pictures, and a
  preview .png of each cover).

`--covers-only` makes the covers again for an SD card made before, from the report folder's
organise.csv, without building the rest again.

tools/test_disks.py then starts the disks it made in openMSX (MSX1 disks on a Philips VG-8020
with an NMS 1200 drive, MSX2 disks on an NMS 8250) and makes report.html with a screenshot of
each after 40 seconds, the ones that stopped with an error first.

Compiling the firmware
----------------------

Normally I use the ARM GNU Toolchain from developer.arm.com, but on modern linux distros you can actually
use the packaged up ARM cross compiler (for example on debian/ubuntu you might 'apt install gcc-arm-none-eabi').
I only use linux for compiling, so have no idea how to do it on other platforms.

You will need the STM32F4DISCOVERY board firmware package from st.com. This is called STSW-STM32068. Copy
its Libraries and Utilities folders to the directory 'above' this one (STM_COMMON=.. in the Makefile).
eg. on some folder you would see
```
   ./Libraries
   ./Utilities
   ./msx-rom-and-floppy-emulator
```
On Windows the compiler and make that come with STM32CubeIDE work (put their tools/bin folders
in the PATH).
To build
```
   cd msx-rom-and-floppy-emulator
   make
```
You should end up with a hex and bin file that you can then flash to the stm32f4 board. There's 
an example in the next section re using USB DFU mode to transfer it.

Compiling the code is not that hard, but I've also included a README-compiling.md file that provides some
more detailed help especially if you are not using linux.



Copying the firmware to the stm32f407 board
-------------------------------------------

There are lots of options for writing firmware with the stm32 chips. There is 
an example of using dfu-util in the transfer.sh script. In order for this to 
work you would need to set the BOOT0 and or BOOT1 settings such that plugging
the board in via usb will show a DFU device. Then you can run transfer.sh. Remove
the BOOT0 or BOOT1 jumpers after you do this.

If you are having trouble getting the board to appear as a DFU device, you can try
putting a pull down resistor between PA10 and GND (some value between 1K and 10K will
probably work).

The flash is split in two, and on a 1MB chip (STM32F407VGT6) three:

```
0x08000000 - 0x0800FFFF   SD card bootloader (bootloader/bl_main.c)
0x08010000 - 0x0807FFFF   the emulator
0x08080000 - 0x080FFFFF   a rom over 128K (sectors 8-11), see below
```

Roms over 128K

They do not fit in the board's RAM (64K of CCM and 64K of RAM hold the rest), so they are
written to flash sectors 8-11 and run from there, up to 512K. When one is started, the board
first reads it from the SD card and compares it with what is in flash; only if it differs are the
sectors erased and written, which takes up to 20 seconds or so (KCMFS says STARTING FROM FLASH).
The board does not answer the MSX while it erases or writes (its own code is in flash too), so
KCMFS waits in RAM for it to say it is done (PREPARE and "RDY!", see the protocol below). The
same rom again starts straight away, even after a power cycle. Started with NEXT/PREV instead,
whatever runs on the MSX goes wrong while the flash is written; reset it afterwards.

A rom's 8K banks are looked up in a table (bank_table, 64 entries) by the interrupt routine, for
roms in RAM too, so all of them go through the same code. Flash is a little slower to read than
RAM (wait states at 240MHz); not yet tried on a real MSX.

`make` builds both, plus these files:

- `msx-rom-and-floppy-emulator-full.bin` (and `.hex`): bootloader and emulator together.
  Write this to 0x08000000 the first time, with an ST-Link or over USB DFU (transfer.sh).
- `upgrade.bin`: the emulator on its own, for upgrading from the SD card.

Do not write `msx-rom-and-floppy-emulator.bin` on its own to 0x08000000. It is built to run at
0x08010000.

Upgrading from the SD card
--------------------------

Copy `upgrade.bin` to the root of the SD card and reset the stm32f4 board (or power it up).
The emulator sees the file, hands over to the bootloader, which flashes it, checks it and deletes
upgrade.bin. Then the board restarts with the new firmware. The LEDs on PA6/PA7 (the two LEDs of
the common STM32F407VET6 'black' board) flicker while it is flashing. The KCMFS menu shows the
firmware version in its top line.

- If the file is not an emulator image (for example the -full.bin by mistake) it is renamed to
  upgrade.bad and nothing is flashed.
- If the power goes during the upgrade, the bootloader sees there is no complete emulator and
  tries again at the next power up, as long as upgrade.bin is still on the card.
- A steady blink on PA6/PA7 means there is no working emulator and nothing to flash. Use DFU or
  an ST-Link.

KCMFS
-----

In the kcmfs directory is a Z80 assembly based MSX program that presents a menu to
the user. It lists the files in the msx directory of the SD card and let's 
you select one, and consequently reboots off it. If you put kcmfs (menu.rom) in
the root of the SD card, it will always boot menu.rom  after a reset of the
STM32F4 board.

KCMFS 3 runs on MSX1 and MSX2, in SCREEN 1. It shows one folder at a time, 19 entries to a
page, light yellow on black: ".." first (when you are below msx/), then the folders, then the
roms, disks, disk sets, tapes and music, each sorted by name. The marker in front of a name says
what it is: yellow folder, cyan disk (two disks for a disk set), magenta cartridge for a rom, green
cassette for a tape (.cas), blue notes for music (.vgm), white arrow for "..". It copes with up to 2048 entries per folder. Names are shown with up to 28 characters
(21 while the sizes are shown), without the extension. A small picture at the end of the line
means there is a cover. The top line shows the menu version, the firmware version and which
MSX it is running on. The bottom lines show the folder you are in (eg. /DSKs/MSX 2) and where
you are in the list.

When you come back to the menu it starts in the folder and on the entry you last started.

```
UP / DOWN       move up and down the list (wraps round). Held down, they repeat
LEFT / RIGHT    previous / next page
HOME            to the top of the list
letters, digits jump to the first name starting with what you have typed so far.
                A key that matches nothing is ignored
SPACE           show or hide the sizes (in K) on the right. Once you have started
                typing a name, SPACE is part of the name
TAB, SELECT     show the cover full screen. There the arrow keys go to the previous / next
                game with a cover, RETURN starts it and any other key goes back to the list
BS              take back the last letter typed, or up one folder
ESC             forget what was typed, or stop the music, or up one folder
RETURN          open the selected folder, start the selected rom, disk, disk set or tape, or
                play the selected music
```

Starting a disk needs disk.rom in the root of the SD card. Without it KCMFS says so.

Tapes (.cas)

Starting a .cas resets the MSX into BASIC with the tape in, and the command that loads it typed
for you, eg. DEFUSR=&H9000:A=USR(0):RUN"CAS:". RUN"CAS:" is for a BASIC loader saved as text,
CLOAD and RUN for tokenised BASIC, BLOAD"CAS:",R for machine code (whichever the first file on
the tape is); the USR(0) in front switches the tape in (below). From then on the MSX loads the
tape as it would from a cassette recorder, only a lot quicker, so BASIC loaders that load the
next parts, games in several parts and LOAD"CAS:" typed by hand all work. Reset the MSX to load
the tape again from the start. NEXT and PREV put the next or previous tape (or rom, or disk) in
the folder in its place, to start with a reset, and both together go back to the menu.

How: the board presents menu.rom again, with a flag in its control block. When the MSX starts,
menu.rom sees the flag and, instead of the menu, copies the BIOS from ROM into the RAM in page 0.
In the copy, the BIOS's TAPION and TAPIN (find a block, read a byte) are replaced by calls to
routines in menu.rom that read the .cas, which the board puts 64K at a time where the MSX can see
it. The USR(0) switches the copy in just before the load (it is in BASIC's program area until
then, which is why it is part of the command). So

- it needs 64K of RAM, in the same slot as page 3 (as nearly all MSX with 64K have it). Without
  that BASIC prints NO 64K RAM FOR TAPES.
- only what loads through the BIOS works. A game that uses all 64K (page 0 RAM included) and
  switches the BIOS ROM back in to load the rest loses the tape, and waits for a cassette for
  ever. Many 64K games from 1987 on do this (Eurosoft's, US Gold's, Ocean's). So do turbo
  loaders, but they can not be in a .cas file anyway.
- on an MSX2 whose RAM shares slot 3 with the SUB-ROM (eg. the NMS 8250), the BIOS calls the
  SUB-ROM for SCREEN, COLOR and the like through EXTROM, which menu.rom routes round the copy. A
  game that reads other slots through the BIOS itself (RDSLT and the like, eg. to look for RAM)
  loses the tape there.
- on an MSX with a disk drive, Disk BASIC takes a name without CAS: (BLOAD"GAME") to be on the
  disk, and the disk ROM takes memory. Hold SHIFT while the MSX starts to leave the disk ROM out,
  as you would for a real tape.

Snapshots of tapes (.msxsnap)

For the tapes this can not load (the 64K ones above) there is a snapshot instead: the whole MSX
(64K of RAM, VRAM, the VDP, PSG and Z80 registers) just after the tape has loaded in openMSX.
Starting one puts it all back and the game carries on from there. It is shown with the cassette
marker too. tools/cas_snapshot.py makes them (a Philips VG-8020 loads the
tape with openMSX's own cassette player, and the snapshot is taken after the motor goes off for
the last time, once the CPU is in the game's code in RAM rather than in the BIOS, so it does not
depend on one BIOS), and tools/organise_sd.py --snapshots puts them next to the tapes on the SD
card, the .cas going into a "Virker ikke" folder below. tools/test_snapshots.py tries them in
openMSX with menu.rom's own code (--as MSX2 on an NMS 8250).

How: as for a tape, the board presents menu.rom again with a flag (0x800B), the snapshot's RAM in
banks 8-15, its VRAM in banks 3-4 and its registers in bank 5. menu.rom puts back VRAM, the VDP
and PSG registers and RAM pages 0 and 2, then page 3 (its own stack and variables with it) and
jumps to a routine in the control block, which the board shows at 0x0000 too. That puts back page
1 and the registers and jumps to a stub of 9 bytes below the game's stack: OUT (0xA8) for the
game's slots, POP AF, EI, RET to the game. So

- the game's RAM goes into the RAM of page 3's slot, and the pages that were the BIOS ROM into the
  main ROM's slot. The 9 bytes below the game's stack are lost (the stub).
- the MSX's own slot tables (EXPTBL, SLTTBL) stay, and on an MSX2 its own MSX2 system variables
  (DPPAGE to LOGOPR, RG8SAV to 0xFFFE, unless the game's stack is there) and the secondary slot
  register at 0xFFFF. RAMAD0-3, which many loaders (Eurosoft's) set to the RAM's slot, get this
  MSX's. So a snapshot of an MSX1 runs on an MSX2 too: on the NMS 8250, 27 of the 30 on the card.
- a game that switches slots with what it worked out while it loaded, beyond RAMAD0-3, has the
  VG-8020's (RAM in slot 3, not expanded). Life in the Fast Lane, Eagle Control and Red Dawn
  write the secondary slot register themselves, which on an MSX with its RAM in an expanded slot
  (the NMS 8250) takes the RAM away.

Music (.vgm)

KCMFS plays .vgm files (marked with two notes) on the MSX's own PSG, so it works on any MSX. RETURN
starts one; the music goes on while you move about the list, look at covers or open folders, and
at the end of a song the next one in the folder follows. ESC stops it, as does starting a game.
VGM is the usual format for chip music: only what it has for the AY-3-8910 (the PSG) is played,
so a rip with FM (MSX-Music) or SCC parts in it plays only its PSG part. Unpack .vgz files first.

tools/mid2vgm.py makes a .vgm from a MIDI file: the melody (the highest note playing), the bass
(the lowest) and the drums as noise, or a third note where there are no drums. tools/organise_sd.py
does this for the MIDI files in the collection's Midis folder, into msx/Musikk (--music-only to do
just that). The board hands the file over 16K at a time (command 0x02 below), into two halves of
the bank window: one is played while the next chunk goes into the other.

tools/test_tapes.py loads every .cas in openMSX this way (with kcmfs/menu-simtape.rom, an ASCII8
rom with the tape put in it, since there is no board) and makes report.html with a screenshot of
each. --reference loads them with openMSX's own cassette player instead, to see which tapes work
at all, and --shift holds SHIFT at the start. tools/casinfo.py lists what is on a tape. Of the
181 tapes in the collection, on a Philips VG-8020 about 150 come up as they do from a real
cassette, about 30 do not (the 64K ones above), and a few do not work from a real cassette
either.

Covers

A cover is a SCREEN 2 picture (256x192, 15 colours, two colours in each row of 8 pixels), saved
as BSAVE "GAME.SC2",0,&H37FF,S saves it, so BLOAD"GAME.SC2",S shows it in BASIC too and
pictures made with other MSX tools work. It is Game.sc2 next to Game.rom (or .dsk, .cas ...), or
cover.sc2 in a folder (for a disk set or a folder, the one inside it). tools/make_covers.ps1 makes
them from a scanned box, inlay or advert:

    powershell -ExecutionPolicy Bypass -File tools/make_covers.ps1 -One box.jpg -Out Game.sc2 -Preview

(-Crop cuts the front out of a whole cassette inlay, -Preview also writes Game.png to look at).

menu.rom is 16K. kcmfs/build.sh assembles it with sjasmplus
(https://github.com/z00m128/sjasmplus). It also builds menu-sim.rom (32K), which has a list of
made up names and kcmfs/sim-cover.sc2 and kcmfs/sim-song.vgm built in, so you can try the menu
out in openMSX without the stm32f4 board. Those two are not in the repository: make a
sim-cover.sc2 with tools/make_covers.ps1 and a sim-song.vgm (4K at most) with tools/mid2vgm.py.

The top line reads eg. `KCMFS 3.0.7  FW 2.0.12  MSX2`. The last number of each is a build number
that counts up by itself: `make` keeps the firmware's in build_number, and kcmfs/build.sh keeps
the menu's in kcmfs/build_number. Bump the first part (FIRMWARE_VERSION in defines.h, title in
menu.asm) for new features.

The protocol. While menu.rom is presented, the stm32f4 shows the MSX

```
0x8000-0x9FFF   a control block (CCM 0x4000-0x5FFF). 0x8000-0x80FF can be written
0xA000-0xBFFF   an 8K bank of the stm32f4's RAM, picked by writing its number to 0x8001.
                The folder list is in banks 8 to 15, a cover in banks 4 and 5
0x6000-0x7FFF   while a snapshot is put back: the bank written to 0x8002
0x0000-0x3FFF   the same as 0x8000-0xBFFF (the board only looks at A13 and A14)
```

The control block:

```
0x8000        - command. kcmfs writes it, the stm32f4 sets it to 0 when it is done
                  0x80  list the folder the menu was last in
                  0x20  open the folder (or "..") whose entry number is at 0x8080
                  0x40  start the rom, disk, disk set, tape or snapshot whose entry number is
                        at 0x8080
                  0x10  load the cover of the entry whose number is at 0x8080: its patterns
                        (6144 bytes) into bank 4 and its colours into bank 5
                  0x08  load 64K of the tape, from the 8K block whose number is at 0x8084,
                        into banks 8 to 15
                  0x04  get ready to start the entry at 0x8080: a rom over 128K is written to
                        flash. "RDY!" at 0x8060 when it is done
                  0x02  load 16K chunk 0x8086 of a song into banks 3-4 (0x8088 = 0) or 5-6
                        (0x8088 = 1). Chunk 0 is of the entry at 0x8080, the later ones of the
                        same file. Past its end it reads 0x66 (VGM's end)
0x8001        - 8K bank to show at 0xA000
0x8002/0x8003 - number of entries (low byte first). Written: 8K bank to show at 0x6000
0x8004/0x8005 - entry to start on
0x8006        - flags. Bit 0: there is no disk.rom. Bit 1: no room in flash for roms over 128K
0x8008        - 1 if 0x10 found a cover, 0 if not
0x800A        - 1 if a tape (.cas) was started: menu.rom sets up the tape instead of the menu
0x800B        - 1 if a snapshot (.msxsnap) was started: menu.rom puts it back instead
0x800C-0x800F - the size of the tape
0x8010        - firmware version, 0 terminated
0x8020        - folder shown, below msx/, eg "/DSKs/MSX 2". Empty at the top. At most the
                last 31 characters, 0 terminated. While a snapshot is put back, the MSX's own
                system variables that stay
0x8064-0x80FF - while a snapshot is put back: AF', the stub and the routine that ends it
0x8060-0x8063 - "RDY!" after 0x04. kcmfs clears it first
0x8080/0x8081 - entry number for 0x02, 0x04, 0x10, 0x20 and 0x40, written by kcmfs
0x8084/0x8085 - 8K block of the tape for 0x08
0x8086/0x8087 - 16K chunk of the song for 0x02
0x8088        - half of the window for 0x02
```

Entry n is in bank 8 + n/256, at 0xA000 + (n%256)*32:

```
byte 0      'U' for "..", 'F' for a folder, 'D' for a disk image, 'S' for a disk set,
            'R' for a rom, 'T' for a tape, 'M' for music (.vgm), 'P' for a snapshot (.msxsnap)
byte 1-29   the name without the extension, 0 terminated (at most 28 characters)
byte 30-31  the size in K, low byte first, 15 bits. 0 for folders and disk sets. Bit 15 is
            set if there is a cover
```

For 0x40 the rom (menu) goes away under the Z80 while the stm32f4 loads the new one, so kcmfs
copies a few bytes to RAM at 0xE100 and runs them: they clear 0x8060, write 0x04 and wait for
all four bytes of "RDY!" there (while flash is written the bus reads 0xFF now and then, which a
single byte could be mistaken for), then write the 0x40, wait until 0x8000 no longer reads 0x40
(the new rom is there), wait a moment more and reset the MSX.


Technical
---------

PC2 will interrupt on the -ve edge of _MREQ. I've used a different technique in the past,
such that the _MREQ int is on the +ve edge. That former technique gives better timing
outcomes for the _MREQ processing at the expense of reducing the time available to the
main while() loop. MSX adds wait states such that an M1 is low for 560ns and a regular
memory access is 690ns. On the stm32f407 @ 240MHz, its around 100ns best case until the
first line of the interrupt handler, so we are not as pressed for time as some other Z80A
systems. ie. we can 'get away' with the interrupt on the -ve edge. Note though that the 
interrupt handling code is written in ARM assembly.

The interrupt handler makes heavy use of floating point registers that are used as
general purpose global constants and pointers. This means the interrupt handler does
not need to push any registers (On ARM, r0-r3 and r12 are automatically pushed 
whether you like it or not though). The fpu registers are effectively used as high speed RAM. 
Here's an example;
```
   // grab the pointer to GPIOA from s11
   vmov	r1,s11
   // s1 is preset to the value '1'. Send PA0 high
   vstr s1,[r1,ODR]
```
There are thirty two 32 bit fpu registers (s0 to s31). I have used most of them, though
I noticed that gcc tends to want to do weird things with s16, s17, s18 and s19 (d8 and d9),
so I tend to avoid those.

As far as the decision process for an _MREQ int;

 - work out if its a false int. Sometimes this happens as edges of signals from the Z80A
   can appear a bit rough to the stm32f4
 - see if the _SlotSelect signal is low. If its not then exit.
 - Next we need to figure out if we're simply emulating a normal ROM cart, or whether
   we're emulating a disk rom, and will be using disk images. At the moment its one or the
   other. If you want disks then you can't have other carts as the only ROM being emulated
   will be the disk ROM (which is a basic 16k ROM).
 - So if its a disk ROM, then we emulate the 16K disk ROM, and also enable access to the 
   emulated floppy disk controller at 0x7ff8-0x7fff (replicated at 0xbff8-0xbfff)
 - If its a ROM cartridge, then we need to quickly translate any 'Mapper' bank selection
   such that the appropriate 8K block is presented. Conversely a 'write' allows the ROM
   to write to the Mapper bank registers (which differ depending on the Mapper type).



