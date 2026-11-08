/*
 * msx-rom-and-floppy-emulator
 * kernel@kernelcrash.com
 *
 *
 */
#include <stdio.h>
#include <string.h>
#include "main.h"
#include "defines.h"
#include "stm32f4xx.h"
#include "util.h"

#include "stm32f4_discovery.h"
#include "stm32f4_discovery_sdio_sd.h"
#include "ff.h"
#include "diskio.h"
#include "upgrade.h"



extern volatile uint8_t *rom_base;
extern volatile uint8_t *low_64k_base;
extern volatile uint8_t *high_64k_base;

extern volatile uint32_t main_thread_command;
extern volatile uint32_t main_thread_data;
extern volatile uint32_t main_thread_actual_track[2];

extern volatile uint8_t *track_buffer;
extern volatile uint32_t fdc_write_flush_count;
extern volatile uint32_t fdc_write_dirty_bits;


#ifdef ENABLE_SEMIHOSTING
extern void initialise_monitor_handles(void);   /*rtt*/
#endif

GPIO_InitTypeDef  GPIO_InitStructure;

// FATFS stuff
FRESULT res;
FILINFO fno;
DIR dir;
FATFS fs32;
char* path;
UINT BytesRead;

uint32_t disk_index;
uint32_t disk_index_max;

#ifdef DEBUG_FILENAME
	char debug_filename[128];
#endif

#if _USE_LFN
    static char lfn[_MAX_LFN + 1];
        fno.lfname = lfn;
            fno.lfsize = sizeof lfn;
#endif


// Enable the FPU (Cortex-M4 - STM32F4xx and higher)
// http://infocenter.arm.com/help/topic/com.arm.doc.dui0553a/BEHBJHIG.html
// Also make sure lazy stacking is disabled
void enable_fpu_and_disable_lazy_stacking() {
  __asm volatile
  (
    "  ldr.w r0, =0xE000ED88    \n"  /* The FPU enable bits are in the CPACR. */
    "  ldr r1, [r0]             \n"  /* read CAPCR */
    "  orr r1, r1, #( 0xf << 20 )\n" /* Set bits 20-23 to enable CP10 and CP11 coprocessors */
    "  str r1, [r0]              \n" /* Write back the modified value to the CPACR */
    "  dsb                       \n" /* wait for store to complete */
    "  isb                       \n" /* reset pipeline now the FPU is enabled */
    // Disable lazy stacking (the default) and effectively have no stacking since we're not really using the FPU for anything other than a fast register store
    "  ldr.w r0, =0xE000EF34    \n"  /* The FPU FPCCR. */
    "  ldr r1, [r0]             \n"  /* read FPCCR */
    "  bfc r1, #30,#2\n" /* Clear bits 30-31. ASPEN and LSPEN. This disables lazy stacking */
    "  str r1, [r0]              \n" /* Write back the modified value to the FPCCR */
    "  dsb                       \n" /* wait for store to complete */
    "  isb"                          /* reset pipeline  */
    :::"r0","r1"
    );
}

enum sysclk_freq {
    SYSCLK_42_MHZ=0,
    SYSCLK_84_MHZ,
    SYSCLK_168_MHZ,
    SYSCLK_200_MHZ,
    SYSCLK_240_MHZ,
};
 
void rcc_set_frequency(enum sysclk_freq freq)
{
    int freqs[]   = {42, 84, 168, 200, 240};
 
    /* USB freqs: 42MHz, 42Mhz, 48MHz, 50MHz, 48MHz */
    int pll_div[] = {2, 4, 7, 10, 10}; 
 
    /* PLL_VCO = (HSE_VALUE / PLL_M) * PLL_N */
    /* SYSCLK = PLL_VCO / PLL_P */
    /* USB OTG FS, SDIO and RNG Clock =  PLL_VCO / PLLQ */
    uint32_t PLL_P = 2;
    uint32_t PLL_N = freqs[freq] * 2;
    uint32_t PLL_M = (HSE_VALUE/1000000);
    uint32_t PLL_Q = pll_div[freq];
 
    RCC_DeInit();
 
    /* Enable HSE osscilator */
    RCC_HSEConfig(RCC_HSE_ON);
 
    if (RCC_WaitForHSEStartUp() == ERROR) {
        return;
    }
 
    /* Configure PLL clock M, N, P, and Q dividers */
    RCC_PLLConfig(RCC_PLLSource_HSE, PLL_M, PLL_N, PLL_P, PLL_Q);
 
    /* Enable PLL clock */
    RCC_PLLCmd(ENABLE);
 
    /* Wait until PLL clock is stable */
    while ((RCC->CR & RCC_CR_PLLRDY) == 0);
 
    /* Set PLL_CLK as system clock source SYSCLK */
    RCC_SYSCLKConfig(RCC_SYSCLKSource_PLLCLK);
 
    /* Set AHB clock divider */
    RCC_HCLKConfig(RCC_SYSCLK_Div1);
 
    //FLASH->ACR = FLASH_ACR_PRFTEN | FLASH_ACR_ICEN |FLASH_ACR_DCEN |FLASH_ACR_LATENCY_5WS;
    FLASH->ACR =  FLASH_ACR_ICEN |FLASH_ACR_DCEN |FLASH_ACR_LATENCY_5WS;

    /* Set APBx clock dividers */
    switch (freq) {
        /* Max freq APB1: 42MHz APB2: 84MHz */
        case SYSCLK_42_MHZ:
            RCC_PCLK1Config(RCC_HCLK_Div1); /* 42MHz */
            RCC_PCLK2Config(RCC_HCLK_Div1); /* 42MHz */
            break;
        case SYSCLK_84_MHZ:
            RCC_PCLK1Config(RCC_HCLK_Div2); /* 42MHz */
            RCC_PCLK2Config(RCC_HCLK_Div1); /* 84MHz */
            break;
        case SYSCLK_168_MHZ:
            RCC_PCLK1Config(RCC_HCLK_Div4); /* 42MHz */
            RCC_PCLK2Config(RCC_HCLK_Div2); /* 84MHz */
            break;
        case SYSCLK_200_MHZ:
            RCC_PCLK1Config(RCC_HCLK_Div4); /* 50MHz */
            RCC_PCLK2Config(RCC_HCLK_Div2); /* 100MHz */
            break;
        case SYSCLK_240_MHZ:
            RCC_PCLK1Config(RCC_HCLK_Div4); /* 60MHz */
            RCC_PCLK2Config(RCC_HCLK_Div2); /* 120MHz */
            break;
    }
 
    /* Update SystemCoreClock variable */
    SystemCoreClockUpdate();
}


