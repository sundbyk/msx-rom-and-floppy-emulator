// defines
//
// This needs to be able to be included from C and asm. defines work in .S and .c files

// Stringify functions
#define XSTR(x) STR(x)
#define STR(x) #x

// true/false
#define TRUE 1
#define FALSE 0

// registers
#define reg_zero	s0
#define reg_bit0_high	s1
#define reg_bit1_high	s2
#define reg_gpioc_base	s3
#define reg_bit2_high	s4

#define reg_gpioa_base	s5
// bank_table: 64 pointers, where each 8K bank of the rom is (CCM, high_64k_base or flash)
#define reg_bank_table	s6
#define reg_exti_base	s7
#define reg_moder_dataout	s8
#define reg_moder_datain	s9
// reg_mapper_pages. The page is 8K, at 0x4000, 0x6000, 0x8000 or 0xA000 (A14 and A13)
//   b31/b30/b29 - rom type
//   b23-b18 - 0x6000 bank (8K)
//   b17-b12 - 0x4000 bank
//   b11-b6  - 0xA000 bank
//   b5 -b0  - 0x8000 bank
#define reg_mapper_pages	s10
#define PAGEMAP(b4000, b6000, b8000, bA000)	(((b4000) << 12) | ((b6000) << 18) | (b8000) | ((bA000) << 6))
#define reg_rowcache	s11
#define reg_gpiob_base	s12
#define reg_bit6_high	s13
#define reg_ccmram_log	s14

#define reg_fdc_status	s15
// NOTE: FPU registers d8 and d9 are used somehow, so you cannot use s16,s17,s18 and s19


#define reg_fdc_write_length	s20
#define reg_fdc_system	s21
#define reg_bit8_high	s22
#define reg_track_buffer_ptr	s23
#define reg_fdc_track	s24
#define reg_fdc_intended_track	s25
#define reg_fdc_sector	s26
#define reg_fdc_data	s27

#define reg_fdc_irq_drq	s28
#define reg_fdc_command	s29

#define reg_fake_stack	s30

#define reg_fdc_read_length	s31

// the thread command is a special one. Its hard to use a floating reg from C when we disable the FPU
#define reg_main_thread_command	r10

// ============================
//
#define         IORQ_MASK             0x0001       // ie PC0
#define         SLOT_SELECT_MASK      0x0002       // ie PC1
#define         MREQ_MASK             0x0004       // ie PC2
#define         RD_MASK               0x0008       // ie PC3
#define         BUSDIR_HIGH           0x0010       // ie PC4

// =============================
#define		NEXT_ROM_OR_DISK_MASK 0x0002	   // PA1
#define		PREV_ROM_OR_DISK_MASK 0x0004	   // PA2
// =============================

#define		MREQ_PREEMPTION_PRIORITY	0
#define		IORQ_PREEMPTION_PRIORITY	1
#define		SDIO_IRQ_PREEMPTION_PRIORITY	3
#define		SDIO_DMA_PREEMPTION_PRIORITY	4


// ============================
// straight from fMSX
//
                           /* Common status bits:               */
#define F_BUSY     0x01    /* Controller is executing a command */
#define F_READONLY 0x40    /* The disk is write-protected       */
#define F_NOTREADY 0x80    /* The drive is not ready            */

                           /* Type-1 command status:            */
#define F_INDEX    0x02    /* Index mark detected               */
#define F_TRACK0   0x04    /* Head positioned at track #0       */
#define F_CRCERR   0x08    /* CRC error in ID field             */
#define F_SEEKERR  0x10    /* Seek error, track not verified    */
#define F_HEADLOAD 0x20    /* Head loaded                       */

                           /* Type-2 and Type-3 command status: */
