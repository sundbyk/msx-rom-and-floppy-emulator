#include "util.h"

// probably have to tweak these if the processor speed changes. Just have to be rough
void delay_us(const uint16_t us)
{
   uint32_t i = us * 60;
   while (i-- > 0) {
      __asm volatile ("nop");
   }
}

void delay_ms(const uint16_t ms)
{
   //uint32_t i = ms * 27778;
   uint32_t i = ms * 30000 *2;
   while (i-- > 0) {
      __asm volatile ("nop");
   }
}

void blink_pa6_pa7(int delay) {
        while(1) {
                GPIOA->ODR = 0x0040;
                delay_ms(delay);
                GPIOA->ODR = 0x0080;
                delay_ms(delay);
        }
}

void blink_pa6(int delay) {
        while(1) {
                GPIOA->ODR = 0x0040;
                delay_ms(delay);
                GPIOA->ODR = 0x0000;
                delay_ms(delay);
        }
}

void blink_pa7(int delay) {
        while(1) {
                GPIOA->ODR = 0x0080;
                delay_ms(delay);
                GPIOA->ODR = 0x0000;
                delay_ms(delay);
        }
}

void blink_pa1(int delay) {
        while(1) {
                GPIOA->ODR = 0x0002;
                delay_ms(delay);
                GPIOA->ODR = 0x0000;
                delay_ms(delay);
        }
}


uint32_t suffix_match(char *name, char *suffix) {
	if (strlen(name)>strlen(suffix)) {
		if (strncasecmp (&name[strlen(name)-strlen(suffix)],suffix,strlen(suffix)) == 0) {
			return TRUE;
		}
	}
	return FALSE;
}

uint32_t get_romtype_from_filename(char *fname) {
	uint32_t 	romtype;

	romtype = ROM_TYPE_GENERIC;
	if (suffix_match(fname,ROM_SUFFIX_KONAMI4)) {
		romtype = ROM_TYPE_KONAMI4;
	}
	if (suffix_match(fname,ROM_SUFFIX_KONAMI5)) {
		romtype = ROM_TYPE_KONAMI5;
	}
	if (suffix_match(fname,ROM_SUFFIX_ASCII8)) {
		romtype = ROM_TYPE_ASCII8;
	}
	if (suffix_match(fname,ROM_SUFFIX_ASCII16)) {
		romtype = ROM_TYPE_ASCII16;
	}
	if (strncmp(fname,"menu.rom",8) == 0) {
		romtype = ROM_TYPE_MENUROM;
	}

	return romtype;
}

uint32_t get_pagemap_default_by_romtype(uint32_t romtype) {
	switch(romtype) {
		case ROM_TYPE_MENUROM :
			return PAGEMAP(0, 1, 2, 3);
		case ROM_TYPE_GENERIC :
			return PAGEMAP(0, 1, 2, 3);
		case ROM_TYPE_KONAMI4 :
			return PAGEMAP(0, 1, 0, 0);
		case ROM_TYPE_KONAMI5 :
			return PAGEMAP(0, 1, 2, 3);
		case ROM_TYPE_ASCII8:
			return PAGEMAP(0, 0, 0, 0);
		case ROM_TYPE_ASCII16:
			return PAGEMAP(0, 0, 0, 0);
		default:
			return PAGEMAP(0, 1, 2, 3);

	}
}

// Where each 8K bank of the rom is. EXTI2 reads through it (reg_bank_table)
uint32_t bank_table[64];

// The rom's banks in RAM: 0-7 in lowbuffer (CCM), 8-15 in highbuffer, and so on round again
void set_banks_ram(char *lowbuffer, char *highbuffer) {
	uint32_t b;

	for (b = 0; b < 64; b++) {
		bank_table[b] = (b & 15) < 8 ? (uint32_t) lowbuffer + (b & 7) * 0x2000 : (uint32_t) highbuffer + (b & 7) * 0x2000;
	}
}

// The rom's banks in flash, size bytes of them, and round again after that
static void set_banks_flash(uint32_t size) {
	uint32_t b, banks = (size + 0x1FFF) / 0x2000;

	for (b = 0; b < 64; b++) {
		bank_table[b] = FLASH_ROM_BASE + (b % banks) * 0x2000;
	}
}