void config_backup_sram() {
  RCC_AHB1PeriphClockCmd(RCC_AHB1Periph_BKPSRAM, ENABLE);
  /* disable backup domain write protection */
  RCC_APB1PeriphClockCmd(RCC_APB1Periph_PWR, ENABLE);   // set RCC->APB1ENR.pwren
  PWR_BackupAccessCmd(ENABLE);                          // set PWR->CR.dbp = 1;
  /** enable the backup regulator (used to maintain the backup SRAM content in
    * standby and Vbat modes).  NOTE : this bit is not reset when the device
    * wakes up from standby, system reset or power reset. You can check that
    * the backup regulator is ready on PWR->CSR.brr, see rm p144 */
  PWR_BackupRegulatorCmd(ENABLE);     // set PWR->CSR.bre = 1;
}


// For some weird reason the optimizer likes to delete this whole function, hence set to O0
void __attribute__((optimize("O0")))  SD_NVIC_Configuration(void)
{
        NVIC_InitTypeDef NVIC_InitStructure;


        NVIC_InitStructure.NVIC_IRQChannel = SDIO_IRQn;
        NVIC_InitStructure.NVIC_IRQChannelPreemptionPriority = SDIO_IRQ_PREEMPTION_PRIORITY;    // This must be a lower priority (ie. higher number) than the _MREQ and _IORQ interrupts
        NVIC_InitStructure.NVIC_IRQChannelSubPriority = 0;
        NVIC_InitStructure.NVIC_IRQChannelCmd = ENABLE;
        NVIC_Init(&NVIC_InitStructure);

	// DMA2 STREAMx Interrupt ENABLE
	NVIC_InitStructure.NVIC_IRQChannel = SD_SDIO_DMA_IRQn;
	NVIC_InitStructure.NVIC_IRQChannelPreemptionPriority = SDIO_DMA_PREEMPTION_PRIORITY;
	NVIC_Init(&NVIC_InitStructure);

}

void SDIO_IRQHandler(void)
{
	/* Process All SDIO Interrupt Sources */
	SD_ProcessIRQSrc();
}

void SD_SDIO_DMA_IRQHANDLER(void)
{
	SD_ProcessDMAIRQ();
}

//
// _IORQ interrupt
void config_PC0_int(void) {
        EXTI_InitTypeDef EXTI_InitStruct;
        NVIC_InitTypeDef NVIC_InitStruct;

        /* Enable clock for SYSCFG */
        RCC_APB2PeriphClockCmd(RCC_APB2Periph_SYSCFG, ENABLE);

        SYSCFG_EXTILineConfig(EXTI_PortSourceGPIOC, EXTI_PinSource0);

        EXTI_InitStruct.EXTI_Line = EXTI_Line0;
        /* Enable interrupt */
        EXTI_InitStruct.EXTI_LineCmd = ENABLE;
        /* Interrupt mode */
        EXTI_InitStruct.EXTI_Mode = EXTI_Mode_Interrupt;
        /* Triggers on rising and falling edge */
        //EXTI_InitStruct.EXTI_Trigger = EXTI_Trigger_Rising;
        EXTI_InitStruct.EXTI_Trigger = EXTI_Trigger_Falling;
        /* Add to EXTI */
        EXTI_Init(&EXTI_InitStruct);

        /* Add IRQ vector to NVIC */
        /* PC0 is connected to EXTI_Line0, which has EXTI0_IRQn vector */
        NVIC_InitStruct.NVIC_IRQChannel = EXTI0_IRQn;
        /* Set priority */
        NVIC_InitStruct.NVIC_IRQChannelPreemptionPriority = IORQ_PREEMPTION_PRIORITY;
        /* Set sub priority */
        NVIC_InitStruct.NVIC_IRQChannelSubPriority = 0x00;
        /* Enable interrupt */
        NVIC_InitStruct.NVIC_IRQChannelCmd = ENABLE;
        /* Add to NVIC */
        NVIC_Init(&NVIC_InitStruct);
}


// _MREQ interrupt
void config_PC2_int(void) {
        EXTI_InitTypeDef EXTI_InitStruct;
        NVIC_InitTypeDef NVIC_InitStruct;

        /* Enable clock for SYSCFG */
        RCC_APB2PeriphClockCmd(RCC_APB2Periph_SYSCFG, ENABLE);

        SYSCFG_EXTILineConfig(EXTI_PortSourceGPIOC, EXTI_PinSource2);

        EXTI_InitStruct.EXTI_Line = EXTI_Line2;
        /* Enable interrupt */
        EXTI_InitStruct.EXTI_LineCmd = ENABLE;
        /* Interrupt mode */
        EXTI_InitStruct.EXTI_Mode = EXTI_Mode_Interrupt;
        /* Triggers on rising and falling edge */
        //EXTI_InitStruct.EXTI_Trigger = EXTI_Trigger_Rising;
        EXTI_InitStruct.EXTI_Trigger = EXTI_Trigger_Falling;
        /* Add to EXTI */
        EXTI_Init(&EXTI_InitStruct);

        /* Add IRQ vector to NVIC */
        /* PC2 is connected to EXTI_Line2, which has EXTI2_IRQn vector */
        NVIC_InitStruct.NVIC_IRQChannel = EXTI2_IRQn;
        /* Set priority */
        NVIC_InitStruct.NVIC_IRQChannelPreemptionPriority = MREQ_PREEMPTION_PRIORITY;
        /* Set sub priority */
        NVIC_InitStruct.NVIC_IRQChannelSubPriority = 0x00;
        /* Enable interrupt */
        NVIC_InitStruct.NVIC_IRQChannelCmd = ENABLE;
        /* Add to NVIC */
        NVIC_Init(&NVIC_InitStruct);
}

void config_gpio_portb(void) {
	GPIO_InitTypeDef  GPIO_InitStructure;
	/* GPIOC Periph clock enable */
	RCC_AHB1PeriphClockCmd(RCC_AHB1Periph_GPIOB, ENABLE);
	RCC_APB1PeriphResetCmd(RCC_APB1Periph_USART3, DISABLE);

	/* Configure GPIO Settings */
	// Make sure to init the PS2 keyboard pins here.
	GPIO_InitStructure.GPIO_Pin = GPIO_Pin_8 | GPIO_Pin_9 | GPIO_Pin_10 | GPIO_Pin_11 | GPIO_Pin_12
					| GPIO_Pin_13 | GPIO_Pin_14 | GPIO_Pin_15 ;
	GPIO_InitStructure.GPIO_Mode = GPIO_Mode_OUT;
	GPIO_InitStructure.GPIO_OType = GPIO_OType_OD;
	GPIO_InitStructure.GPIO_Speed = GPIO_Speed_100MHz;
	GPIO_InitStructure.GPIO_PuPd = GPIO_PuPd_NOPULL;
	GPIO_Init(GPIOB, &GPIO_InitStructure);

	GPIOB->ODR = 0xFFFF;
}