#define F_DRQ      0x02    /* Data request pending              */
#define F_LOSTDATA 0x04    /* Data has been lost (missed DRQ)   */
#define F_ERRCODE  0x18    /* Error code bits:                  */
#define F_BADDATA  0x08    /* 1 = bad data CRC                  */
#define F_NOTFOUND 0x10    /* 2 = sector not found              */
#define F_BADID    0x18    /* 3 = bad ID field CRC              */
#define F_DELETED  0x20    /* Deleted data mark (when reading)  */
#define F_WRFAULT  0x20    /* Write fault (when writing)        */

#define C_DELMARK  0x01
#define C_SIDECOMP 0x02
#define C_STEPRATE 0x03
#define C_VERIFY   0x04
#define C_WAIT15MS 0x04
#define C_LOADHEAD 0x08
#define C_SIDE     0x08
#define C_IRQ      0x08
#define C_SETTRACK 0x10
#define C_MULTIREC 0x10

#define S_DRIVE    0x03
#define S_RESET    0x04
#define S_HALT     0x08
#define S_SIDE     0x10
#define S_DENSITY  0x20
#define S_MOTOR    0x80

#define S_LASTSTEPDIR	0x100
#define S_FDC_PRESENT	0x80000000

#define WD1793_IRQ     0x80
#define WD1793_DRQ     0x40



// -------------
#define MAIN_THREAD_SEEK_COMMAND 1
#define MAIN_THREAD_CHANGE_DISK_COMMAND 2
#define MAIN_THREAD_COMMAND_LOAD_DIRECTORY 3
#define MAIN_THREAD_COMMAND_LOAD_ROM 4
#define MAIN_THREAD_BUTTON_COMMAND 5

#define MAIN_THREAD_COMMAND_CHANGE_DIR 6
#define MAIN_THREAD_COMMAND_LOAD_COVER 7
#define MAIN_THREAD_COMMAND_TAPE_WINDOW 8
#define MAIN_THREAD_COMMAND_PREPARE 9
#define MAIN_THREAD_COMMAND_SONG 10

#define LOAD_DIRECTORY_COMMAND_MASK 0x80
#define LOAD_ROM_COMMAND_MASK 0x40
#define CHANGE_DIR_COMMAND_MASK 0x20
#define LOAD_COVER_COMMAND_MASK 0x10
#define TAPE_WINDOW_COMMAND_MASK 0x08
#define PREPARE_COMMAND_MASK 0x04
#define SONG_COMMAND_MASK 0x02

// ---------------
#define ROM_TYPE_GENERIC	0
#define ROM_TYPE_MENUROM	1
#define ROM_TYPE_KONAMI4	2
#define ROM_TYPE_KONAMI5	3
#define ROM_TYPE_ASCII8		4
#define ROM_TYPE_ASCII16	5

#define ROM_SUFFIX_KONAMI4	".konami4"
#define ROM_SUFFIX_KONAMI5	".konami5"
#define ROM_SUFFIX_ASCII8	".ascii8"
#define ROM_SUFFIX_ASCII16	".ascii16"
#define DSK_SUFFIX	".dsk"
#define CAS_SUFFIX	".cas"
#define VGM_SUFFIX	".vgm"
#define SNAP_SUFFIX	".msxsnap"

// ------------
#define MAX_DRIVES		2
#define SINGLE_SIDED_TRACK	9*512
#define DOUBLE_SIDED_TRACK	SINGLE_SIDED_TRACK*2

#define SINGLE_SIDED_DISK_SIZE 368640
#define DOUBLE_SIDED_DISK_SIZE 737280

// Longest folder path below the root that a file name is added to
#define FOLDER_PATH_LENGTH	256

// ROMs are loaded into CCM (low 64K) and high_64k_base, so 128K at most. Bigger ones (up to
// 512K) run from flash sectors 8-11, which only the 1MB STM32F407VGT6 has. The emulator itself
// is in sectors 4-7 (see stm32_flash.ld)
#define MAX_ROM_SIZE		0x20000
#define FLASH_ROM_BASE		0x08080000
#define FLASH_ROM_MAX		0x80000
#define FLASH_ROM_SECTOR	8
#define FLASH_SECTOR_SIZE	0x20000
#define FLASH_SIZE_KB		(*(volatile uint16_t *) 0x1FFF7A22)	// from the chip

