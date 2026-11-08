
# Put your stlink folder here so make burn will work.
STLINK=~/stlink.git

#SRCS=main.c system_stm32f4xx.c stm32f4xx_it.c
#SRCS=main.c system_stm32f4xx.c working-stm32f4xx_it.c

SRCS=main.c system_stm32f4xx.c util.c

# Library modules
SRCS += stm32f4xx_exti.c stm32f4xx_gpio.c stm32f4xx_rcc.c stm32f4xx_pwr.c stm32f4xx_syscfg.c
SRCS += stm32f4xx_tim.c misc.c stm32f4xx_flash.c

# Add in stuff for SD access
SRCS += diskio.c  ff.c ffunicode.c stm32f4_discovery.c  stm32f4_discovery_sdio_sd.c system_stm32f4xx.c misc_handlers.c stm32f4xx_sdio.c stm32f4xx_dma.c

#SRCS += stm32f4_discovery.c

# Binaries will be generated with this name (.elf, .bin, .hex, etc)
PROJ_NAME=msx-rom-and-floppy-emulator

#######################################################################################

#STM_COMMON=../../..
# You need libs somewhere!
# I used the STM32F4DISCOVERY firmware at http://www.st.com/web/en/catalog/tools/PF257904# 
#STM_COMMON=../STM32F4-Discovery_FW_V1.1.0
# Libraries/ and Utilities/ from that package copied straight in next to this project
STM_COMMON=..

CC=arm-none-eabi-gcc
OBJCOPY=arm-none-eabi-objcopy

# NOTE: -mgeneral-regs-only does not work with gcc 7. I used gcc 9
#CFLAGS  =  -g -O2 -Wall -Tstm32_flash.ld -mno-unaligned-access -fsingle-precision-constant  -mgeneral-regs-only
#CFLAGS  =  -g -O2 -Wall -Tstm32_flash.ld -fsingle-precision-constant  -mgeneral-regs-only
## -ffunction-sections is meant to keep the literal pools closer to where they are referenced
CFLAGS  =  -g -O2 -Wall -Tstm32_flash.ld -ffunction-sections -fdata-sections -fomit-frame-pointer 
CFLAGS += -DUSE_STDPERIPH_DRIVER
# The emulator sits above the bootloader. See upgrade.h
CFLAGS += -DVECT_TAB_OFFSET=0x10000
#CFLAGS += -mlittle-endian -mthumb -mcpu=cortex-m4 -mthumb-interwork
CFLAGS += -mlittle-endian -mthumb -mcpu=cortex-m4 
CFLAGS += -mfloat-abi=hard -mfpu=fpv4-sp-d16
#CFLAGS += -mfloat-abi=softfp -mfpu=fpv4-sp-d16
#CFLAGS += -mfloat-abi=soft
CFLAGS += -I.
CFLAGS += --specs=nosys.specs
#CFLAGS += -specs=nano.specs -specs=rdimon.specs -lc -lrdimon
## Even though we specify these registers in main.c as global, still need to specify here to stop FATFS and anything else using though (though we luck out with any other libs linked in)
## This register list must match what is in defines.h
CFLAGS += -ffixed-s0 -ffixed-s1 -ffixed-s2 -ffixed-s3 -ffixed-s4 -ffixed-s5 -ffixed-s6 -ffixed-s7 -ffixed-s8 -ffixed-s9 -ffixed-s10 -ffixed-s11 -ffixed-s12 -ffixed-s13 -ffixed-s14 -ffixed-s15 -ffixed-s16 -ffixed-s17 -ffixed-s18 -ffixed-s19 -ffixed-s20 -ffixed-s21 -ffixed-s22 -ffixed-s23 -ffixed-s24 -ffixed-s25 -ffixed-s26 -ffixed-s27 -ffixed-s28 -ffixed-s29 -ffixed-s30 -ffixed-s31

CFLAGS += -ffixed-r10

#CFLAGS += -DENABLE_RTC_RAM_BANK_EMULATION
#CFLAGS += -DDEBUG_EXTI2_START
#CFLAGS += -DDEBUG_EXTI2_END
#CFLAGS += -DDEBUG_EXTI2_ROM_ACCESS
#CFLAGS += -DDEBUG_EXTI0_START
#CFLAGS += -DDEBUG_EXTI0_END
#CFLAGS += -DDEBUG_IO_00B4
#CFLAGS += -DDEBUG_IO_00B5
#CFLAGS += -DDEBUG_IO_00B5_READ
#CFLAGS += -DENABLE_SEMIHOSTING
#CFLAGS += -DDEBUG_FDC
#CFLAGS += -DDEBUG_FDC_STATUS_READ
#CFLAGS += -DENABLE_FDC_CCM_LOGGING
#CFLAGS += -DDEBUG_FILENAME


# Include files from STM libraries
CFLAGS += -I$(STM_COMMON)/Utilities/STM32F4-Discovery
CFLAGS += -I$(STM_COMMON)/Libraries/CMSIS/Include 
CFLAGS += -I$(STM_COMMON)/Libraries/CMSIS/ST/STM32F4xx/Include
CFLAGS += -I$(STM_COMMON)/Libraries/STM32F4xx_StdPeriph_Driver/inc