void config_gpio_portc(void) {
	GPIO_InitTypeDef  GPIO_InitStructure;
	/* GPIOC Periph clock enable */
	RCC_AHB1PeriphClockCmd(RCC_AHB1Periph_GPIOC, ENABLE);

	/* Configure GPIO Settings */
	GPIO_InitStructure.GPIO_Pin = GPIO_Pin_0 | GPIO_Pin_1 | GPIO_Pin_2 | GPIO_Pin_3 ;
	GPIO_InitStructure.GPIO_Mode = GPIO_Mode_IN;
	GPIO_InitStructure.GPIO_OType = GPIO_OType_PP;
	GPIO_InitStructure.GPIO_Speed = GPIO_Speed_100MHz;
	GPIO_InitStructure.GPIO_PuPd = GPIO_PuPd_UP;
	//GPIO_InitStructure.GPIO_PuPd = GPIO_PuPd_NOPULL;
	GPIO_Init(GPIOC, &GPIO_InitStructure);

	GPIO_InitStructure.GPIO_Pin =  GPIO_Pin_4;
	GPIO_InitStructure.GPIO_Mode = GPIO_Mode_OUT;
	GPIO_InitStructure.GPIO_OType = GPIO_OType_PP;
	GPIO_InitStructure.GPIO_Speed = GPIO_Speed_100MHz;
	GPIO_InitStructure.GPIO_PuPd = GPIO_PuPd_UP;
	GPIO_Init(GPIOC, &GPIO_InitStructure);
	GPIOC->ODR = BUSDIR_HIGH;
}

/* Input/Output data GPIO pins on PD{8..15}. Also PD2 is used fo MOSI on the STM32F407VET6 board I have */
void config_gpio_data(void) {
	GPIO_InitTypeDef  GPIO_InitStructure;
	/* GPIOD Periph clock enable */
	RCC_AHB1PeriphClockCmd(RCC_AHB1Periph_GPIOD, ENABLE);

	/* Configure GPIO Settings */
	GPIO_InitStructure.GPIO_Pin = GPIO_Pin_8 | GPIO_Pin_9 | GPIO_Pin_10 | GPIO_Pin_11 | 
		GPIO_Pin_12 | GPIO_Pin_13 | GPIO_Pin_14 | GPIO_Pin_15;
	GPIO_InitStructure.GPIO_Mode = GPIO_Mode_IN;
	GPIO_InitStructure.GPIO_OType = GPIO_OType_PP;
	GPIO_InitStructure.GPIO_Speed = GPIO_Speed_100MHz;
	//GPIO_InitStructure.GPIO_PuPd = GPIO_PuPd_NOPULL;
	GPIO_InitStructure.GPIO_PuPd = GPIO_PuPd_UP;
	//GPIO_InitStructure.GPIO_PuPd = GPIO_PuPd_DOWN;
	GPIO_Init(GPIOD, &GPIO_InitStructure);

}

/* Input Address GPIO pins on PE{0..15} */
void config_gpio_addr(void) {
	GPIO_InitTypeDef  GPIO_InitStructure;
	/* GPIOE Periph clock enable */
	RCC_AHB1PeriphClockCmd(RCC_AHB1Periph_GPIOE, ENABLE);

	/* Configure GPIO Settings */
	GPIO_InitStructure.GPIO_Pin = 
		GPIO_Pin_0 | GPIO_Pin_1 | GPIO_Pin_2 | GPIO_Pin_3 | 
		GPIO_Pin_4 | GPIO_Pin_5 | GPIO_Pin_6 | GPIO_Pin_7 | 
		GPIO_Pin_8 | GPIO_Pin_9 | GPIO_Pin_10 | GPIO_Pin_11 | 
		GPIO_Pin_12 | GPIO_Pin_13 | GPIO_Pin_14 | GPIO_Pin_15;
	GPIO_InitStructure.GPIO_Mode = GPIO_Mode_IN;
	GPIO_InitStructure.GPIO_OType = GPIO_OType_PP;
	GPIO_InitStructure.GPIO_Speed = GPIO_Speed_100MHz;
	//GPIO_InitStructure.GPIO_PuPd = GPIO_PuPd_DOWN;
	GPIO_InitStructure.GPIO_PuPd = GPIO_PuPd_UP;
	GPIO_Init(GPIOE, &GPIO_InitStructure);
}

#ifdef ENABLE_KEYBOARD_EMULATION
/* Input Address GPIO pins on PD{4..7}. */
/* I dont think PA0 can be used as an input */
void config_gpio_keyboard_row(void) {
	GPIO_InitTypeDef  GPIO_InitStructure;
	/* GPIOE Periph clock enable */
	RCC_AHB1PeriphClockCmd(RCC_AHB1Periph_GPIOD, ENABLE);

	/* Configure GPIO Settings */
	GPIO_InitStructure.GPIO_Pin = GPIO_Pin_4 | GPIO_Pin_5 | GPIO_Pin_6 | GPIO_Pin_7;
	GPIO_InitStructure.GPIO_Mode = GPIO_Mode_IN;
	GPIO_InitStructure.GPIO_OType = GPIO_OType_PP;
	GPIO_InitStructure.GPIO_Speed = GPIO_Speed_100MHz;
	GPIO_InitStructure.GPIO_PuPd = GPIO_PuPd_DOWN;
	GPIO_Init(GPIOD, &GPIO_InitStructure);
}
#endif


/* Debug GPIO pins on PA6  / PA7 / PA8 */
void config_gpio_dbg(void) {
	GPIO_InitTypeDef  GPIO_InitStructure;
	/* GPIOA Periph clock enable */
	RCC_AHB1PeriphClockCmd(RCC_AHB1Periph_GPIOA, ENABLE);
        RCC_APB1PeriphClockCmd(RCC_APB1Periph_UART4,DISABLE);


	/* Configure GPIO Settings */
	GPIO_InitStructure.GPIO_Pin = GPIO_Pin_6 | GPIO_Pin_7 | GPIO_Pin_8 ;
	GPIO_InitStructure.GPIO_Mode = GPIO_Mode_OUT;
	GPIO_InitStructure.GPIO_OType = GPIO_OType_PP;
	GPIO_InitStructure.GPIO_Speed = GPIO_Speed_100MHz;
	GPIO_InitStructure.GPIO_PuPd = GPIO_PuPd_NOPULL;
	GPIO_Init(GPIOA, &GPIO_InitStructure);
}

/* push buttons on PA0, PA1 */
void config_gpio_buttons(void) {
	GPIO_InitTypeDef  GPIO_InitStructure;
	/* GPIOA Periph clock enable */
	RCC_AHB1PeriphClockCmd(RCC_AHB1Periph_GPIOA, ENABLE);


	/* Configure GPIO Settings */
	GPIO_InitStructure.GPIO_Pin = GPIO_Pin_0 | GPIO_Pin_1 | GPIO_Pin_2;
	GPIO_InitStructure.GPIO_Mode = GPIO_Mode_IN;
	GPIO_InitStructure.GPIO_OType = GPIO_OType_PP;
	GPIO_InitStructure.GPIO_Speed = GPIO_Speed_100MHz;
	GPIO_InitStructure.GPIO_PuPd = GPIO_PuPd_UP;
	GPIO_Init(GPIOA, &GPIO_InitStructure);
}