// Shown at the top of the KCMFS menu, eg. "2.0.17". Bump the first part for new features.
// The last number is counted up by the Makefile each time the emulator is built (see build_number)
#ifndef FIRMWARE_BUILD
#define FIRMWARE_BUILD		0
#endif
#define FIRMWARE_VERSION	"2.0." XSTR(FIRMWARE_BUILD)

// ---------------
// KCMFS menu interface. While menu.rom is presented the MSX sees
//   0x8000-0x9FFF  CCM 0x4000-0x5FFF: the control block below. 0x8000-0x80FF can be written
//   0xA000-0xBFFF  the 8K bank written to 0x8001. Banks 8-15 are high_64k_base, where the
//                  folder list is: entry n is in bank 8 + n/256 at 0xA000 + (n%256)*32.
//                  Banks 4 and 5 (CCM 0x8000-0xBFFF) hold the cover after LOAD_COVER
#define MENU_CTRL_BASE			(CCMRAM_BASE+0x4000)
#define MENU_CTRL_COMMAND		0x00	// W: command (below). Reads 0 when it is done
#define MENU_CTRL_BANK			0x01	// W: 8K bank to show at 0xA000
#define MENU_CTRL_COUNT			0x02	// R: number of entries, 16 bit, low byte first
#define MENU_CTRL_START_CURSOR		0x04	// R: entry to start on, 16 bit
#define MENU_CTRL_FLAGS			0x06	// R: MENU_FLAG_*
#define MENU_CTRL_COVER			0x08	// R: 1 if LOAD_COVER found a cover, 0 if not
#define MENU_CTRL_BANK_6000		0x02	// W: 8K bank to show at 0x6000 (for restoring a snapshot)
#define MENU_CTRL_TAPE			0x0A	// R: 1 if a tape was started (see below)
#define MENU_CTRL_SNAP			0x0B	// R: 1 if a snapshot was started (see below)
#define MENU_CTRL_TAPE_SIZE		0x0C	// R: its size in bytes, 32 bit
#define MENU_CTRL_VERSION		0x10	// R: firmware version, 0 terminated
#define MENU_CTRL_PATH			0x20	// R: folder shown, below msx/. Last 31 characters, 0 terminated
#define MENU_CTRL_PATH_LENGTH		31
#define MENU_CTRL_READY			0x60	// R/W: "RDY!" when PREPARE is done. kcmfs clears it first
#define MENU_CTRL_SELECTED		0x80	// W: entry number for PREPARE, LOAD_ROM, CHANGE_DIR and LOAD_COVER, 16 bit
#define MENU_CTRL_TAPE_BLOCK		0x84	// W: first 8K block of the tape for TAPE_WINDOW, 16 bit
#define MENU_CTRL_SONG_CHUNK		0x86	// W: 16K chunk of the song for SONG, 16 bit
#define MENU_CTRL_SONG_HALF		0x88	// W: 0 for banks 3-4, 1 for banks 5-6
#define MENU_CTRL_WRITABLE		0x100

// Music: SONG puts 16K of a .vgm (chunk MENU_CTRL_SONG_CHUNK) into banks 3-4 or 5-6, for kcmfs
// to play on the PSG while one half is loaded and the other played. Chunk 0 is of the entry at
// MENU_CTRL_SELECTED, the later ones of the same file (so it plays on in another folder). Past the
// end it reads 0x66, VGM's end
#define MENU_SONG_BANK			3
#define MENU_SONG_CHUNK			0x4000

// A snapshot (.msxsnap, made by tools/cas_snapshot.py from a tape loaded in openMSX): 64K of
// RAM, 16K of VRAM and 256 bytes of registers. Starting one presents menu.rom with
// MENU_CTRL_SNAP set and the RAM in banks 8-15, the VRAM in banks 3-4 and the registers in bank
// 5, and kcmfs puts it all back and goes on where the MSX was
#define MENU_SNAP_SIZE			(0x10000 + 0x4000 + 256)
#define MENU_SNAP_BANK			3	// VRAM, then the registers

