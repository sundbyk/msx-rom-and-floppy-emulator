/*
 * SD card bootloader for msx-rom-and-floppy-emulator
 *
 * Lives in flash sectors 0-3. The emulator itself is linked at APP_BASE (see upgrade.h).
 *
 * - Normal boot: jump straight to the emulator. The SD card is not touched, so the time
 *   until the MSX sees a cartridge is the same as without a bootloader.
 * - Upgrade: the emulator finds upgrade.bin in the root of the SD card, writes UPGRADE_MAGIC
 *   to UPGRADE_FLAG_ADDR and resets. We flash upgrade.bin, verify it, delete it and reset.
 * - If the emulator in flash is not valid (eg. power was lost during an upgrade) we also look
 *   for upgrade.bin, so an interrupted upgrade just carries on at the next power up. The two
 *   vector table words are written last, so a half written emulator is never seen as valid.
 * - A file that does not look like an emulator image is renamed to upgrade.bad.
 *
 * PA6 and PA7 (the two LEDs on the common STM32F407VET6 'black' board, and the emulator's debug
 * pins) flicker while flashing. A steady blink means there is no valid emulator in flash and no
 * usable upgrade.bin. Use DFU or an ST-Link in that case.
 */
#include <string.h>
#include "stm32f4xx.h"
#include "stm32f4_discovery_sdio_sd.h"
#include "ff.h"
#include "defines.h"
#include "upgrade.h"

#define UPGRADE_OK		0
#define UPGRADE_NO_FILE		1
#define UPGRADE_BAD_FILE	2
#define UPGRADE_ERROR		3

#define LED_PINS		(GPIO_Pin_6 | GPIO_Pin_7)

static volatile uint32_t * const upgrade_flag = (volatile uint32_t *) UPGRADE_FLAG_ADDR;

static FATFS fs;
static FIL fil;
static uint32_t buffer[512/4];

static const struct {
	uint32_t start;
	uint16_t sector;
} app_sectors[] = {
	{ 0x08010000, FLASH_Sector_4 },	// 64K
	{ 0x08020000, FLASH_Sector_5 },	// 128K
	{ 0x08040000, FLASH_Sector_6 },	// 128K
	{ 0x08060000, FLASH_Sector_7 },	// 128K
};

static void delay(uint32_t count) {
	while (count--) {
		__asm volatile ("nop");
	}
}

// One LED on, the other off, the other way round next time
static void led_toggle(void) {
	GPIOA->ODR ^= LED_PINS;
}

static void config_led(void) {
	GPIO_InitTypeDef GPIO_InitStructure;

	RCC_AHB1PeriphClockCmd(RCC_AHB1Periph_GPIOA, ENABLE);
	GPIO_InitStructure.GPIO_Pin = LED_PINS;
	GPIO_InitStructure.GPIO_Mode = GPIO_Mode_OUT;
	GPIO_InitStructure.GPIO_OType = GPIO_OType_PP;
	GPIO_InitStructure.GPIO_Speed = GPIO_Speed_2MHz;
	GPIO_InitStructure.GPIO_PuPd = GPIO_PuPd_NOPULL;
	GPIO_Init(GPIOA, &GPIO_InitStructure);
	GPIO_SetBits(GPIOA, GPIO_Pin_6);
	GPIO_ResetBits(GPIOA, GPIO_Pin_7);
}

static void config_sd_nvic(void) {
	NVIC_InitTypeDef NVIC_InitStructure;

	NVIC_PriorityGroupConfig(NVIC_PriorityGroup_4);

	NVIC_InitStructure.NVIC_IRQChannel = SDIO_IRQn;
	NVIC_InitStructure.NVIC_IRQChannelPreemptionPriority = SDIO_IRQ_PREEMPTION_PRIORITY;
	NVIC_InitStructure.NVIC_IRQChannelSubPriority = 0;
	NVIC_InitStructure.NVIC_IRQChannelCmd = ENABLE;
	NVIC_Init(&NVIC_InitStructure);

	NVIC_InitStructure.NVIC_IRQChannel = SD_SDIO_DMA_IRQn;
	NVIC_InitStructure.NVIC_IRQChannelPreemptionPriority = SDIO_DMA_PREEMPTION_PRIORITY;
	NVIC_Init(&NVIC_InitStructure);
}

void SDIO_IRQHandler(void) {
	SD_ProcessIRQSrc();
}

void SD_SDIO_DMA_IRQHANDLER(void) {
	SD_ProcessDMAIRQ();
}

// A vector table that points into the emulator's flash and RAM
static int vectors_are_valid(uint32_t sp, uint32_t pc, uint32_t size) {
	return (sp >= 0x20000000) && (sp <= 0x20020000) &&
	       (pc & 1) && (pc >= APP_BASE) && (pc < APP_BASE + size);
}

static int app_is_valid(void) {
	return vectors_are_valid(*(volatile uint32_t *) APP_BASE, *(volatile uint32_t *) (APP_BASE + 4), APP_MAX_SIZE);
}