FRESULT __attribute__((optimize("O0")))  load_track(DSK *dsk, uint32_t disk_selects, uint32_t track_number, char *track_buffer) {
        UINT BytesRead;
        FRESULT res = FR_OK;
	uint32_t offset;
	uint32_t track_size;
	uint32_t drive;
	char *b;

	b = track_buffer;
	for (drive=0; drive<MAX_DRIVES;drive++) {
		if ((1<<drive) & disk_selects) {
			if (dsk[drive].fil.obj.id) {	
				if (!dsk[drive].double_sided) {
					// single sided
					offset = track_number * 9 * 512 * 1;
					track_size = SINGLE_SIDED_TRACK;
				} else {
					// double sided
					offset = track_number * 9 * 512 * 2;
					track_size = DOUBLE_SIDED_TRACK;
				}

				res = f_lseek(&dsk[drive].fil, offset);
				if (res == FR_OK) {
					res = f_read(&dsk[drive].fil, b, track_size, &BytesRead);
					// Past the end of a short image the track reads as empty, not as the last disk's data
					if (res != FR_OK) BytesRead = 0;
					if (BytesRead < track_size) memset(b + BytesRead, 0, track_size - BytesRead);
				} else {
       				         blink_pa6_pa7(1000);
				}
			}
		}
		b+=DOUBLE_SIDED_TRACK;
	}

	return res;
}

FRESULT __attribute__((optimize("O0"))) save_track(DSK *dsk, volatile uint32_t *actual_track, char *track_buffer) {
        UINT BytesWritten;
        FRESULT res = FR_OK;
	uint32_t offset;
	uint32_t track_size;
	uint32_t drive;
	char *b;

	b = track_buffer;

	for (drive=0; drive<MAX_DRIVES;drive++) {
		if ((1<<drive) & fdc_write_dirty_bits) {
			if (dsk[drive].fil.obj.id) {
				f_close(&dsk[drive].fil);
				memset(&dsk[drive].fil, 0, sizeof(FIL));
			

				if (!dsk[drive].double_sided) {
					// single sided
					offset = actual_track[drive] * 9 * 512 * 1;
					track_size = SINGLE_SIDED_TRACK;
				} else {
					// double sided
					offset = actual_track[drive] * 9 * 512 * 2;
					track_size = DOUBLE_SIDED_TRACK;
				}

				res = f_open(&dsk[drive].fil, dsk[drive].disk_filename, FA_WRITE);
				if (res != FR_OK) { blink_pa1(3000);}

				res = f_lseek(&dsk[drive].fil, offset);
				if (res == FR_OK) {
					res = f_write(&dsk[drive].fil, b, track_size, &BytesWritten);
				} else {
					blink_pa1(3000);
				}
				f_close(&dsk[drive].fil);
				memset(&dsk[drive].fil, 0, sizeof(FIL));
				res = f_open(&dsk[drive].fil, dsk[drive].disk_filename, FA_READ);
			}
		}
		b+=DOUBLE_SIDED_TRACK;
	}
	return res;

}

// Write out a track that still has sectors waiting, before the image is closed or another track loaded
void flush_track(DSK *dsk) {
	if (fdc_write_flush_count) {
		fdc_write_flush_count = 0;
		save_track(dsk, main_thread_actual_track, (char *) &track_buffer);
		fdc_write_dirty_bits = 0;
	}
}




// ---------------------------------------------------------------------------------------------
// Folders. NEXT/PREV step through the roms, disks and disk sets in button_dir. The menu shows menu_dir.
static char root_directory[] = "msx";
static char button_dir[FOLDER_PATH_LENGTH];
static char menu_dir[FOLDER_PATH_LENGTH];
static char came_from[FF_MAX_LFN + 1];
static uint32_t menu_start_cursor;
static uint32_t menu_count;
static uint32_t menu_flags;

#define MENU_CTRL(off)	((volatile uint8_t *) (MENU_CTRL_BASE + (off)))
#define MENU_ENTRIES	((unsigned char *) &high_64k_base)

static void menu_ctrl_set_u16(uint32_t off, uint32_t v) {
	*MENU_CTRL(off) = v & 0xff;
	*MENU_CTRL(off + 1) = (v >> 8) & 0xff;
}

static uint32_t menu_ctrl_get_u16(uint32_t off) {
	return *MENU_CTRL(off) | (*MENU_CTRL(off + 1) << 8);
}

// Present menu.rom from the root of the SD card
static FRESULT load_menu_rom(void) {
	FRESULT r = load_rom("menu.rom",(char *)CCMRAM_BASE,(char *)&high_64k_base);
	if (r == FR_OK) {
		// The menu is 16K at 0x4000. The rest is the control block and its window, cleared so
		// the BIOS finds no second header at 0x8000
		memset((void *) MENU_CTRL_BASE, 0, 0x10000 - 0x4000);
		strcpy((char *) MENU_CTRL(MENU_CTRL_VERSION), FIRMWARE_VERSION);
		*MENU_CTRL(MENU_CTRL_FLAGS) = menu_flags;
	}
	return r;
}

// Fill the menu list with the folder menu_dir (see MENU_CTRL_* in defines.h). Returns the number of entries.
static uint32_t load_menu_folder(uint32_t start_cursor) {
	uint32_t count, len;
	char *relative = menu_dir + strlen(root_directory);	// "" or eg. "/DSKs/MSX 2"

	count = load_directory(menu_dir, MENU_ENTRIES, relative[0] != 0);

	// If it is too long, keep the end. That is the folder you are in
	len = strlen(relative);
	if (len > MENU_CTRL_PATH_LENGTH) {
		relative += len - MENU_CTRL_PATH_LENGTH;
	}
	strcpy((char *) MENU_CTRL(MENU_CTRL_PATH), relative);
	menu_ctrl_set_u16(MENU_CTRL_COUNT, count);
	menu_ctrl_set_u16(MENU_CTRL_START_CURSOR, (start_cursor < count) ? start_cursor : 0);
	return count;
}

// Entry number of the folder called name in the menu list, or 0
static uint32_t find_menu_folder(char *name, uint32_t count) {
	uint32_t i;
	unsigned char *entry;

	for (i = 0; i < count; i++) {
		entry = MENU_ENTRIES + (i * MENU_ENTRY_SIZE);
		// menu names are cut at MENU_NAME_LENGTH
		if (entry[0] == MENU_TYPE_FOLDER && strncmp((char *) &entry[1], name, MENU_NAME_LENGTH) == 0) {
			return i;
		}
	}
	return 0;
}