// TRUE if roms over 128K can run from flash
uint32_t flash_roms_possible(void) {
	return FLASH_SIZE_KB >= 1024;
}

// Have the rom in f (size bytes) in flash at FLASH_ROM_BASE. It is read and compared first, and
// only written if it is not there already. buffer is 64K the SD card's DMA can reach. The board
// does not answer the MSX while flash is erased or written: its code is in flash too
static FRESULT flash_rom(FIL *f, uint32_t size, uint8_t *buffer) {
	FRESULT res = FR_OK;
	FLASH_Status st = FLASH_COMPLETE;
	uint32_t off, i, same = TRUE;
	UINT n = 0;

	for (off = 0; same && off < size; off += n) {
		res = f_read(f, buffer, 0x10000, &n);
		if (res != FR_OK || n == 0) {
			return FR_INT_ERR;
		}
		for (i = 0; i < n; i++) {
			if (buffer[i] != *(volatile uint8_t *) (FLASH_ROM_BASE + off + i)) {
				same = FALSE;
				break;
			}
		}
	}
	if (same) {
		return FR_OK;
	}
	if (f_lseek(f, 0) != FR_OK) {
		return FR_INT_ERR;
	}
	FLASH_Unlock();
	FLASH_ClearFlag(FLASH_FLAG_EOP | FLASH_FLAG_OPERR | FLASH_FLAG_WRPERR |
			FLASH_FLAG_PGAERR | FLASH_FLAG_PGPERR | FLASH_FLAG_PGSERR);
	for (i = 0; st == FLASH_COMPLETE && i * FLASH_SECTOR_SIZE < size; i++) {
		st = FLASH_EraseSector((FLASH_ROM_SECTOR + i) << 3, VoltageRange_3);
	}
	for (off = 0; st == FLASH_COMPLETE && off < size; off += n) {
		res = f_read(f, buffer, 0x10000, &n);
		if (res != FR_OK || n == 0) {
			break;
		}
		for (i = 0; st == FLASH_COMPLETE && i < n; i += 4) {
			st = FLASH_ProgramWord(FLASH_ROM_BASE + off + i, *(uint32_t *) &buffer[i]);
		}
	}
	FLASH_Lock();
	// what the data cache had of the old rom
	FLASH->ACR &= ~FLASH_ACR_DCEN;
	FLASH->ACR |= FLASH_ACR_DCRST;
	FLASH->ACR &= ~FLASH_ACR_DCRST;
	FLASH->ACR |= FLASH_ACR_DCEN;
	return (st == FLASH_COMPLETE && off >= size) ? FR_OK : FR_INT_ERR;
}

// Write the rom fname to flash if it is over 128K (and not there already). For PREPARE, before
// load_rom presents it, so the MSX is not running from the board then
FRESULT prepare_rom(char *fname, char *highbuffer) {
	FRESULT res;
	FIL fil;

	memset(&fil, 0, sizeof(FIL));
	res = f_open(&fil, fname, FA_READ);
	if (res == FR_OK && f_size(&fil) > MAX_ROM_SIZE && f_size(&fil) <= FLASH_ROM_MAX && flash_roms_possible()) {
		res = flash_rom(&fil, f_size(&fil), (uint8_t *) highbuffer);
	}
	f_close(&fil);
	return res;
}

char *find_disk_n(char *haystack, int n) {
	char *p;

	p = haystack;
	while (*p) {
		if ((*p== 'd') || (*p=='D')) {
			if ((p[1]=='i') || (p[1]=='I')) {
				if ((p[2]=='s') || (p[2]=='S')) {
					if ((p[3]=='k') || (p[3]=='K')) {
						if (((p[4]==' ') && (p[5]==(n+'0'))) || (p[4]==(n+'0'))) {
							return p;
						} else {
							// exit if we matched all the way to Disk, but failed on the number
							// This is so that a game filename like "Some Game (1990)(Blah Blah)(Disk 4 of 4)(Game Disk 1).dsk" will only attempt to match the first case of the word 'Disk'
							return NULL;
						}
					}
				}
			}
		}
		p++;
	}
	return NULL;
}