// Only called before any peripheral has been set up, so the emulator starts from a clean state
static void jump_to_app(void) {
	uint32_t sp = *(volatile uint32_t *) APP_BASE;
	uint32_t pc = *(volatile uint32_t *) (APP_BASE + 4);

	SCB->VTOR = APP_BASE;
	__asm volatile ("msr msp, %0\n"
			"bx  %1\n"
			:: "r" (sp), "r" (pc));
	while (1);
}

// The flash data/instruction caches can hold the old contents of an erased sector
static void reset_flash_caches(void) {
	FLASH->ACR &= ~(FLASH_ACR_DCEN | FLASH_ACR_ICEN);
	FLASH->ACR |= FLASH_ACR_DCRST | FLASH_ACR_ICRST;
	FLASH->ACR &= ~(FLASH_ACR_DCRST | FLASH_ACR_ICRST);
	FLASH->ACR |= FLASH_ACR_DCEN | FLASH_ACR_ICEN;
}

static int program_word(uint32_t addr, uint32_t data) {
	if (FLASH_ProgramWord(addr, data) != FLASH_COMPLETE) {
		return 0;
	}
	return *(volatile uint32_t *) addr == data;
}

static int flash_upgrade_file(FIL *f) {
	UINT br;
	uint32_t size, offset, addr, i, vectors[2];

	size = f_size(f);
	if (size < 8 || size > APP_MAX_SIZE) {
		return UPGRADE_BAD_FILE;
	}
	if (f_read(f, vectors, 8, &br) != FR_OK || br != 8) {
		return UPGRADE_ERROR;
	}
	if (!vectors_are_valid(vectors[0], vectors[1], size)) {
		// Probably the full image (bootloader + emulator) or something else entirely
		return UPGRADE_BAD_FILE;
	}

	FLASH_Unlock();
	FLASH_ClearFlag(FLASH_FLAG_EOP | FLASH_FLAG_OPERR | FLASH_FLAG_WRPERR |
			FLASH_FLAG_PGAERR | FLASH_FLAG_PGPERR | FLASH_FLAG_PGSERR);

	for (i = 0; i < sizeof(app_sectors) / sizeof(app_sectors[0]); i++) {
		if (app_sectors[i].start < APP_BASE + size) {
			led_toggle();
			if (FLASH_EraseSector(app_sectors[i].sector, VoltageRange_3) != FLASH_COMPLETE) {
				FLASH_Lock();
				return UPGRADE_ERROR;
			}
		}
	}
	reset_flash_caches();

	// Everything except the vector table first
	f_lseek(f, 0);
	for (offset = 0; offset < size; offset += br) {
		if (f_read(f, buffer, sizeof(buffer), &br) != FR_OK || br == 0) {
			FLASH_Lock();
			return UPGRADE_ERROR;
		}
		if (br & 3) {
			memset((uint8_t *) buffer + br, 0xFF, 4 - (br & 3));
		}
		for (i = 0; i < (br + 3) / 4; i++) {
			addr = APP_BASE + offset + (i * 4);
			if (addr >= APP_BASE + 8 && !program_word(addr, buffer[i])) {
				FLASH_Lock();
				return UPGRADE_ERROR;
			}
		}
		if ((offset & 0xfff) == 0) {
			led_toggle();
		}
	}

	// Vector table last. From here on the emulator is seen as valid
	if (!program_word(APP_BASE + 4, vectors[1]) || !program_word(APP_BASE, vectors[0])) {
		FLASH_Lock();
		return UPGRADE_ERROR;
	}
	FLASH_Lock();
	reset_flash_caches();
	return UPGRADE_OK;
}

static int do_upgrade(void) {
	int result;

	if (f_mount(&fs, "", 1) != FR_OK) {
		return UPGRADE_ERROR;
	}
	if (f_open(&fil, UPGRADE_FILENAME, FA_READ) != FR_OK) {
		return UPGRADE_NO_FILE;
	}
	result = flash_upgrade_file(&fil);
	f_close(&fil);

	if (result == UPGRADE_OK) {
		f_unlink(UPGRADE_FILENAME);
	} else if (result == UPGRADE_BAD_FILE) {
		// Get it out of the way so the emulator does not keep asking for it
		f_unlink(UPGRADE_BAD_FILENAME);
		f_rename(UPGRADE_FILENAME, UPGRADE_BAD_FILENAME);
	}
	return result;
}

int main(void) {
	if (*upgrade_flag != UPGRADE_MAGIC && app_is_valid()) {
		jump_to_app();
	}

	config_led();
	config_sd_nvic();

	do_upgrade();
	// Whatever happened, the emulator should not send us back here again until the next power up
	*upgrade_flag = UPGRADE_NO_RETRY;

	if (app_is_valid()) {
		// Reset rather than jump, so the emulator does not inherit the SDIO/DMA setup
		NVIC_SystemReset();
	}

	// No emulator and nothing usable to flash
	while (1) {
		led_toggle();
		delay(2000000);
	}
}