static void close_drives(DSK *dsk) {
	for (int drive=0;drive<MAX_DRIVES;drive++) {
		if (dsk[drive].fil.obj.id) {
			f_close(&dsk[drive].fil);
			memset(&dsk[drive].fil, 0, sizeof(FIL));
		}
		dsk[drive].disk_filename[0] = 0;	// null out the first char of the filename (helpful in debugging)
	}
}

// The tape that was started last (see MENU_TAPE_* in defines.h)
static char tape_filename[FOLDER_PATH_LENGTH + 1 + FF_MAX_LFN + 1];

// Read 64K of the tape, from 8K block first on, into banks 8-15. What is past the end is left
static void load_tape_window(uint32_t first) {
	static FIL f;
	UINT n;

	memset(&f, 0, sizeof(FIL));
	if (f_open(&f, tape_filename, FA_READ) == FR_OK) {
		if (f_lseek(&f, first * MENU_TAPE_BLOCK) == FR_OK) {
			f_read(&f, (void *) MENU_ENTRIES, MENU_TAPE_WINDOW, &n);
		}
		f_close(&f);
	}
}

// Present menu.rom with the tape full in it. After the reset the menu sees MENU_CTRL_TAPE, puts
// the tape routines in place and has BASIC load the tape. Returns 0, or -1 if nothing changed
static int32_t start_tape(DSK *dsk, char *full) {
	static FILINFO st;

	if (f_stat(full, &st) != FR_OK || (st.fattrib & AM_DIR) || strlen(full) >= sizeof(tape_filename)) {
		return -1;
	}
	close_drives(dsk);
	deactivate_fdc();
	if (load_menu_rom() != FR_OK) {
		return -1;
	}
	strcpy(tape_filename, full);
	load_tape_window(0);
	*MENU_CTRL(MENU_CTRL_TAPE) = 1;
	menu_ctrl_set_u16(MENU_CTRL_TAPE_SIZE, st.fsize & 0xFFFF);
	menu_ctrl_set_u16(MENU_CTRL_TAPE_SIZE + 2, (st.fsize >> 16) & 0xFFFF);
	return 0;
}

// Present menu.rom with the snapshot full in banks 3-5 and 8-15 (see MENU_SNAP_* in defines.h).
// After the reset the menu puts the MSX back as it was. Returns 0, or -1 if nothing changed
static int32_t start_snapshot(DSK *dsk, char *full) {
	// f_read can not write to CCM, so the VRAM and registers go through here
	static uint32_t buffer[512 / 4];
	static FILINFO st;
	static FIL f;
	volatile uint32_t *to = (volatile uint32_t *) (CCMRAM_BASE + MENU_SNAP_BANK * 0x2000);
	uint32_t done, i, ok;
	UINT n;

	if (f_stat(full, &st) != FR_OK || st.fsize != MENU_SNAP_SIZE) {
		return -1;
	}
	close_drives(dsk);
	deactivate_fdc();
	if (load_menu_rom() != FR_OK) {
		return -1;
	}
	memset(&f, 0, sizeof(FIL));
	if (f_open(&f, full, FA_READ) != FR_OK) {
		return 0;	// the menu then
	}
	ok = f_read(&f, (void *) MENU_ENTRIES, 0x10000, &n) == FR_OK && n == 0x10000;
	for (done = 0x10000; ok && done < MENU_SNAP_SIZE; done += n) {
		ok = f_read(&f, buffer, sizeof(buffer), &n) == FR_OK && n > 0;
		for (i = 0; ok && i < (n + 3) / 4; i++) {
			*to++ = buffer[i];
		}
	}
	f_close(&f);
	*MENU_CTRL(MENU_CTRL_SNAP) = ok;
	return 0;
}

// Present full: a .dsk, a disk set (folder) starting on disk_number, a rom, a tape or a snapshot.
// Returns 1 if a disk was put in (the caller then has track 0 loaded), 0 for the others and -1 if
// nothing changed.
static int32_t start_image(DSK *dsk, char *full, uint32_t disk_number) {
	static FILINFO st;

	// A sector written just before must reach the old image first
	flush_track(dsk);
	if (is_tape_image(full)) {
		disk_index = 0;
		disk_index_max = 0;
		return start_tape(dsk, full);
	}
	if (is_snapshot(full)) {
		disk_index = 0;
		disk_index_max = 0;
		return start_snapshot(dsk, full);
	}
	disk_index = disk_number;
	if (load_disks(dsk,full,&disk_index,&disk_index_max)) {
		load_rom("disk.rom",(char *)CCMRAM_BASE,(char *)&high_64k_base);
		// this willl activate the FDC emulation
		init_fdc();
		// track 0 of both drives
		main_thread_data = 0 | 0x40000000 | 0x20000000;
		return 1;
	}
	disk_index = 0;
	disk_index_max = 0;
	// A disk set without the disk asked for is left as it is
	if (f_stat(full, &st) != FR_OK || (st.fattrib & AM_DIR)) {
		return -1;
	}
	close_drives(dsk);
	deactivate_fdc();
	if (load_rom(full,(char *)CCMRAM_BASE,(char *)&high_64k_base) != FR_OK) {
		return -1;
	}
	return 0;
}

// The n'th (from 0) thing NEXT/PREV can start in path. FALSE if there are not that many
static uint32_t nth_image(char *path, int32_t n, FILINFO *fno) {
	DIR d;
	int32_t i;

	memset(&d, 0, sizeof(DIR));
	if (n < 0 || f_opendir(&d, path) != FR_OK) {
		return FALSE;
	}
	for (i = 0; i <= n; i++) {
		if (readdir_image(&d, path, fno) != FR_OK || fno->fname[0] == 0) {
			f_closedir(&d);
			return FALSE;
		}
	}
	f_closedir(&d);
	return TRUE;
}

static int32_t count_images(char *path, FILINFO *fno) {
	DIR d;
	int32_t n = 0;

	memset(&d, 0, sizeof(DIR));
	if (f_opendir(&d, path) != FR_OK) {
		return 0;
	}
	while (readdir_image(&d, path, fno) == FR_OK && fno->fname[0] != 0) {
		n++;
	}
	f_closedir(&d);
	return n;
}

// full = path/name, if it fits
static uint32_t make_path(char *full, char *path, char *name) {
	if (strlen(path) + 1 + strlen(name) > FOLDER_PATH_LENGTH + FF_MAX_LFN) {
		return FALSE;
	}
	strcpy(full, path);
	strcat(full, "/");
	strcat(full, name);
	return TRUE;
}