// 360K (1DD, 80 tracks) and 180K (40 tracks) images are one sided, 720K two sided. Either way a
// track is 9 sectors of 512 bytes
static uint32_t is_double_sided(FIL *fil) {
	return f_size(fil) > SINGLE_SIDED_DISK_SIZE;
}

/*
 * load_disks
 * if filename is a path to a directory then look inside that directory for
 *    something to load into dsk[0]
 *    something to load into dsk[1]
 *
 *    For dsk[0] this can be a file with the string 'Disk n' in the filename (eg. game disk 1.dsk or
 *    game disk 2.dsk and so on. The numeric is based on what disk_index is set to. ie. 1, means 
 *    load game disk 1.dsk.
 *
 *    For dsk[1] it only looks for a file ending in .dsk2 . The expectation is that most games wont
 *    look for the 2nd or 3rd disks in the 2nd drive.
 *
 *    disk_index is a pointer to a uint32_t. So is disk_index_max. The idea is that as it scans the subdir
 *    looking for the filename that matches with 'Disk n', it also calculates the highest number for 'Disk n'
 *    (eg. Disk 6). That highest number '6' is then stored in disk_index_max
 *
 * if the filename is a path to a file
 *
 *    check if the filename ends in .dsk or .dsk1 and load it into dsk[0] only
 *
 * if no dsk files are found at all return '0' (ie failure)
 * */
uint32_t load_disks(DSK *dsk,char *filename,uint32_t *disk_index, uint32_t *disk_index_max) {
	FILINFO fno;
	FRESULT res;
	DIR	dir;
	// tmp_disk_n_name is the disk n we are looking for
	// tmp_disk_n_plus_1_name is the disk name that is n+1 (eg. if we were searching for Disk 1, then this would be used for Disk 2. It is a sort of additional fallback for disk sets where you leave out disk 1 (which might be an intro) and the main game starts at disk 2
	char 	tmp_disk_n_name[FF_MAX_LFN + 1],tmp_disk_n_plus_1_name[FF_MAX_LFN + 1],fallback_fname[FF_MAX_LFN + 1];
	uint32_t	min,max;

	tmp_disk_n_name[0]=0;
	tmp_disk_n_plus_1_name[0]=0;
	fallback_fname[0]=0;


	res = f_stat(filename,&fno);
	if (res == FR_OK) {
		dsk[1].disk_filename[0]=0;
		res = f_opendir(&dir,filename);
		if (res == FR_OK) {
			max = 0;
			min = 100; // arbitrary high number
			for (;;) {
				res = f_readdir(&dir,&fno);
				if (res != FR_OK || fno.fname[0] == 0) break;
				if (suffix_match(fno.fname,".dsk")) {
					// If disk_index is 1 on entry it means we want to load 'the first disk' regardless of whether it has 'Disk 1' in the filename
					// If disk_index is 0 on entry it means we don't know if there are any disks, but if there is one then we would want to load 'Disk 1' OR 'the first .dsk it sees
					if ((*disk_index == 1) || (*disk_index == 0)) {
						// disk_index 1 is a special case where we allow the first file we see as disk 1
						*disk_index = 1;
						strcpy(fallback_fname,fno.fname);
					}
					// work out the highest numbered disk
					for (uint32_t i=9;i>0;i--) {
						if (find_disk_n(fno.fname,i)!=NULL) {
							if (i>max) {
								max = i;
							}
							if (i<min) {
								min = i;
							}
						}
					}
					if (find_disk_n(fno.fname,*disk_index)!=NULL) {
						// Disk n found
						strcpy(tmp_disk_n_name,fno.fname);
					}
					if (find_disk_n(fno.fname,(*disk_index)+1)!=NULL) {
						// Disk n+1 found
						strcpy(tmp_disk_n_plus_1_name,fno.fname);
					}


				}
				if (suffix_match(fno.fname,".dsk2")) {
					strcpy(dsk[1].disk_filename,filename);
					strcat(dsk[1].disk_filename,"/");
					strcat(dsk[1].disk_filename,fno.fname);
				}
			}
			f_closedir(&dir);
			if (max > 0) {
				*disk_index_max = max;
			} else {
				*disk_index_max = 1;
			}

			if (tmp_disk_n_name[0]) {
				// disk n was found
				strcpy(dsk[0].disk_filename,filename);
				strcat(dsk[0].disk_filename,"/");
				strcat(dsk[0].disk_filename,tmp_disk_n_name);
			} else {
				if (tmp_disk_n_plus_1_name[0]) {
					// we could not find the disk n we wanted but we did find n+1
					strcpy(dsk[0].disk_filename,filename);
					strcat(dsk[0].disk_filename,"/");
					strcat(dsk[0].disk_filename,tmp_disk_n_plus_1_name);
					(*disk_index)++;  // push the disk number up. TODO this will probably screw up the PREV button working completely correctly
				} else {
					if (fallback_fname[0]) {
						strcpy(dsk[0].disk_filename,filename);
						strcat(dsk[0].disk_filename,"/");
						strcat(dsk[0].disk_filename,fallback_fname);
					} else {
						// we didnt find anything
						dsk[0].disk_filename[0]=0;
						dsk[1].disk_filename[0]=0;

						*disk_index=0;		// TODO. not sure if this is required.

						return NO_DISKS_FOUND;
					}
				}
			}
			// close both drives
			for (int drive=0;drive<MAX_DRIVES;drive++) {
				if (dsk[drive].fil.obj.id) {
					f_close(&dsk[drive].fil);
					memset(&dsk[drive].fil, 0, sizeof(FIL));
				}
			}

			res = f_open(&dsk[0].fil, dsk[0].disk_filename, FA_READ);
			if (res != FR_OK) blink_pa1(1500);
			dsk[0].double_sided = is_double_sided(&dsk[0].fil);
			if (dsk[1].disk_filename[0]) {
				res = f_open(&dsk[1].fil, dsk[1].disk_filename, FA_READ);
				if (res != FR_OK) blink_pa1(1500);
				dsk[1].double_sided = is_double_sided(&dsk[1].fil);
			}
			return DISKS_FOUND;
		} else if (suffix_match(fno.fname,".dsk")) {
			// Must be a dsk file
			*disk_index = 0;		// default it to Disk 1
			*disk_index_max = 0;		// so when the person hits NEXT it will go to the next file or subdir
			// close both drives
			for (int drive=0;drive<MAX_DRIVES;drive++) {
				if (dsk[drive].fil.obj.id) {
					f_close(&dsk[drive].fil);
					memset(&dsk[drive].fil, 0, sizeof(FIL));
				}
			}
			strcpy(dsk[0].disk_filename,filename);
			res = f_open(&dsk[0].fil, dsk[0].disk_filename, FA_READ);
			dsk[0].double_sided = is_double_sided(&dsk[0].fil);
			return DISK1_FOUND;
		} else {
			return NO_DISKS_FOUND;
		}
	} else {
		return 0;
	}


}

