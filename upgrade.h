// Shared between the emulator and the SD card bootloader (bootloader/bl_main.c)
//
// Flash layout
//   0x08000000 - 0x0800FFFF  bootloader (sectors 0-3)
//   0x08010000 - 0x0807FFFF  emulator   (sectors 4-7). Fits both the STM32F407VE (512K) and VG (1M)
#ifndef __UPGRADE_H
#define __UPGRADE_H

#define APP_BASE		0x08010000
#define APP_MAX_SIZE		(448*1024)

// The emulator writes UPGRADE_MAGIC here and resets when it finds UPGRADE_FILENAME on the SD card.
// The top of CCM is not touched by either startup code, and survives a reset. The emulator
// checks it before it loads a rom into CCM. Should a rom ever leave UPGRADE_MAGIC there, the
// bootloader just finds no upgrade.bin and carries on
#define UPGRADE_FLAG_ADDR	0x1000FFF0
#define UPGRADE_MAGIC		0x55504752	// "UPGR"
#define UPGRADE_NO_RETRY	0x4E4F5254	// "NORT". Bootloader has had a go this power cycle. Don't ask again
#define UPGRADE_FILENAME	"upgrade.bin"
#define UPGRADE_BAD_FILENAME	"upgrade.bad"

#endif