# add startup file to build
SRCS += startup_stm32f4xx.s 
# You need to end asm files in capital S to get them to see preprocessor directives
SRCS += interrupt.S

OBJS = $(SRCS:.c=.o)

vpath %.c $(STM_COMMON)/Libraries/STM32F4xx_StdPeriph_Driver/src $(STM_COMMON)/Utilities/STM32F4-Discovery

#######################################################################################
# SD card bootloader (bootloader/bl_main.c). Only needs the SD card, FatFs and the flash driver.
# No long filenames and a small code page, so it fits in the 64K below the emulator.

BL_NAME=bootloader
BL_SRCS = bootloader/bl_main.c system_stm32f4xx.c startup_stm32f4xx.s misc_handlers.c
BL_SRCS += diskio.c ff.c stm32f4_discovery.c stm32f4_discovery_sdio_sd.c
BL_SRCS += stm32f4xx_gpio.c stm32f4xx_rcc.c stm32f4xx_sdio.c stm32f4xx_dma.c stm32f4xx_flash.c misc.c

BL_CFLAGS  = -g -Os -Wall -Tbootloader/bootloader.ld -ffunction-sections -fdata-sections -Wl,--gc-sections
BL_CFLAGS += -DUSE_STDPERIPH_DRIVER -DFF_USE_LFN=0 -DFF_CODE_PAGE=437
BL_CFLAGS += -mlittle-endian -mthumb -mcpu=cortex-m4 -mfloat-abi=hard -mfpu=fpv4-sp-d16
BL_CFLAGS += -I. --specs=nosys.specs
BL_CFLAGS += -I$(STM_COMMON)/Utilities/STM32F4-Discovery
BL_CFLAGS += -I$(STM_COMMON)/Libraries/CMSIS/Include
BL_CFLAGS += -I$(STM_COMMON)/Libraries/CMSIS/ST/STM32F4xx/Include
BL_CFLAGS += -I$(STM_COMMON)/Libraries/STM32F4xx_StdPeriph_Driver/inc

#######################################################################################
# Outputs
#   $(PROJ_NAME).bin       the emulator on its own, at 0x08010000
#   upgrade.bin            same thing. Copy it to the root of the SD card to upgrade
#   $(BL_NAME).bin         the bootloader on its own, at 0x08000000
#   $(PROJ_NAME)-full.bin  bootloader + emulator. Flash this to 0x08000000 the first time (DFU or ST-Link)

.PHONY: proj bootloader full

all: proj bootloader full

proj: $(PROJ_NAME).elf

bootloader: $(BL_NAME).elf

full: $(PROJ_NAME)-full.bin

# Each build counts build_number up by one. It is the last part of FIRMWARE_VERSION (defines.h)
$(PROJ_NAME).elf: $(SRCS)
	n=$$(( $$(cat build_number 2>/dev/null || echo 0) + 1 )) && echo $$n > build_number && \
	$(CC) $(CFLAGS) -DFIRMWARE_BUILD=$$n $^ -o $@
	$(OBJCOPY) -O ihex $(PROJ_NAME).elf $(PROJ_NAME).hex
	$(OBJCOPY) -O binary $(PROJ_NAME).elf $(PROJ_NAME).bin
	$(OBJCOPY) -O binary $(PROJ_NAME).elf upgrade.bin

$(BL_NAME).elf: $(BL_SRCS) upgrade.h
	$(CC) $(BL_CFLAGS) $(filter-out upgrade.h,$^) -o $@
	$(OBJCOPY) -O ihex $(BL_NAME).elf $(BL_NAME).hex
	$(OBJCOPY) -O binary $(BL_NAME).elf $(BL_NAME).bin

# Glue the emulator binary on to the bootloader at 0x08010000, gap filled with erased flash
$(PROJ_NAME)-full.bin: $(BL_NAME).elf $(PROJ_NAME).elf
	$(OBJCOPY) --add-section .app=$(PROJ_NAME).bin --set-section-flags .app=alloc,load,readonly,data,contents --change-section-address .app=0x08010000 $(BL_NAME).elf $(PROJ_NAME)-full.elf
	$(OBJCOPY) -O binary --gap-fill 0xFF $(PROJ_NAME)-full.elf $(PROJ_NAME)-full.bin
	$(OBJCOPY) -O ihex $(PROJ_NAME)-full.elf $(PROJ_NAME)-full.hex

clean:
	rm -f *.o
	rm -f $(PROJ_NAME).elf $(PROJ_NAME).hex $(PROJ_NAME).bin upgrade.bin
	rm -f $(BL_NAME).elf $(BL_NAME).hex $(BL_NAME).bin
	rm -f $(PROJ_NAME)-full.elf $(PROJ_NAME)-full.hex $(PROJ_NAME)-full.bin


# Flash the STM32F4
#burn: proj
#	$(STLINK)/st-flash write $(PROJ_NAME).bin 0x8000000