// Load fname file with the first 64k going to lowbuffer , and the next 64k going to highbuffer
FRESULT load_rom(char *fname,char *lowbuffer, char* highbuffer) {
	FRESULT res;
        FIL     fil;
        UINT BytesRead;
	volatile uint32_t romtype;
	volatile uint32_t pagemap_default;

	memset(&fil, 0, sizeof(FIL));

	res =  f_open(&fil, fname, FA_READ);
	romtype = get_romtype_from_filename(fname);
	pagemap_default = get_pagemap_default_by_romtype(romtype);

	// Over 128K it runs from flash, if it fits there. Otherwise the current rom stays
	if (res == FR_OK && f_size(&fil) > MAX_ROM_SIZE) {
		uint32_t size = f_size(&fil);

		if (size > FLASH_ROM_MAX || !flash_roms_possible()) {
			f_close(&fil);
			return FR_INVALID_OBJECT;
		}
		res = flash_rom(&fil, size, (uint8_t *) highbuffer);
		f_close(&fil);
		if (res == FR_OK) {
			set_banks_flash(size);
			__asm volatile("\t vmov "XSTR(reg_mapper_pages)", %0" :: "rm"(pagemap_default | (romtype <<29)));
		}
		return res;
	}

	set_banks_ram(lowbuffer, highbuffer);
	// set romtype in upper portion of page map registers
	__asm volatile("\t vmov "XSTR(reg_mapper_pages)", %0" :: "rm"(pagemap_default | (romtype <<29)));

	if (res == FR_OK) {
#ifdef ENABLE_SEMIHOSTING
                printf("TEST.ROM opened OK\n");
#endif

		// f_read into the highbuffer since it won't work into ccmram
		res = f_read(&fil,highbuffer, 0x10000, &BytesRead);
		if (res != FR_OK) {
			blink_pa6(3000);
		} else {
#ifdef ENABLE_SEMIHOSTING
	                printf("Read %d bytes in to %0x08x\n",BytesRead,highbuffer);
#endif
		}
		
		// copy what we jsut read to ccmram
		if (romtype == ROM_TYPE_GENERIC && BytesRead > 0 && BytesRead <= 0x4000) {
			// An 8K or 16K rom goes at 0x4000, or at 0x8000 if its header points there (eg. a
			// BASIC rom). The rest reads 0xFF, not what the previous rom left behind, so the
			// BIOS does not find a second header (a disk rom must not be started twice)
			uint32_t base = 0;	// in lowbuffer. 0 is 0x4000, 0x4000 is 0x8000
			if (BytesRead >= 0x10 && highbuffer[0] == 'A' && highbuffer[1] == 'B') {
				for (int p = 2; p <= 8; p += 2) {
					uint32_t addr = (uint8_t) highbuffer[p] | ((uint8_t) highbuffer[p+1] << 8);
					if (addr >= 0x8000 && addr < 0xC000) {
						base = 0x4000;
					}
				}
			}
			memset(lowbuffer, 0xFF, 0x10000);
			for (int i=0;i<BytesRead;i++) {
				lowbuffer[base+i]=highbuffer[i];
			}
			// An 8K rom also shows in the other half of its 16K, as on most such carts
			if (BytesRead <= 0x2000) {
				for (int i=0;i<0x2000;i++) {
					lowbuffer[base+0x2000+i]=lowbuffer[base+i];
				}
			}
		} else {
			for (int i=0;i<0x10000;i++) {
				lowbuffer[i]=highbuffer[i];
			}
		}
		// Only read second 64K if necessary
		if (BytesRead == 0x10000) {
			res = f_read(&fil,highbuffer, 0x10000, &BytesRead);
			if (res != FR_OK) {
				blink_pa7(4000);
			} else {
#ifdef ENABLE_SEMIHOSTING
		                printf("Read %d bytes in to %0x08x\n",BytesRead,highbuffer);
#endif

			}

		}
	}
	f_close(&fil);
	return res;
}