// Copy the cover in path (see MENU_COVER_* in defines.h) to its two banks. TRUE if it is there
// and looks right
static uint32_t read_cover(char *path) {
	// f_read can not write to CCM (the SD card's DMA does not reach it), so it goes through here
	static uint32_t buffer[512 / 4];
	static FIL f;
	static const uint32_t from[2] = { MENU_COVER_HEADER, MENU_COVER_HEADER + MENU_COVER_COLOURS };
	volatile uint32_t *to;
	uint32_t part, done, i, ok;
	UINT n;

	memset(&f, 0, sizeof(FIL));
	if (f_open(&f, path, FA_READ) != FR_OK) {
		return FALSE;
	}
	ok = f_size(&f) >= MENU_COVER_FILE_SIZE && f_read(&f, buffer, 1, &n) == FR_OK && n == 1 &&
	     (buffer[0] & 0xFF) == 0xFE;
	for (part = 0; ok && part < 2; part++) {
		to = (volatile uint32_t *) (CCMRAM_BASE + (MENU_COVER_BANK + part) * 0x2000);
		ok = f_lseek(&f, from[part]) == FR_OK;
		for (done = 0; ok && done < MENU_COVER_PART_SIZE; done += sizeof(buffer)) {
			ok = f_read(&f, buffer, sizeof(buffer), &n) == FR_OK && n == sizeof(buffer);
			for (i = 0; ok && i < sizeof(buffer) / 4; i++) {
				*to++ = buffer[i];
			}
		}
	}
	f_close(&f);
	return ok;
}

// The cover of menu entry selected: Game.sc2 next to it, or for a folder cover.sc2 in it
static uint32_t load_cover(uint32_t selected) {
	static char path[FOLDER_PATH_LENGTH + 1 + FF_MAX_LFN + sizeof("/" MENU_COVER_IN_FOLDER)];
	static char name[FF_MAX_LFN + 1];
	static FILINFO cover_fno;
	unsigned char *entry = MENU_ENTRIES + selected * MENU_ENTRY_SIZE;
	uint32_t type, len;

	if (selected >= menu_count || entry[0] == MENU_TYPE_UP) {
		return FALSE;
	}
	type = entry[0];
	strcpy(name, (char *) &entry[1]);
	if (strlen(name) >= MENU_NAME_LENGTH) {
		// The menu has only the start of a long name, so look the file up
		DIR cover_dir;
		int32_t images_before;
		char *dot;

		memset(&cover_dir, 0, sizeof(DIR));
		res = find_menu_entry(&cover_dir, menu_dir, menu_entry_ordinal(selected), &cover_fno, &type, &images_before);
		f_closedir(&cover_dir);
		if (res != FR_OK || cover_fno.fname[0] == 0) {
			return FALSE;
		}
		strcpy(name, cover_fno.fname);
		// without the extension, as the menu shows it
		dot = strrchr(name, '.');
		if (dot && !(cover_fno.fattrib & AM_DIR)) {
			*dot = 0;
		}
	}
	len = strlen(menu_dir) + 1 + strlen(name);
	if (len + sizeof("/" MENU_COVER_IN_FOLDER) > sizeof(path)) {
		return FALSE;
	}
	strcpy(path, menu_dir);
	strcat(path, "/");
	strcat(path, name);
	strcat(path, MENU_COVER_SUFFIX);
	if (read_cover(path)) {
		return TRUE;
	}
	if (type == MENU_TYPE_FOLDER || type == MENU_TYPE_DISK_SET) {
		path[len] = 0;
		strcat(path, "/" MENU_COVER_IN_FOLDER);
		return read_cover(path);
	}
	return FALSE;
}

// The song being played (see MENU_SONG_* in defines.h)
static char song_filename[FOLDER_PATH_LENGTH + 1 + FF_MAX_LFN + 1];

// 16K of the song, from chunk on, into banks 3-4 (half 0) or 5-6. Chunk 0 is of menu entry
// selected; the later ones of the same file
static void load_song_chunk(uint32_t selected, uint32_t chunk, uint32_t half) {
	// f_read can not write to CCM, so it goes through here
	static uint32_t buffer[512 / 4];
	static FIL f;
	volatile uint32_t *to = (volatile uint32_t *) (CCMRAM_BASE + (MENU_SONG_BANK + half * 2) * 0x2000);
	uint32_t done = 0, i;
	UINT n;

	if (chunk == 0) {
		song_filename[0] = 0;
		if (selected < menu_count && MENU_ENTRIES[selected * MENU_ENTRY_SIZE] == MENU_TYPE_SONG) {
			DIR song_dir;
			int32_t images_before;
			uint32_t type;

			memset(&song_dir, 0, sizeof(DIR));
			res = find_menu_entry(&song_dir, menu_dir, menu_entry_ordinal(selected), &fno, &type, &images_before);
			f_closedir(&song_dir);
			if (res != FR_OK || fno.fname[0] == 0 || type != MENU_TYPE_SONG ||
			    !make_path(song_filename, menu_dir, fno.fname)) {
				song_filename[0] = 0;
			}
		}
	}
	memset(&f, 0, sizeof(FIL));
	if (song_filename[0] && f_open(&f, song_filename, FA_READ) == FR_OK) {
		if (f_lseek(&f, chunk * MENU_SONG_CHUNK) == FR_OK) {
			while (done < MENU_SONG_CHUNK && f_read(&f, buffer, sizeof(buffer), &n) == FR_OK && n > 0) {
				for (i = n; i < sizeof(buffer); i++) {
					((uint8_t *) buffer)[i] = 0x66;
				}
				for (i = 0; i < sizeof(buffer) / 4; i++) {
					*to++ = buffer[i];
				}
				done += sizeof(buffer);
			}
		}
		f_close(&f);
	}
	// past the end: VGM's end command
	for (; done < MENU_SONG_CHUNK; done += 4) {
		*to++ = 0x66666666;
	}
}