// Starting a .cas presents menu.rom again with MENU_CTRL_TAPE set and the MSX is reset. The menu
// then puts the BIOS in RAM with its own TAPION and TAPIN, which read the tape through banks
// 8-15: TAPE_WINDOW loads the 64K of the tape from 8K block MENU_CTRL_TAPE_BLOCK on into them
#define MENU_TAPE_BLOCK			0x2000
#define MENU_TAPE_WINDOW		0x10000

#define MENU_FLAG_NO_DISK_ROM		0x01	// there is no disk.rom, so disks can not be started
#define MENU_FLAG_NO_FLASH_ROMS		0x02	// no room in flash for roms over 128K (not an STM32F407VGT6)

// Before LOAD_ROM kcmfs sends PREPARE (from RAM) and waits for "RDY!". A rom over 128K is written
// to flash then if it is not there already, and the board does not answer the bus while it erases
// and writes (its code is in flash), so the MSX reads 0xFF from it now and then

#define MENU_BANK_FIRST			8
#define MENU_ENTRY_SIZE			32
#define MENU_NAME_LENGTH		28	// characters shown. The name is 0 terminated after that
#define MENU_ENTRY_SIZE_K		30	// size in K, 15 bit, low byte first. 0 for folders
#define MENU_ENTRY_HAS_COVER		0x80	// set in the high byte of the size if there is a cover
#define MENU_MAX_ENTRIES		2048	// 64K / 32

// A cover is a SCREEN 2 picture saved with BSAVE (as BASIC does with BSAVE "X.SC2",0,&H37FF,S):
// a 7 byte header starting with 0xFE, then VRAM from 0. LOAD_COVER copies its patterns (VRAM
// 0x0000) to bank 4 and its colours (VRAM 0x2000) to bank 5. It is Game.sc2 next to Game.rom
// (or .dsk ...), or cover.sc2 in a folder (see tools/make_covers.ps1)
#define MENU_COVER_SUFFIX		".sc2"
#define MENU_COVER_IN_FOLDER		"cover.sc2"
#define MENU_COVER_BANK			4
#define MENU_COVER_PART_SIZE		6144
#define MENU_COVER_HEADER		7
#define MENU_COVER_COLOURS		0x2000	// VRAM address of the colours
#define MENU_COVER_FILE_SIZE		(MENU_COVER_HEADER + MENU_COVER_COLOURS + MENU_COVER_PART_SIZE)

// entry type, byte 0 of each entry
#define MENU_TYPE_UP			'U'	// ".."
#define MENU_TYPE_FOLDER		'F'	// a folder to open
#define MENU_TYPE_DISK			'D'	// a .dsk
#define MENU_TYPE_DISK_SET		'S'	// a folder with only .dsk files in it: one game on several disks
#define MENU_TYPE_ROM			'R'
#define MENU_TYPE_TAPE			'T'	// a .cas
#define MENU_TYPE_SONG			'M'	// a .vgm, played by kcmfs itself
#define MENU_TYPE_SNAPSHOT		'P'	// a .msxsnap

#define ROM_SUFFIX_ROM		".rom"
#define ROM_SUFFIX_MX1		".mx1"
#define ROM_SUFFIX_MX2		".mx2"
#define ROM_SUFFIX_RI		".ri"

//---------
#define CCMRAM_BASE	0x10000000

//------------
#define FDC_WRITE_FLUSH_DEFAULT	200000

//----------
#define MAIN_COMMAND_IN_PROGRESS	0x40000000
#define MAIN_COMMAND_COMPLETE		0x80000000

//------
#define DISKS_FOUND 2
#define DISK1_FOUND 1
#define NO_DISKS_FOUND 0