// ---------------------------------------------------------------------------------------------
// Folder listing for the KCMFS menu and for NEXT/PREV

uint32_t is_disk_image(char *name) {
	return suffix_match(name, DSK_SUFFIX);
}

uint32_t is_tape_image(char *name) {
	return suffix_match(name, CAS_SUFFIX);
}

uint32_t is_song(char *name) {
	return suffix_match(name, VGM_SUFFIX);
}

uint32_t is_snapshot(char *name) {
	return suffix_match(name, SNAP_SUFFIX);
}

uint32_t is_rom_image(char *name) {
	return suffix_match(name, ROM_SUFFIX_ROM) || suffix_match(name, ROM_SUFFIX_MX1) ||
	       suffix_match(name, ROM_SUFFIX_MX2) || suffix_match(name, ROM_SUFFIX_RI) ||
	       suffix_match(name, ROM_SUFFIX_KONAMI4) || suffix_match(name, ROM_SUFFIX_KONAMI5) ||
	       suffix_match(name, ROM_SUFFIX_ASCII8) || suffix_match(name, ROM_SUFFIX_ASCII16);
}

// Hidden and system files, and names starting with '.' (eg. the ._ files macOS leaves behind)
static uint32_t is_visible(FILINFO *fno) {
	return !(fno->fattrib & (AM_HID | AM_SYS)) && fno->fname[0] != '.';
}

// Set by folder_kind() if it saw a cover.sc2 in the folder. It stops looking at the first
// subfolder or rom, so this is only sure to be found in a disk set
static uint32_t folder_cover;