int __attribute__((optimize("O0")))  main(void) {

	TCHAR full_filename[FOLDER_PATH_LENGTH + 1 + FF_MAX_LFN + 1];
	uint64_t next_button_debounce;
	int first_time;
	uint32_t	button_state;
	int32_t	file_counter;
        DSK dsk[MAX_DRIVES];

	// You have to disable lazy stacking BEFORE initialising the scratch fpu registers
	enable_fpu_and_disable_lazy_stacking();
	init_fpu_regs();
	// where the rom's banks are, before EXTI2 reads through it
	set_banks_ram((char *) CCMRAM_BASE, (char *) &high_64k_base);

	register uint32_t main_thread_command_reg asm("r10") __attribute__((unused)) = 0;
	uint32_t main_cmd;

// main_thread_command lives in r10 and the EXTI2 handler writes it too. Every update from here
// must be one instruction, otherwise the handler can write r10 in the middle of a
// read-modify-write and its new command is lost.
#define MAIN_CMD_SET(v)	__asm volatile("mov %0,%1" : "=r"(main_thread_command_reg) : "i"(v))
#define MAIN_CMD_OR(v)	__asm volatile("orr %0,%0,%1" : "+r"(main_thread_command_reg) : "i"(v))

	rcc_set_frequency(SYSCLK_240_MHZ);

	RCC_AHB1PeriphClockCmd(RCC_AHB1Periph_CCMDATARAMEN, ENABLE);

	/* PD{8..15}  and PD2 for SD card MOSI*/
	config_gpio_data();
	/* PE{0..15} */
	config_gpio_addr();
	
	config_gpio_portc();

	/* PA6/7 */
	config_gpio_dbg();

	config_gpio_buttons();

	config_backup_sram();


	  // switch on compensation cell
	RCC->APB2ENR |= 0 |  RCC_APB2ENR_SYSCFGEN ;
	SYSCFG->CMPCR |= SYSCFG_CMPCR_CMP_PD; // enable compensation cell
	while ((SYSCFG->CMPCR & SYSCFG_CMPCR_READY) == 0);  // wait until ready

	NVIC_PriorityGroupConfig(NVIC_PriorityGroup_4); 
	SysTick->CTRL  = 0;



	SD_NVIC_Configuration();


#ifdef ENABLE_SEMIHOSTING
	initialise_monitor_handles();   /*rtt*/
        printf("Starting\n");
#endif

        memset(&fs32, 0, sizeof(FATFS));
        res = f_mount(&fs32, "",0);
        if (res != FR_OK) {
                blink_pa6_pa7(250);
        }


        static FILINFO fno;

	// upgrade.bin in the root of the SD card? Let the bootloader flash it (see bootloader/bl_main.c).
	// The bootloader sets UPGRADE_NO_RETRY when it has had a go, so a file it could not use
	// does not send us round in circles. This has to come before a rom is loaded into CCM.
	if (*(volatile uint32_t *) UPGRADE_FLAG_ADDR != UPGRADE_NO_RETRY && f_stat(UPGRADE_FILENAME, &fno) == FR_OK) {
		*(volatile uint32_t *) UPGRADE_FLAG_ADDR = UPGRADE_MAGIC;
		NVIC_SystemReset();
	}

        res = f_stat(root_directory, &fno);
        if (res != FR_OK) {
                blink_pa6_pa7(100);
        }
	menu_flags = (f_stat("disk.rom", &fno) == FR_OK) ? 0 : MENU_FLAG_NO_DISK_ROM;
	if (!flash_roms_possible()) {
		menu_flags |= MENU_FLAG_NO_FLASH_ROMS;
	}
	strcpy(button_dir, root_directory);
	strcpy(menu_dir, root_directory);
	menu_start_cursor = 0;
	menu_count = 0;


#ifdef ENABLE_RTC_RAM_BANK_EMULATION
	config_PC0_int();
#endif
	config_PC2_int();


	next_button_debounce=0;
	file_counter=-1;
	disk_index=0;
	disk_index_max=0;
	// This memset is actually really important
	for (int drive=0;drive<MAX_DRIVES;drive++) {
		memset(&dsk[drive].fil, 0, sizeof(FIL));
	}

	// attempt to load the special menu rom. See kcmfs. Without it, start on the first rom or disk
	first_time = (load_menu_rom() != FR_OK);

	while(1) {
		button_state = GPIOA->IDR;
		if (!(button_state & NEXT_ROM_OR_DISK_MASK) || !(button_state & PREV_ROM_OR_DISK_MASK) || first_time) {
			if (next_button_debounce == 0 ) {
				uint32_t next = first_time;
				uint32_t prev = FALSE;
				int32_t started = -1;

				if (!first_time) {
					// Give the other button a moment, to see NEXT and PREV pressed together
					delay_ms(50);
					button_state = GPIOA->IDR;
					next = !(button_state & NEXT_ROM_OR_DISK_MASK);
					prev = !(button_state & PREV_ROM_OR_DISK_MASK);
				}
				first_time = FALSE;
				if (next && prev) {
					// Both: back to the menu. It starts when the MSX is reset
					flush_track(dsk);
					close_drives(dsk);
					deactivate_fdc();
					disk_index = 0;
					disk_index_max = 0;
					if (load_menu_rom() == FR_OK) {
						started = 0;
					}
				} else if (next || prev) {
					if (disk_index_max > 1 && ((next && disk_index < disk_index_max) || (prev && disk_index > 1))) {
						// the next or previous disk of a game on several disks
						started = start_image(dsk, full_filename, next ? disk_index + 1 : disk_index - 1);
					} else {
						uint32_t found;
						if (next) {
							file_counter++;
							found = nth_image(button_dir, file_counter, &fno);
							if (!found) {
								// allow buttonpushes to 'wrap round'
								file_counter = 0;
								found = nth_image(button_dir, file_counter, &fno);
							}
						} else {
							int32_t n = count_images(button_dir, &fno);
							file_counter = (file_counter > 0 && file_counter <= n) ? file_counter - 1 : n - 1;
							found = nth_image(button_dir, file_counter, &fno);
						}
						if (found && make_path(full_filename, button_dir, fno.fname)) {
#ifdef DEBUG_FILENAME
							strcpy(debug_filename,full_filename);
#endif
							started = start_image(dsk, full_filename, 1);
						}
					}
				}
				if (started == 1) {
					// load track 0 in the next block of code
					MAIN_CMD_SET(MAIN_THREAD_BUTTON_COMMAND);
				} else if (started == 0) {
					MAIN_CMD_SET(0);
				}
				//next_button_debounce=5850000;
				next_button_debounce=3000000;
			} 
		}
		next_button_debounce = (next_button_debounce>0)?next_button_debounce-1:0;

		main_cmd = main_thread_command_reg;
		if (!(main_cmd & 0xc0000000) && (main_cmd & 0xff)) {
			switch(main_cmd) {
				case (MAIN_THREAD_BUTTON_COMMAND):
				case (MAIN_THREAD_SEEK_COMMAND): {
					MAIN_CMD_OR(MAIN_COMMAND_IN_PROGRESS);
					// Check if there is any pending write
					flush_track(dsk);
					// main_thread_data contains the track number
					// bit 31 is DSK3 (not implemented) , bit 30 is DSK2, bit 29 is DSK1
					load_track(dsk, (main_thread_data>>29), (main_thread_data & 0xff), (char *) &track_buffer);
					delay_ms(1);
					for (int drive = 0 ; drive<MAX_DRIVES ; drive++) {
						if (1<<drive & (main_thread_data>>29)) {
							main_thread_actual_track[drive] = (main_thread_data & 0xff);
						}
					}
					update_fdc_track_from_intended_track_register();
					if ((main_cmd & 0xff) == MAIN_THREAD_SEEK_COMMAND) {
						MAIN_CMD_OR(MAIN_COMMAND_COMPLETE);
					} else {
						// must be a next/prev button push so make sure we don't feed an INTRQ in
						MAIN_CMD_SET(0);
					}

					break;
				}
				case (MAIN_THREAD_COMMAND_LOAD_DIRECTORY): {
					MAIN_CMD_OR(MAIN_COMMAND_IN_PROGRESS);
					// The menu comes back in the folder it was last in, on the entry last started
					menu_count = load_menu_folder(menu_start_cursor);
					// r10 first: the menu can send the next command as soon as it sees 0
					MAIN_CMD_SET(0);
					*MENU_CTRL(MENU_CTRL_COMMAND) = 0;
					break;
				}
				case (MAIN_THREAD_COMMAND_CHANGE_DIR): {
					MAIN_CMD_OR(MAIN_COMMAND_IN_PROGRESS);
					// The menu writes the number of the ".." or folder entry it wants to open
					uint32_t selected = menu_ctrl_get_u16(MENU_CTRL_SELECTED);
					unsigned char type = (selected < menu_count) ? MENU_ENTRIES[selected * MENU_ENTRY_SIZE] : 0;
					char *slash = strrchr(menu_dir, '/');

					came_from[0] = 0;
					menu_start_cursor = 0;
					if (type == MENU_TYPE_UP && slash && strlen(menu_dir) > strlen(root_directory)) {
						strcpy(came_from, slash + 1);
						*slash = 0;
					} else if (type == MENU_TYPE_FOLDER) {
						DIR folder_dir;
						int32_t images_before;
						uint32_t found_type;

						memset(&folder_dir, 0, sizeof(DIR));
						res = find_menu_entry(&folder_dir, menu_dir, menu_entry_ordinal(selected), &fno, &found_type, &images_before);
						f_closedir(&folder_dir);
						if (res == FR_OK && found_type == MENU_TYPE_FOLDER && strlen(menu_dir) + 1 + strlen(fno.fname) < FOLDER_PATH_LENGTH) {
							strcat(menu_dir, "/");
							strcat(menu_dir, fno.fname);
							menu_start_cursor = 1;		// first thing after ".."
						}
					}
					menu_count = load_menu_folder(menu_start_cursor);
					if (came_from[0]) {
						// Going up. Start on the folder we just left
						menu_start_cursor = find_menu_folder(came_from, menu_count);
						menu_ctrl_set_u16(MENU_CTRL_START_CURSOR, menu_start_cursor);
					}
					MAIN_CMD_SET(0);
					*MENU_CTRL(MENU_CTRL_COMMAND) = 0;
					break;
				}
				case (MAIN_THREAD_COMMAND_LOAD_COVER): {
					MAIN_CMD_OR(MAIN_COMMAND_IN_PROGRESS);
					*MENU_CTRL(MENU_CTRL_COVER) = load_cover(menu_ctrl_get_u16(MENU_CTRL_SELECTED));
					MAIN_CMD_SET(0);
					*MENU_CTRL(MENU_CTRL_COMMAND) = 0;
					break;
				}
				case (MAIN_THREAD_COMMAND_PREPARE): {
					MAIN_CMD_OR(MAIN_COMMAND_IN_PROGRESS);
					// A rom over 128K goes to flash now, while the MSX waits in RAM (see
					// MENU_CTRL_READY). The list in high_64k_base is used as the buffer
					uint32_t selected = menu_ctrl_get_u16(MENU_CTRL_SELECTED);

					if (selected < menu_count && MENU_ENTRIES[selected * MENU_ENTRY_SIZE] == MENU_TYPE_ROM) {
						DIR entry_dir;
						int32_t images_before;
						uint32_t type;

						memset(&entry_dir, 0, sizeof(DIR));
						res = find_menu_entry(&entry_dir, menu_dir, menu_entry_ordinal(selected), &fno, &type, &images_before);
						f_closedir(&entry_dir);
						if (res == FR_OK && fno.fname[0] != 0 && type == MENU_TYPE_ROM &&
						    fno.fsize > MAX_ROM_SIZE && make_path(full_filename, menu_dir, fno.fname)) {
							prepare_rom(full_filename, (char *) &high_64k_base);
						}
					}
					*MENU_CTRL(MENU_CTRL_READY) = 'R';
					*MENU_CTRL(MENU_CTRL_READY + 1) = 'D';
					*MENU_CTRL(MENU_CTRL_READY + 2) = 'Y';
					*MENU_CTRL(MENU_CTRL_READY + 3) = '!';
					MAIN_CMD_SET(0);
					*MENU_CTRL(MENU_CTRL_COMMAND) = 0;
					break;
				}
				case (MAIN_THREAD_COMMAND_SONG): {
					MAIN_CMD_OR(MAIN_COMMAND_IN_PROGRESS);
					load_song_chunk(menu_ctrl_get_u16(MENU_CTRL_SELECTED), menu_ctrl_get_u16(MENU_CTRL_SONG_CHUNK),
							*MENU_CTRL(MENU_CTRL_SONG_HALF) & 1);
					MAIN_CMD_SET(0);
					*MENU_CTRL(MENU_CTRL_COMMAND) = 0;
					break;
				}
				case (MAIN_THREAD_COMMAND_TAPE_WINDOW): {
					MAIN_CMD_OR(MAIN_COMMAND_IN_PROGRESS);
					load_tape_window(menu_ctrl_get_u16(MENU_CTRL_TAPE_BLOCK));
					MAIN_CMD_SET(0);
					*MENU_CTRL(MENU_CTRL_COMMAND) = 0;
					break;
				}
				case (MAIN_THREAD_COMMAND_LOAD_ROM): {
					MAIN_CMD_OR(MAIN_COMMAND_IN_PROGRESS);
					// The menu writes the number of the (sorted) entry it wants
					uint32_t selected = menu_ctrl_get_u16(MENU_CTRL_SELECTED);
					int32_t started = -1;

					if (selected < menu_count) {
						DIR entry_dir;
						int32_t images_before;
						uint32_t type;

						memset(&entry_dir, 0, sizeof(DIR));
						res = find_menu_entry(&entry_dir, menu_dir, menu_entry_ordinal(selected), &fno, &type, &images_before);
						f_closedir(&entry_dir);
						if (res == FR_OK && fno.fname[0] != 0 && type != MENU_TYPE_FOLDER && type != MENU_TYPE_SONG &&
						    make_path(full_filename, menu_dir, fno.fname)) {
							// NEXT/PREV carry on from here, and the menu comes back on it
							strcpy(button_dir, menu_dir);
							file_counter = images_before;
							menu_start_cursor = selected;
							started = start_image(dsk, full_filename, 1);
						}
					}
					if (started == 1) {
						// load track 0 in the next block of code
						MAIN_CMD_SET(MAIN_THREAD_BUTTON_COMMAND);
					} else {
						MAIN_CMD_SET(0);
					}
					if (started < 0) {
						// Nothing was loaded and the menu is still there. It resets and comes back
						*MENU_CTRL(MENU_CTRL_COMMAND) = 0;
					}
					break;
				}
			}
		}

		if (fdc_write_flush_count) {
			fdc_write_flush_count--;
			if (fdc_write_flush_count == 0) {
				save_track(dsk, main_thread_actual_track, (char *) &track_buffer);
				fdc_write_dirty_bits = 0;
			}
		}
	}
}