// What a folder in parent is: MENU_TYPE_DISK_SET if it holds .dsk files and nothing else that
// can be started (no folders, roms or tapes), so it is one game on several disks. Otherwise
// MENU_TYPE_FOLDER, a folder to open.
uint32_t folder_kind(char *parent, char *name) {
	static char path[FOLDER_PATH_LENGTH + 1 + FF_MAX_LFN + 1];
	static FILINFO fno;
	DIR dir;
	uint32_t disks = 0;
	uint32_t others = 0;

	folder_cover = FALSE;
	if (strlen(parent) + 1 + strlen(name) >= sizeof(path)) {
		return MENU_TYPE_FOLDER;
	}
	strcpy(path, parent);
	strcat(path, "/");
	strcat(path, name);
	memset(&dir, 0, sizeof(DIR));
	if (f_opendir(&dir, path) != FR_OK) {
		return MENU_TYPE_FOLDER;
	}
	while (!others && f_readdir(&dir, &fno) == FR_OK && fno.fname[0] != 0) {
		if (!is_visible(&fno)) {
			continue;
		}
		if (fno.fattrib & AM_DIR) {
			others++;
		} else if (is_disk_image(fno.fname)) {
			disks++;
		} else if (is_rom_image(fno.fname) || is_tape_image(fno.fname) || is_song(fno.fname) || is_snapshot(fno.fname)) {
			others++;
		} else if (strcasecmp(fno.fname, MENU_COVER_IN_FOLDER) == 0) {
			folder_cover = TRUE;
		}
	}
	f_closedir(&dir);
	return (disks && !others) ? MENU_TYPE_DISK_SET : MENU_TYPE_FOLDER;
}

// The menu type of fno in parent, or 0 if the menu does not show it
static uint32_t menu_type(char *parent, FILINFO *fno) {
	if (!is_visible(fno)) {
		return 0;
	}
	if (fno->fattrib & AM_DIR) {
		return folder_kind(parent, fno->fname);
	}
	if (is_disk_image(fno->fname)) {
		return MENU_TYPE_DISK;
	}
	if (is_rom_image(fno->fname)) {
		return MENU_TYPE_ROM;
	}
	if (is_tape_image(fno->fname)) {
		return MENU_TYPE_TAPE;
	}
	if (is_song(fno->fname)) {
		return MENU_TYPE_SONG;
	}
	if (is_snapshot(fno->fname)) {
		return MENU_TYPE_SNAPSHOT;
	}
	return 0;
}

// f_readdir that only returns what the menu shows: folders, disk sets, disks, roms, tapes, songs.
// *type is its MENU_TYPE_*. fno->fname[0] == 0 at the end
FRESULT readdir_menu(DIR *dir, char *path, FILINFO *fno, uint32_t *type) {
	FRESULT res;

	do {
		res = f_readdir(dir, fno);
		*type = (res == FR_OK && fno->fname[0] != 0) ? menu_type(path, fno) : 0;
	} while (res == FR_OK && fno->fname[0] != 0 && *type == 0);
	return res;
}

// Same, but only what NEXT/PREV can start: disks, disk sets, roms and tapes, not folders or songs
static uint32_t is_startable(uint32_t type) {
	return type != MENU_TYPE_FOLDER && type != MENU_TYPE_SONG;
}

FRESULT readdir_image(DIR *dir, char *path, FILINFO *fno) {
	FRESULT res;
	uint32_t type;

	do {
		res = readdir_menu(dir, path, fno, &type);
	} while (res == FR_OK && fno->fname[0] != 0 && !is_startable(type));
	return res;
}

// Position of each sorted menu entry among the readdir_menu() entries in directory order.
// This is what is needed to find the file or folder again when the menu selects an entry.
static uint16_t menu_ordinal[MENU_MAX_ENTRIES];

uint32_t menu_entry_ordinal(uint32_t index) {
	return (index < MENU_MAX_ENTRIES) ? menu_ordinal[index] : 0;
}

static int upper(int c) {
	return (c >= 'a' && c <= 'z') ? c - 'a' + 'A' : c;
}

// Folders first, then case insensitive by name (skipping the type byte). Disk sets are games,
// so they go in among the files
static int entry_compare(unsigned char *a, unsigned char *b) {
	int i;
	int a_rank = (a[0] == MENU_TYPE_FOLDER) ? 0 : 1;
	int b_rank = (b[0] == MENU_TYPE_FOLDER) ? 0 : 1;

	if (a_rank != b_rank) {
		return a_rank - b_rank;
	}
	for (i = 1; i < MENU_ENTRY_SIZE_K; i++) {
		if (upper(a[i]) != upper(b[i]) || a[i] == 0) {
			return upper(a[i]) - upper(b[i]);
		}
	}
	return 0;
}

static void entry_swap(unsigned char *buffer, uint32_t a, uint32_t b) {
	uint32_t *p = (uint32_t *) &buffer[a * MENU_ENTRY_SIZE];
	uint32_t *q = (uint32_t *) &buffer[b * MENU_ENTRY_SIZE];
	uint32_t t;
	int i;

	for (i = 0; i < MENU_ENTRY_SIZE / 4; i++) {
		t = p[i];
		p[i] = q[i];
		q[i] = t;
	}
	t = menu_ordinal[a];
	menu_ordinal[a] = menu_ordinal[b];
	menu_ordinal[b] = t;
}

// The entry against the first len characters of name, the way entry_compare() orders names
static int entry_name_compare(unsigned char *entry, char *name, uint32_t len) {
	int i, a, b;

	for (i = 0; i < MENU_NAME_LENGTH; i++) {
		a = entry[1 + i];
		b = (i < (int) len) ? (unsigned char) name[i] : 0;
		if (upper(a) != upper(b) || a == 0) {
			return upper(a) - upper(b);
		}
	}
	return 0;
}

// Set MENU_ENTRY_HAS_COVER on the sorted entries first to count-1 called name (len characters),
// if any. Names cut at MENU_NAME_LENGTH match on what is left of them
static void mark_cover(unsigned char *buffer, uint32_t first, uint32_t count, char *name, uint32_t len) {
	uint32_t lo, hi, mid, i;
	int c;

	if (len > MENU_NAME_LENGTH) {
		len = MENU_NAME_LENGTH;
	}
	lo = first;
	hi = count;
	while (lo < hi) {
		mid = (lo + hi) / 2;
		c = entry_name_compare(&buffer[mid * MENU_ENTRY_SIZE], name, len);
		if (c == 0) {
			// Game.rom and Game.dsk side by side both get it
			for (i = mid; i > first && entry_name_compare(&buffer[(i - 1) * MENU_ENTRY_SIZE], name, len) == 0; i--);
			for (; i < count && entry_name_compare(&buffer[i * MENU_ENTRY_SIZE], name, len) == 0; i++) {
				buffer[i * MENU_ENTRY_SIZE + MENU_ENTRY_SIZE_K + 1] |= MENU_ENTRY_HAS_COVER;
			}
			return;
		}
		if (c < 0) {
			lo = mid + 1;
		} else {
			hi = mid;
		}
	}
}

// Look through dirname again for Game.sc2 files and mark the entries they go with. Folders and
// the rest are sorted apart, so each part is searched
static void mark_covers(char *dirname, unsigned char *buffer, uint32_t first, uint32_t count) {
	static FILINFO fno;
	DIR dir;
	uint32_t folders, len;

	for (folders = first; folders < count && buffer[folders * MENU_ENTRY_SIZE] == MENU_TYPE_FOLDER; folders++);
	memset(&dir, 0, sizeof(DIR));
	if (f_opendir(&dir, (TCHAR *) dirname) != FR_OK) {
		return;
	}
	while (f_readdir(&dir, &fno) == FR_OK && fno.fname[0] != 0) {
		if (!is_visible(&fno) || (fno.fattrib & AM_DIR) || !suffix_match(fno.fname, MENU_COVER_SUFFIX)) {
			continue;
		}
		len = strlen(fno.fname) - strlen(MENU_COVER_SUFFIX);
		mark_cover(buffer, first, folders, fno.fname, len);
		mark_cover(buffer, folders, count, fno.fname, len);
	}
	f_closedir(&dir);
}

// Shell sort of entries first to count-1. No recursion and no library calls (newlib is not
// built with -ffixed-r10)
static void sort_entries(unsigned char *buffer, uint32_t first, uint32_t count) {
	uint32_t gap, i, j, n = count - first;

	if (count <= first) {
		return;
	}
	for (gap = 1; gap < n / 3; gap = gap * 3 + 1);
	for (; gap > 0; gap /= 3) {
		for (i = first + gap; i < count; i++) {
			for (j = i; j >= first + gap && entry_compare(&buffer[(j - gap) * MENU_ENTRY_SIZE], &buffer[j * MENU_ENTRY_SIZE]) > 0; j -= gap) {
				entry_swap(buffer, j - gap, j);
			}
		}
	}
}

// Build the menu list from what readdir_menu() finds in dirname. Each entry is MENU_ENTRY_SIZE
// bytes (see defines.h): a type byte, the name without the extension, and the size in K with
// MENU_ENTRY_HAS_COVER. With with_up there is a ".." entry first. Then folders, then the rest,
// each sorted by name. Returns the number of entries.
uint32_t load_directory(char *dirname, unsigned char *buffer, uint32_t with_up) {
	FRESULT res;
	DIR dir;
	static FILINFO fno;
	uint32_t count, ordinal, len, first, type;
	FSIZE_t size_k;
	unsigned char *entry;
	char *dot;

	count = 0;
	if (with_up) {
		memset(buffer, 0, MENU_ENTRY_SIZE);
		buffer[0] = MENU_TYPE_UP;
		strcpy((char *) &buffer[1], "..");
		menu_ordinal[0] = 0;
		count = 1;
	}
	first = count;

	memset(&dir, 0, sizeof(DIR));
	if (f_opendir(&dir, (TCHAR *) dirname) != FR_OK) {
		return count;
	}

	ordinal = 0;
	while (count < MENU_MAX_ENTRIES) {
		res = readdir_menu(&dir, dirname, &fno, &type);
		if (res != FR_OK || fno.fname[0] == 0) {
			break;
		}
		entry = &buffer[count * MENU_ENTRY_SIZE];
		entry[0] = type;
		size_k = 0;
		if (fno.fattrib & AM_DIR) {
			len = strlen(fno.fname);
		} else {
			// The extension (and with it the mapper type) is not shown
			dot = strrchr(fno.fname, '.');
			len = dot ? (uint32_t) (dot - fno.fname) : strlen(fno.fname);
			// to the nearest K, but never 0K for a file with something in it
			size_k = (fno.fsize + 512) / 1024;
			if (size_k == 0 && fno.fsize > 0) {
				size_k = 1;
			}
			if (size_k > 0x7FFF) {
				size_k = 0x7FFF;
			}
		}
		if (len > MENU_NAME_LENGTH) {
			len = MENU_NAME_LENGTH;
		}
		memcpy(&entry[1], fno.fname, len);
		memset(&entry[1 + len], 0, MENU_ENTRY_SIZE_K - 1 - len);
		entry[MENU_ENTRY_SIZE_K] = size_k & 0xFF;
		entry[MENU_ENTRY_SIZE_K + 1] = size_k >> 8;
		// a cover.sc2 in a disk set
		if ((fno.fattrib & AM_DIR) && folder_cover) {
			entry[MENU_ENTRY_SIZE_K + 1] |= MENU_ENTRY_HAS_COVER;
		}
		menu_ordinal[count] = ordinal;
		count++;
		ordinal++;
	}
	f_closedir(&dir);

	sort_entries(buffer, first, count);
	mark_covers(dirname, buffer, first, count);
	return count;
}

// Open path and walk readdir_menu() to the entry at ordinal. dir is left just after it, so
// readdir_image() carries on with the next rom or disk. *images_before is how many entries
// readdir_image() would have given before it, *type is its MENU_TYPE_*. Returns FR_OK with
// fno->fname[0] == 0 if there is no such entry.
FRESULT find_menu_entry(DIR *dir, char *path, uint32_t ordinal, FILINFO *fno, uint32_t *type, int32_t *images_before) {
	FRESULT res;
	uint32_t i;

	*images_before = 0;
	f_closedir(dir);
	res = f_opendir(dir, path);
	if (res != FR_OK) {
		return res;
	}
	for (i = 0; i <= ordinal; i++) {
		res = readdir_menu(dir, path, fno, type);
		if (res != FR_OK || fno->fname[0] == 0) {
			return res;
		}
		if (i < ordinal && is_startable(*type)) {
			(*images_before)++;
		}
	}
	return FR_OK;
}