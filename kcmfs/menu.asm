; KCMFS - kernelcrash MSX file selector, for msx-rom-and-floppy-emulator
;
; A 16K rom at 0x4000. The stm32f4 board shows its control block at 0x8000 and the folder
; list through an 8K window at 0xA000 (see MENU_CTRL_* in ../defines.h).
; Runs on MSX1 and MSX2 in SCREEN 1: 32x24, a colour for each group of 8 characters. Covers
; are shown full screen in SCREEN 2.
;
; Build with build.sh (sjasmplus). -DSIM builds menu-sim.rom (32K) with a list and a cover built
; in, to try the menu out in an emulator such as openMSX without the stm32f4 board.

	IFDEF SIM
	OUTPUT "menu-sim.rom"
	ELSE
	IFDEF SIMTAPE
	OUTPUT "menu-simtape.rom"
	ELSE
	OUTPUT "menu.rom"
	ENDIF
	ENDIF

; ---- BIOS
RDSLT		equ	0x000C
WRSLT		equ	0x0014
DISSCR		equ	0x0041
ENASCR		equ	0x0044
WRTVDP		equ	0x0047
FILVRM		equ	0x0056
LDIRMV		equ	0x0059
LDIRVM		equ	0x005C
CHGCLR		equ	0x0062
INIT32		equ	0x006F
INIGRP		equ	0x0072
CHSNS		equ	0x009C
CHGET		equ	0x009F
ERAFNC		equ	0x00CC
WRTPSG		equ	0x0093
ROMID		equ	0x002B		; bit 7: 50 Hz
TAPION		equ	0x00E1
TAPIN		equ	0x00E4
ENASLT		equ	0x0024
RSLREG		equ	0x0138
MSXVER		equ	0x002D		; 0 MSX1, 1 MSX2, 2 MSX2+, 3 turbo R

; ---- system variables
T32NAM		equ	0xF3BD
T32COL		equ	0xF3BF
T32CGP		equ	0xF3C1
GRPCOL		equ	0xF3C9
GRPCGP		equ	0xF3CB
CLIKSW		equ	0xF3DB
FORCLR		equ	0xF3E9
BAKCLR		equ	0xF3EA
BDRCLR		equ	0xF3EB
PUTPNT		equ	0xF3F8
GETPNT		equ	0xF3FA
FNKSTR		equ	0xF87F
KEYBUF		equ	0xFBF0
EXPTBL		equ	0xFCC1
SLTTBL		equ	0xFCC5
JIFFY		equ	0xFC9E
H_STKE		equ	0xFEDA		; called when BASIC starts, after the roms are set up

; ---- stm32f4 board
CMD_REG		equ	0x8000		; MENU_CTRL_COMMAND
BANK_REG	equ	0x8001		; MENU_CTRL_BANK
CTRL_COUNT	equ	0x8002
CTRL_START	equ	0x8004
CTRL_FLAGS	equ	0x8006
CTRL_COVER	equ	0x8008
CTRL_TAPE	equ	0x800A
CTRL_SNAP	equ	0x800B
BANK_REG_6000	equ	0x8002		; the bank at 0x6000, for restoring a snapshot
CTRL_TAPE_SIZE	equ	0x800C		; 32 bit
CTRL_VERSION	equ	0x8010
CTRL_PATH	equ	0x8020
CTRL_SELECTED	equ	0x8080
CTRL_TAPE_BLOCK	equ	0x8084		; 16 bit
CTRL_READY	equ	0x8060		; "RDY!" after CMD_PREPARE
CTRL_SONG_CHUNK	equ	0x8086		; 16 bit: 16K chunk of the song for CMD_SONG
CTRL_SONG_HALF	equ	0x8088		; 0: banks 3-4, 1: banks 5-6
BANK_SONG	equ	3
WINDOW		equ	0xA000
BANK_FIRST	equ	8
BANK_COVER	equ	4		; the patterns, then the colours in bank 5
COVER_PART	equ	6144
TAPE_WINDOW	equ	8		; 8K blocks of the tape in banks 8-15

CMD_LOAD_DIRECTORY equ	0x80
CMD_LOAD_ROM	equ	0x40
CMD_CHANGE_DIR	equ	0x20
CMD_LOAD_COVER	equ	0x10
CMD_TAPE_WINDOW	equ	0x08
CMD_PREPARE	equ	0x04
CMD_SONG	equ	0x02
FLAG_NO_DISK_ROM equ	0x01
FLAG_NO_FLASH_ROMS equ	0x02		; roms over 128K can not run (the board has 512K of flash)
RAM_ROM_K	equ	128		; bigger roms run from the board's flash

	IFDEF SIMTAPE
TAPE_BANK_REG	equ	0x7800		; menu-simtape.rom is an ASCII8 rom: the bank at 0xA000
	ELSE
TAPE_BANK_REG	equ	BANK_REG
	ENDIF

ENTRY_SIZE	equ	32
NAME_LENGTH	equ	28
ENTRY_SIZE_K	equ	30		; 15 bits. Bit 7 of the byte after is set if there is a cover
HAS_COVER	equ	7

; ---- screen
ROWS		equ	19		; list rows. Row 21 is left empty
LIST_ROW	equ	2
PATH_ROW	equ	22
STATUS_ROW	equ	23
NAME_COL	equ	3
NAME_LEN_SIZES	equ	21		; name length while the sizes are shown

; characters 0x80-0x9F are redefined. Each group of 8 has its own colour
CH_MUSIC	equ	0x10		; light blue. 0x10-0x1F are not used for text
CH_TAPE		equ	0x18		; light green
CH_FOLDER	equ	0x80		; dark yellow
CH_STRIPE0	equ	0x81
CH_DISK		equ	0x88		; cyan
CH_STRIPE1	equ	0x89
CH_SET		equ	0x8A
CH_ROM		equ	0x90		; magenta
CH_STRIPE2	equ	0x91
CH_UP		equ	0x98		; white
CH_STRIPE3	equ	0x99
CH_COVER	equ	0x9A
; 0xA0-0xFF are 0x20-0x7F again, black on light yellow (selected row, title)

; ---- RAM. 0xE000 up, so 8K machines are fine too
VARS		equ	0xE000
count		equ	VARS+0		; 16 bit
cursor		equ	VARS+2
top		equ	VARS+4
rowidx		equ	VARS+6
tmp		equ	VARS+8
stub_t		equ	VARS+10
showsize	equ	VARS+12
searchlen	equ	VARS+13
row		equ	VARS+14
msxver		equ	VARS+15
search		equ	VARS+16		; SEARCH_MAX characters
SEARCH_MAX	equ	14		; what fits on the bottom line
start		equ	VARS+30		; 16 bit
incover		equ	VARS+32		; 1 while the cover is on the screen
backward	equ	VARS+33
entbuf		equ	VARS+48		; one entry
; music (see song_poll), after linebuf
song_on		equ	VARS+112	; 1 while a song plays
song_entry	equ	VARS+113	; 16 bit
song_pos	equ	VARS+115	; 24 bit, in the .vgm
song_wait	equ	VARS+118	; 16 bit: samples (1/44100 s) still to wait
song_budget	equ	VARS+120	; 16 bit: samples this frame has left
song_frame	equ	VARS+122	; 16 bit: samples a frame, 882 (50 Hz) or 735
song_jiffy	equ	VARS+124	; 16 bit
song_loaded	equ	VARS+126	; the 16K chunk in each half, 0xFF none
song_pending	equ	VARS+128	; half + 1 while the board loads a chunk into it
song_pchunk	equ	VARS+129	; that chunk
song_bank	equ	VARS+130	; the bank at 0xA000 now, 0xFF not known
song_count	equ	VARS+131	; commands left this frame
song_next	equ	VARS+132	; 16 bit
song_t		equ	VARS+134	; 16 bit
VGM_HEADER	equ	FONTBUF		; 128 bytes, while a song is started
linebuf		equ	VARS+80		; one screen row
STUB		equ	0xE100		; started from RAM, since the rom goes away under it
FONTBUF		equ	0xE200		; 96*8 bytes
; while a tape is set up
tslot		equ	VARS+0		; this rom's slot
ramslot		equ	VARS+1		; the RAM the BIOS is copied to
biosslot	equ	VARS+2		; the BIOS's
; while a snapshot is put back (see snap_init)
a8_p1		equ	VARS+3		; 0xA8 for: page 0 RAM, 1 and 2 this rom, 3 RAM
a8_p1r2		equ	VARS+4		; the same with page 2 RAM
a8_x		equ	VARS+5		; page 0 this rom too, to go to the final routine
a8_f		equ	VARS+6		; the final routine's: page 1 RAM, 0 and 2 this rom
a8_end		equ	VARS+7		; the game's
snapstub	equ	VARS+8		; 9 bytes
snap_sp		equ	VARS+17		; 16 bit
snap_ffff	equ	VARS+19		; for 0xFFFF: the RAM's secondary slot in every page, or RAM
snap_msx	equ	VARS+20		; the main ROM's 0x002D: 0 for an MSX1
COPYBUF		equ	0xE200		; 256 bytes

	org	0x4000

; MSX cartridge (ROM) header
	db	"AB"
	dw	init
	dw	0, 0, 0
	ds	6, 0

title:
	db	"KCMFS 3.0."
	include	"build.inc"
	db	0

msg_reading	db	"READING THE SD CARD...", 0
msg_starting	db	"STARTING...", 0
msg_flash	db	"STARTING FROM FLASH...", 0
msg_noflash	db	"NEEDS A BOARD WITH 1MB FLASH", 0
msg_noanswer	db	"NO ANSWER FROM THE BOARD", 0
msg_nodiskrom	db	"NO DISK.ROM ON THE SD CARD", 0
msg_empty	db	"NOTHING HERE", 0
msg_hint	db	"TAB COVER SPC SIZES", 0
msg_nocover	db	"NO COVER FOR THIS ONE", 0
msg_playing	db	"ESC STOPS THE MUSIC", 0
msg_nopsg	db	"NO PSG MUSIC IN THIS ONE", 0
msg_find	db	"FIND:", 0
msg_fw		db	"  FW ", 0
msg_msx1	db	"MSX1", 0
msg_msx2	db	"MSX2", 0
msg_msx2p	db	"MSX2+", 0
msg_turbor	db	"MSXTR", 0
	IFDEF SIM
msg_sim_start	db	"START ", 0
	ENDIF

; ---------------------------------------------------------------------------------------------
init:
	IFDEF SIMTAPE
	call	our_slot
	jp	tape_init
	ENDIF
	IFNDEF SIM
	; a tape was started: no menu, but the tape routines and BASIC to load it
	call	our_slot
	push	af
	ld	hl,CTRL_TAPE
	call	RDSLT
	ld	b,a
	pop	af
	inc	b
	dec	b
	jp	nz,tape_init
	; a snapshot: put the MSX back as it was
	push	af
	ld	hl,CTRL_SNAP
	call	RDSLT
	ld	b,a
	pop	af
	inc	b
	dec	b
	jp	nz,snap_init
	ENDIF
	call	find_rom_page_2
	ld	a,(MSXVER)
	ld	(msxver),a
	xor	a
	ld	(CLIKSW),a
	; no function key strings, so F1-F5 do not type into the search
	ld	hl,FNKSTR
	ld	de,FNKSTR+1
	ld	bc,159
	ld	(hl),a
	ldir

	ld	a,11
	ld	(FORCLR),a
	ld	a,1
	ld	(BAKCLR),a
	ld	(BDRCLR),a
	call	INIT32
	call	ERAFNC
	call	CHGCLR
	call	setup_vram

	xor	a
	ld	(showsize),a
	ld	(searchlen),a
	ld	(incover),a
	ld	(song_on),a
	ld	(song_pending),a
	call	draw_title

.retry:
	ld	hl,msg_reading
	call	show_message
	ld	a,CMD_LOAD_DIRECTORY
	call	fw_command
	jr	nc,.ok
	ld	hl,msg_noanswer
	call	show_message
	call	get_key
	jr	.retry
.ok:
	call	load_list

main_loop:
	call	get_key
	call	handle_key
	jr	main_loop

; Wait for a key, playing music meanwhile. The BIOS repeats keys that are held down
get_key:
	call	song_poll
	call	CHSNS
	jr	z,get_key
	jp	CHGET

; ---------------------------------------------------------------------------------------------
; Keys
handle_key:
	cp	0x1E
	jp	z,key_up
	cp	0x1F
	jp	z,key_down
	cp	0x1D
	jp	z,key_left
	cp	0x1C
	jp	z,key_right
	cp	0x0B
	jp	z,key_home
	cp	0x0D
	jp	z,key_enter
	cp	0x1B
	jp	z,key_esc
	cp	0x08
	jp	z,key_bs
	cp	0x09			; TAB
	jp	z,key_cover
	cp	0x18			; SELECT
	jp	z,key_cover
	cp	' '
	jr	nz,.char
	ld	a,(searchlen)
	or	a
	jp	z,toggle_sizes
	ld	a,' '
	jp	key_char
.char:
	cp	0x21
	ret	c
	cp	0x7F
	ret	nc
	jp	key_char

key_up:
	call	clear_search
	ld	hl,(count)
	ld	a,h
	or	l
	ret	z
	ld	hl,(cursor)
	ld	a,h
	or	l
	jr	nz,.dec
	ld	hl,(count)		; wrap round to the end
.dec:	dec	hl
	jp	move_cursor

key_down:
	call	clear_search
	ld	hl,(count)
	ld	a,h
	or	l
	ret	z
	ld	hl,(cursor)
	inc	hl
	ld	de,(count)
	or	a
	sbc	hl,de
	add	hl,de
	jp	c,move_cursor
	ld	hl,0			; wrap round to the start
	jp	move_cursor

; A page back. From the top of the list to the end
key_left:
	call	clear_search
	ld	hl,(count)
	ld	a,h
	or	l
	ret	z
	ld	hl,(cursor)
	ld	a,h
	or	l
	jr	nz,.back
	ld	hl,(count)
	dec	hl
	jp	move_cursor
.back:	ld	de,ROWS
	or	a
	sbc	hl,de
	jp	nc,move_cursor
	ld	hl,0
	jp	move_cursor

; A page on. From the end of the list to the top
key_right:
	call	clear_search
	ld	hl,(count)
	ld	a,h
	or	l
	ret	z
	dec	hl
	ld	de,(cursor)
	or	a
	sbc	hl,de			; HL = entries after the cursor
	jr	nz,.on
	ld	hl,0
	jp	move_cursor
.on:	ld	de,ROWS
	or	a
	sbc	hl,de
	ld	hl,(count)
	dec	hl
	jp	c,move_cursor		; less than a page left: go to the last one
	ld	hl,(cursor)
	ld	de,ROWS
	add	hl,de
	jp	move_cursor

key_home:
	call	clear_search
	ld	hl,0
	jp	move_cursor

key_esc:
	ld	a,(searchlen)
	or	a
	jr	nz,.search
	ld	a,(song_on)
	or	a
	jp	nz,song_stop
	jr	go_up
.search:
	call	clear_search
	jp	draw_status

key_bs:
	ld	a,(searchlen)
	or	a
	jr	z,go_up
	dec	a
	ld	(searchlen),a
	jp	draw_status

; Up one folder: start the ".." entry, if there is one
go_up:
	ld	hl,(count)
	ld	a,h
	or	l
	ret	z
	ld	hl,0
	call	get_entry
	ld	a,(entbuf)
	cp	'U'
	ret	nz
	ld	hl,0
	jp	change_dir

toggle_sizes:
	ld	a,(showsize)
	xor	1
	ld	(showsize),a
	jp	draw_list

; A letter, digit or the like: jump to the first name starting with what has been typed so far.
; A key that matches nothing is ignored
key_char:
	call	upper
	ld	c,a
	ld	a,(searchlen)
	cp	SEARCH_MAX
	ret	nc
	ld	e,a
	ld	d,0
	ld	hl,search
	add	hl,de
	ld	(hl),c
	inc	a
	ld	b,a
	push	bc
	call	find_prefix
	pop	bc
	ret	c
	ld	a,b
	ld	(searchlen),a
	jp	move_cursor

clear_search:
	xor	a
	ld	(searchlen),a
	ret

; ENTER: open a folder or start a rom, disk or disk set
key_enter:
	ld	hl,(count)
	ld	a,h
	or	l
	ret	z
	ld	hl,(cursor)
	call	get_entry
	ld	a,(entbuf)
	cp	'U'
	jr	z,.dir
	cp	'F'
	jr	z,.dir
	cp	'R'
	jr	z,.rom
	cp	'T'
	jp	z,start_entry
	cp	'P'
	jp	z,start_entry
	cp	'M'
	jr	z,.song
	cp	'D'
	jr	z,.disk
	cp	'S'
	ret	nz
.disk:
	IFNDEF SIM
	ld	a,(CTRL_FLAGS)
	and	FLAG_NO_DISK_ROM
	jp	z,start_entry
	ld	hl,msg_nodiskrom
	jp	show_message
	ELSE
	jp	start_entry
	ENDIF
.dir:
	ld	hl,(cursor)
	jp	change_dir
.rom:	; over 128K it runs from the board's flash, if it has room for it
	ld	hl,(entbuf+ENTRY_SIZE_K)
	res	7,h
	ld	de,RAM_ROM_K+1
	or	a
	sbc	hl,de
	jp	c,start_entry
	IFNDEF SIM
	ld	a,(CTRL_FLAGS)
	and	FLAG_NO_FLASH_ROMS
	ld	hl,msg_noflash
	jp	nz,show_message
	ENDIF
	ld	hl,msg_flash
	jp	start_with
.song:	ld	hl,(cursor)
	jp	play_song

; ---------------------------------------------------------------------------------------------
; Covers

; TAB or SELECT: the cover of the entry at the cursor, full screen
key_cover:
	call	clear_search
	ld	hl,(count)
	ld	a,h
	or	l
	ret	z
	ld	hl,(cursor)
	call	load_cover
	jr	nc,cover_view
	ld	hl,msg_nocover
	jp	show_message

; The cover screen. UP/LEFT and DOWN/RIGHT go to the previous and next entry with a cover,
; RETURN starts it, any other key goes back to the list
cover_view:
	call	show_cover
.key:	call	get_key
	ld	c,1
	cp	0x1E
	jr	z,.step
	cp	0x1D
	jr	z,.step
	dec	c
	cp	0x1F
	jr	z,.step
	cp	0x1C
	jr	z,.step
	push	af
	call	list_screen
	pop	af
	cp	0x0D
	jp	z,key_enter
	ret
.step:	ld	a,c
	call	cover_step
	jr	nc,cover_view
	jr	.key

; Move the cursor to the next (A=0) or previous (A=1) entry with a cover, round the end of the
; list, and have the board load it. Carry set if there is no other
cover_step:
	ld	(backward),a
	ld	hl,(cursor)
	ld	(start),hl
.loop:	ld	a,(backward)
	or	a
	jr	nz,.back
	inc	hl
	ld	de,(count)
	or	a
	sbc	hl,de
	add	hl,de
	jr	c,.check
	ld	hl,0
	jr	.check
.back:	ld	a,h
	or	l
	jr	nz,.dec
	ld	hl,(count)
.dec:	dec	hl
.check:	ld	de,(start)
	or	a
	sbc	hl,de
	add	hl,de
	scf
	ret	z			; round to where it started
	push	hl
	call	has_cover
	pop	hl
	jr	z,.loop
	push	hl
	call	load_cover
	pop	hl
	jr	c,.loop
	ld	(cursor),hl
	ret

; NZ if entry HL has a cover
has_cover:
	call	entry_addr
	ld	de,ENTRY_SIZE_K+1
	add	hl,de
	bit	HAS_COVER,(hl)
	ret

; Have the board load the cover of entry HL into banks 4 and 5. Carry set if there is none
load_cover:
	IFDEF SIM
	call	has_cover
	scf
	ret	z
	or	a
	ret
	ELSE
	ld	(CTRL_SELECTED),hl
	ld	a,CMD_LOAD_COVER
	call	fw_command
	ld	hl,0xFFFF		; banks 4 and 5 had music in them
	ld	(song_loaded),hl
	ret	c
	ld	a,(CTRL_COVER)
	cp	1			; carry if 0
	ret
	ENDIF

; The cover the board has loaded, in SCREEN 2. The BIOS sets the screen up as BASIC does, with
; the names 0-255 in each third, so the patterns and colours are all it takes
show_cover:
	ld	a,(incover)
	or	a
	jr	nz,.copy
	call	INIGRP
	ld	a,1
	ld	(incover),a
.copy:	call	DISSCR
	ld	a,BANK_COVER
	ld	de,(GRPCGP)
	call	.part
	ld	a,BANK_COVER+1
	ld	de,(GRPCOL)
	call	.part
	jp	ENASCR
.part:
	IFDEF SIM
	ld	hl,sim_cover
	cp	BANK_COVER
	jr	z,.sim
	ld	hl,sim_cover+COVER_PART
.sim:
	ELSE
	ld	(BANK_REG),a
	ld	hl,WINDOW
	ENDIF
	ld	bc,COVER_PART
	jp	LDIRVM

; From the cover back to the list, on the entry the cursor is on now
list_screen:
	xor	a
	ld	(incover),a
	call	INIT32
	call	setup_vram
	call	draw_title
	call	draw_path
	call	calc_top
	ld	(top),hl
	jp	draw_list

; ---------------------------------------------------------------------------------------------
; Music. A .vgm in the list ('M') is played on the PSG while the menu goes on: get_key calls
; song_poll, which works through the VGM's commands for each frame (50 or 60 a second) that has
; gone by. The board puts the file into banks 3-4 and 5-6, 16K at a time (CMD_SONG): one half is
; played while the next chunk goes into the other. Only the AY8910's (the PSG's) commands are
; played, the rest is skipped. At the end of a song the next one in the list follows

; Play entry HL from the start
play_song:
	push	hl
	call	song_stop
	pop	hl
	ld	(song_entry),hl
	ld	hl,0
	ld	(song_pos),hl
	ld	(song_wait),hl
	ld	(song_budget),hl
	xor	a
	ld	(song_pos+2),a
	ld	hl,0xFFFF
	ld	(song_loaded),hl
	ld	a,0xFF
	ld	(song_bank),a
	ld	hl,VGM_HEADER
	ld	b,0x80
.head:	push	bc
	push	hl
	call	song_byte
	pop	hl
	pop	bc
	ld	(hl),a
	inc	hl
	djnz	.head
	; "Vgm ", version 1.51 or later, and an AY8910 (its clock at 0x74)
	ld	hl,VGM_HEADER
	ld	de,vgm_ident
	ld	b,4
.id:	ld	a,(de)
	cp	(hl)
	jr	nz,.nopsg
	inc	hl
	inc	de
	djnz	.id
	ld	hl,(VGM_HEADER+0x08)
	ld	de,0x151
	or	a
	sbc	hl,de
	jr	c,.nopsg
	ld	hl,(VGM_HEADER+0x74)
	ld	a,h
	or	l
	ld	hl,(VGM_HEADER+0x76)
	or	h
	or	l
	jr	z,.nopsg
	; the commands start at 0x34 + what is there (at 0x40 if that is 0)
	ld	hl,(VGM_HEADER+0x34)
	ld	a,h
	or	l
	jr	nz,.start
	ld	hl,0x40-0x34
.start:	ld	de,0x34
	add	hl,de
	ld	(song_pos),hl
	; samples a frame
	ld	hl,735
	ld	a,(ROMID)
	bit	7,a
	jr	z,.hz
	ld	hl,882
.hz:	ld	(song_frame),hl
	ld	hl,(JIFFY)
	ld	(song_jiffy),hl
	call	song_quiet
	ld	a,1
	ld	(song_on),a
	call	song_prefetch
	call	clear_search		; so ESC stops it
	jp	draw_status
.nopsg:	ld	hl,msg_nopsg
	jp	show_message

vgm_ident	db	"Vgm "

; From get_key: the frames that have gone by since the last time
song_poll:
	ld	a,(song_on)
	or	a
	ret	z
	call	song_done
	ld	hl,(JIFFY)
	ld	de,(song_jiffy)
	ld	(song_jiffy),hl
	or	a
	sbc	hl,de
	ret	z
	ld	a,h
	or	a
	jr	nz,.many
	ld	a,l
	cp	5
	jr	c,.frames
.many:	ld	a,4			; more went by (the board was busy): just go on
.frames:
	ld	b,a
	ld	a,0xFF
	ld	(song_bank),a		; the list may have used the bank register
.frame:	push	bc
	call	song_run
	pop	bc
	ld	a,(song_on)
	or	a
	ret	z
	djnz	.frame
	ret

; One frame: commands until a wait goes past its end
song_run:
	ld	hl,(song_budget)
	ld	de,(song_frame)
	add	hl,de
	ld	(song_budget),hl
	ld	a,255
	ld	(song_count),a
.loop:	ld	hl,(song_wait)
	ld	de,(song_budget)
	or	a
	sbc	hl,de
	jr	c,.due
	jr	z,.due
	ld	(song_wait),hl		; still waiting when the frame is over
	ld	hl,0
	ld	(song_budget),hl
	ret
.due:	ld	hl,(song_budget)
	ld	de,(song_wait)
	or	a
	sbc	hl,de
	ld	(song_budget),hl
	ld	hl,0
	ld	(song_wait),hl
	ld	hl,song_count
	dec	(hl)
	ret	z			; no waits in it: something is wrong
	call	song_command
	ld	a,(song_on)
	or	a
	ret	z
	jr	.loop

; One VGM command
song_command:
	call	song_byte
	cp	0xA0
	jr	z,.ay
	cp	0x61
	jr	z,.wait16
	ld	hl,735
	cp	0x62
	jr	z,.setwait
	ld	hl,882
	cp	0x63
	jr	z,.setwait
	cp	0x66
	jp	z,song_ended
	cp	0x67
	jr	z,.block
	ld	b,a
	and	0xF0
	cp	0x70
	jr	nz,.skip
	ld	a,b			; 0x7n: n+1 samples
	and	0x0F
	inc	a
	ld	l,a
	ld	h,0
.setwait:
	ld	(song_wait),hl
	ret
.wait16:
	call	song_byte
	push	af
	call	song_byte
	ld	h,a
	pop	af
	ld	l,a
	jr	.setwait
.ay:	call	song_byte		; the register (bit 7: a second PSG)
	push	af
	call	song_byte
	ld	e,a
	pop	af
	cp	14
	ret	nc			; the I/O ports, or a second PSG
	cp	7
	jp	nz,WRTPSG
	ld	a,e			; the mixer: port B out, port A in, as on every MSX
	and	0x3F
	or	0x80
	ld	e,a
	ld	a,7
	jp	WRTPSG
.block:	call	song_byte		; 0x66
	call	song_byte		; its type
	call	song_byte		; its size, 32 bits
	push	af
	call	song_byte
	push	af
	call	song_byte
	push	af
	call	song_byte
	pop	af
	ld	c,a
	pop	af
	ld	d,a
	pop	af
	ld	e,a
	ld	hl,(song_pos)
	add	hl,de
	ld	(song_pos),hl
	ld	a,(song_pos+2)
	adc	a,c
	ld	(song_pos+2),a
	ret
.skip:	; another chip's command: B is the command, C how many bytes follow it
	ld	a,b
	cp	0x30
	ret	c
	ld	c,1
	cp	0x40
	jr	c,.n
	ld	c,2
	cp	0x4F
	jr	c,.n
	ld	c,1
	cp	0x51
	jr	c,.n
	ld	c,2
	cp	0x60
	jr	c,.n
	cp	0x80
	ret	c
	cp	0x90
	jr	c,.dac
	cp	0x96
	jr	c,.stream
	ld	c,2
	cp	0xC0
	jr	c,.n
	ld	c,3
	cp	0xE0
	jr	c,.n
	ld	c,4
.n:	push	bc
	call	song_byte
	pop	bc
	dec	c
	jr	nz,.n
	ret
.dac:	and	0x0F			; 0x8n: YM2612 sample and n samples' wait
	ld	l,a
	ld	h,0
	ld	(song_wait),hl
	ret
.stream:
	sub	0x90
	ld	hl,stream_lengths
	add	a,l
	ld	l,a
	jr	nc,.len
	inc	h
.len:	ld	c,(hl)
	jr	.n

stream_lengths	db	4, 4, 5, 10, 1, 4	; 0x90-0x95

; The end of a song: the next one in the list, round the end (the same one if it is the only one)
song_ended:
	ld	bc,(count)
	ld	a,b
	or	c
	jp	z,song_stop
	ld	hl,(song_entry)
	ld	(song_next),hl
.next:	ld	hl,(song_next)
	inc	hl
	ld	de,(count)
	or	a
	sbc	hl,de
	add	hl,de
	jr	c,.in
	ld	hl,0
.in:	ld	(song_next),hl
	push	bc
	call	entry_addr
	ld	a,(hl)
	pop	bc
	cp	'M'
	jr	z,.play
	dec	bc
	ld	a,b
	or	c
	jr	nz,.next
	jp	song_stop
.play:	ld	hl,(song_next)
	jp	play_song

song_stop:
	ld	a,(song_on)
	or	a
	ret	z
	xor	a
	ld	(song_on),a
	call	song_settle
	call	song_quiet
	jp	draw_status

; All three voices off
song_quiet:
	ld	a,8
	ld	e,0
	call	WRTPSG
	ld	a,9
	call	WRTPSG
	ld	a,10
	call	WRTPSG
	ld	a,7
	ld	e,0xBF
	jp	WRTPSG

; C = the 16K chunk the song's position is in, B = the half it goes in (C & 1)
song_chunk:
	ld	hl,(song_pos+1)
	ld	a,l
	rlca
	rlca
	and	3
	ld	c,a
	ld	a,h
	add	a,a
	add	a,a
	or	c
	ld	c,a
	and	1
	ld	b,a
	ret

; A = the byte at the song's position, which moves on one
	IFDEF SIM
song_byte:
	ld	hl,(song_pos)
	ld	de,SIM_SONG_LEN
	or	a
	sbc	hl,de
	ld	a,0x66
	jr	nc,song_step
	add	hl,de
	ld	de,sim_song
	add	hl,de
	ld	a,(hl)
	jr	song_step
	ELSE
song_byte:
	call	song_chunk
	ld	hl,song_loaded
	ld	a,l
	add	a,b
	ld	l,a
	ld	a,(hl)
	cp	c
	call	nz,song_need
	ld	a,(song_pos+1)		; bank 3, 4 (half 0) or 5, 6: bit 13 of the position
	rlca
	rlca
	rlca
	and	1
	add	a,b
	add	a,b
	add	a,BANK_SONG
	ld	hl,song_bank
	cp	(hl)
	jr	z,.bank
	ld	(hl),a
	ld	(BANK_REG),a
.bank:	ld	hl,(song_pos)
	ld	a,h
	and	0x1F
	or	high WINDOW
	ld	h,a
	ld	a,(hl)
	ENDIF
; On one, and at the start of a chunk have the next one loaded. A is kept
song_step:
	push	af
	ld	hl,(song_pos)
	inc	hl
	ld	(song_pos),hl
	ld	a,h
	or	l
	jr	nz,.lo
	ld	hl,song_pos+2
	inc	(hl)
	ld	hl,0
.lo:	ld	a,h
	and	0x3F
	or	l
	call	z,song_prefetch
	pop	af
	ret

; B = half, C = chunk: have the board load it there, and wait. B and C are kept
song_need:
	push	bc
	call	song_settle
	pop	bc
	ld	hl,song_loaded
	ld	a,l
	add	a,b
	ld	l,a
	ld	a,(hl)
	cp	c
	ret	z
	push	bc
	call	song_request
	call	song_settle
	pop	bc
	ret

; The chunk after the one the position is in, into the other half, unless it is there already
song_prefetch:
	ld	a,(song_pending)
	or	a
	ret	nz
	call	song_chunk
	inc	c
	ld	a,b
	xor	1
	ld	b,a
	ld	hl,song_loaded
	add	a,l
	ld	l,a
	ld	a,(hl)
	cp	c
	ret	z
; B = half, C = chunk: have the board start loading it
song_request:
	IFNDEF SIM
	ld	hl,(song_entry)
	ld	(CTRL_SELECTED),hl
	ld	a,c
	ld	(CTRL_SONG_CHUNK),a
	xor	a
	ld	(CTRL_SONG_CHUNK+1),a
	ld	a,b
	ld	(CTRL_SONG_HALF),a
	ld	hl,song_loaded
	add	a,l
	ld	l,a
	ld	(hl),0xFF		; it is being overwritten
	ld	a,c
	ld	(song_pchunk),a
	ld	a,b
	inc	a
	ld	(song_pending),a
	ld	a,CMD_SONG
	ld	(CMD_REG),a
	ENDIF
	ret

; Wait for a chunk the board is loading (a couple of seconds at most)
song_settle:
	IFNDEF SIM
	ld	a,(song_pending)
	or	a
	ret	z
	ld	hl,(JIFFY)
	ld	(song_t),hl
.wait:	call	song_done
	ld	a,(song_pending)
	or	a
	ret	z
	ld	hl,(JIFFY)
	ld	de,(song_t)
	or	a
	sbc	hl,de
	ld	de,120
	or	a
	sbc	hl,de
	jr	c,.wait
	xor	a
	ld	(song_pending),a	; gave up
	ENDIF
	ret

; If the board has finished loading a chunk, note it
song_done:
	IFNDEF SIM
	ld	a,(song_pending)
	or	a
	ret	z
	ld	a,(CMD_REG)
	or	a
	ret	nz
	ld	a,(song_pending)
	dec	a
	ld	hl,song_loaded
	add	a,l
	ld	l,a
	ld	a,(song_pchunk)
	ld	(hl),a
	xor	a
	ld	(song_pending),a
	ENDIF
	ret

; ---------------------------------------------------------------------------------------------
; Talking to the stm32f4 board

; Send command A and wait for the board to finish. Carry set if it does not answer
fw_command:
	IFDEF SIM
	or	a
	ret
	ELSE
	push	af
	call	song_settle		; a chunk of music being loaded first
	pop	af
	ld	(CMD_REG),a
	ld	hl,(JIFFY)
	ld	(tmp),hl
.wait:
	ld	a,(CMD_REG)
	or	a
	ret	z
	ld	hl,(JIFFY)
	ld	de,(tmp)
	or	a
	sbc	hl,de
	ld	de,400			; about 8 seconds
	or	a
	sbc	hl,de
	jr	c,.wait
	scf
	ret
	ENDIF

; Open entry HL (a folder or "..")
change_dir:
	IFNDEF SIM
	ld	(CTRL_SELECTED),hl
	ENDIF
	ld	hl,msg_reading
	call	show_message
	ld	a,CMD_CHANGE_DIR
	call	fw_command
	jp	nc,load_list
	ld	hl,msg_noanswer
	jp	show_message

; Start the entry at the cursor. The rom (menu) goes away while the board loads it, so the last
; part runs from RAM
start_entry:
	ld	hl,msg_starting
start_with:				; HL: the message
	push	hl
	call	song_stop
	pop	hl
	IFDEF SIM
	call	fill_line
	ld	hl,msg_sim_start
	ld	de,linebuf+1
	ld	b,6
	call	copy_string
	ld	hl,entbuf+1
	ld	b,NAME_LENGTH-3
	call	copy_string
	ld	a,STATUS_ROW
	jp	put_line
	ELSE
	push	hl
	ld	hl,(cursor)
	ld	(CTRL_SELECTED),hl
	pop	hl
	call	show_message
	ld	hl,stub_src
	ld	de,STUB
	ld	bc,stub_end-stub_src
	ldir
	jp	STUB
	ENDIF

; Read the list the board has just made, and show it
load_list:
	IFDEF SIM
	ld	hl,SIM_COUNT
	ld	(count),hl
	ld	hl,3
	ELSE
	ld	hl,(CTRL_COUNT)
	ld	(count),hl
	ld	hl,(CTRL_START)
	ENDIF
	ld	de,(count)
	or	a
	sbc	hl,de
	add	hl,de
	jr	c,.cursor_ok
	ld	hl,0
.cursor_ok:
	ld	(cursor),hl
	call	calc_top
	ld	(top),hl
	call	clear_search
	call	draw_path
	jp	draw_list

; HL = address of entry HL (type byte, name, size). Pages its 8K bank in at 0xA000
	IFNDEF SIM
entry_addr:
	ld	a,h
	add	a,BANK_FIRST
	ld	(BANK_REG),a
	ld	h,0
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,hl
	ld	de,WINDOW
	add	hl,de
	ret
	ENDIF

; Copy entry HL to entbuf
get_entry:
	call	entry_addr
	ld	de,entbuf
	ld	bc,ENTRY_SIZE
	ldir
	ret

; First entry whose name starts with the B characters in search. HL = its number, carry set if
; there is none
find_prefix:
	ld	hl,0
.loop:
	ld	de,(count)
	or	a
	sbc	hl,de
	add	hl,de
	ccf
	ret	c			; HL >= count
	push	hl
	push	bc
	call	entry_addr
	inc	hl			; the name
	ld	de,search
.cmp:	ld	a,(hl)
	call	upper
	ld	c,a
	ld	a,(de)
	cp	c
	jr	nz,.no
	inc	hl
	inc	de
	djnz	.cmp
	pop	bc
	pop	hl
	or	a
	ret
.no:	pop	bc
	pop	hl
	inc	hl
	jr	.loop

; ---------------------------------------------------------------------------------------------
; Screen

; Move the cursor to HL and redraw what changed
move_cursor:
	ld	de,(cursor)
	ld	(tmp),de		; old cursor
	ld	(cursor),hl
	call	calc_top
	ld	de,(top)
	or	a
	sbc	hl,de
	jr	z,.same_page
	add	hl,de
	ld	(top),hl
	jp	draw_list
.same_page:
	; old row and new row
	ld	hl,(tmp)
	call	row_of
	call	nc,draw_row
	ld	hl,(cursor)
	call	row_of
	call	nc,draw_row
	jp	draw_status

; A = list row of entry HL. Carry set if it is not on the screen
row_of:
	ld	de,(top)
	or	a
	sbc	hl,de
	ret	c
	ld	a,h
	or	a
	scf
	ret	nz
	ld	a,l
	cp	ROWS
	ccf
	ret

; HL = first entry of the page the cursor is on
calc_top:
	ld	hl,(cursor)
	ld	de,0
	ld	bc,ROWS
.loop:	or	a
	sbc	hl,bc
	jr	c,.done
	ex	de,hl
	add	hl,bc
	ex	de,hl
	jr	.loop
.done:	ex	de,hl
	ret

draw_list:
	xor	a
.loop:	push	af
	call	draw_row
	pop	af
	inc	a
	cp	ROWS
	jr	nz,.loop
	jp	draw_status

; Draw list row A (0 to ROWS-1)
draw_row:
	ld	(row),a
	ld	e,a
	ld	d,0
	ld	hl,(top)
	add	hl,de
	ld	(rowidx),hl
	call	fill_line
	ld	hl,(rowidx)
	ld	de,(count)
	or	a
	sbc	hl,de
	jr	nc,.out
	ld	hl,(rowidx)
	call	get_entry
	call	entry_line
	ld	hl,(rowidx)
	ld	de,(cursor)
	or	a
	sbc	hl,de
	call	z,invert_line
.out:	ld	a,(row)
	add	a,LIST_ROW
	jp	put_line

; linebuf = the entry in entbuf: marker, name and maybe the size
entry_line:
	ld	a,(entbuf)
	ld	b,CH_UP
	cp	'U'
	jr	z,.mark
	ld	b,CH_FOLDER
	cp	'F'
	jr	z,.mark
	ld	b,CH_DISK
	cp	'D'
	jr	z,.mark
	ld	b,CH_SET
	cp	'S'
	jr	z,.mark
	ld	b,CH_ROM
	cp	'R'
	jr	z,.mark
	ld	b,CH_TAPE
	cp	'T'
	jr	z,.mark
	cp	'P'			; a snapshot of a tape
	jr	z,.mark
	ld	b,CH_MUSIC
	cp	'M'
	jr	z,.mark
	ld	b,' '
.mark:	ld	a,b
	ld	(linebuf+1),a
	ld	b,NAME_LENGTH
	ld	a,(showsize)
	or	a
	jr	z,.name
	ld	b,NAME_LEN_SIZES
.name:	ld	hl,entbuf+1
	ld	de,linebuf+NAME_COL
	call	copy_string
	ld	hl,entbuf+ENTRY_SIZE_K+1
	bit	HAS_COVER,(hl)
	jr	z,.size
	ld	a,CH_COVER
	ld	(linebuf+31),a
.size:	ld	a,(showsize)
	or	a
	ret	z
	ld	hl,(entbuf+ENTRY_SIZE_K)
	res	7,h
	ld	a,h
	or	l
	ret	z
	ld	de,linebuf+25
	call	num5
	ld	a,'K'
	ld	(linebuf+30),a
	ret

; Selected: black on light yellow from column 2 to 30. 31 is for the cover mark
invert_line:
	ld	hl,linebuf+2
	ld	b,29
.loop:	set	7,(hl)
	inc	hl
	djnz	.loop
	ret

; Top line: name and version of the menu and the firmware, and what MSX it is. Then a stripe
draw_title:
	call	fill_line
	ld	hl,title
	ld	de,linebuf+1
	ld	b,16
	call	copy_string
	ld	hl,msg_fw
	ld	b,5
	call	copy_string
	IFDEF SIM
	ld	hl,sim_version
	ELSE
	ld	hl,CTRL_VERSION
	ENDIF
	ld	b,10
	call	copy_string
	ld	a,(msxver)
	ld	hl,msg_msx1
	or	a
	jr	z,.machine
	ld	hl,msg_msx2
	dec	a
	jr	z,.machine
	ld	hl,msg_msx2p
	dec	a
	jr	z,.machine
	ld	hl,msg_turbor
.machine:
	; right aligned, ending at column 30
	push	hl
	ld	b,0
.len:	ld	a,(hl)
	or	a
	jr	z,.got
	inc	hl
	inc	b
	jr	.len
.got:	ld	a,31
	sub	b
	ld	e,a
	ld	d,0
	ld	hl,linebuf
	add	hl,de
	ex	de,hl
	pop	hl
	call	copy_string
	ld	hl,linebuf
	ld	b,32
.inv:	set	7,(hl)
	inc	hl
	djnz	.inv
	xor	a
	call	put_line
	; stripe in the four marker colours
	ld	hl,linebuf
	ld	a,CH_STRIPE0
	call	.eight
	ld	a,CH_STRIPE1
	call	.eight
	ld	a,CH_STRIPE2
	call	.eight
	ld	a,CH_STRIPE3
	call	.eight
	ld	a,1
	jp	put_line
.eight:	ld	b,8
.e:	ld	(hl),a
	inc	hl
	djnz	.e
	ret

; The folder below msx/ the list is from
draw_path:
	call	fill_line
	IFDEF SIM
	ld	hl,sim_path
	ELSE
	ld	hl,CTRL_PATH
	ENDIF
	ld	a,(hl)
	or	a
	jr	nz,.path
	ld	a,'/'
	ld	(linebuf+1),a
	jr	.show
.path:	ld	de,linebuf+1
	ld	b,31
	call	copy_string
.show:	ld	a,PATH_ROW
	jp	put_line

; Bottom line: where the cursor is, and what has been typed or the keys
draw_status:
	call	fill_line
	ld	hl,(count)
	ld	a,h
	or	l
	jr	nz,.pos
	ld	hl,msg_empty
	ld	de,linebuf+1
	ld	b,30
	call	copy_string
	jr	.show
.pos:	ld	hl,(cursor)
	inc	hl
	ld	de,linebuf+1
	call	num5
	ld	a,'/'
	ld	(de),a
	inc	de
	push	de
	ld	hl,(count)
	ld	de,linebuf+20		; scratch, past where it goes
	call	num5
	pop	de
	ld	hl,linebuf+20
	ld	b,5
.cnt:	ld	a,(hl)			; without the leading spaces
	ld	(hl),' '
	inc	hl
	cp	' '
	jr	z,.skip
	ld	(de),a
	inc	de
.skip:	djnz	.cnt
	ld	a,(searchlen)
	or	a
	jr	nz,.find
	ld	hl,msg_hint
	ld	a,(song_on)
	or	a
	jr	z,.hint
	ld	hl,msg_playing
.hint:	ld	de,linebuf+13
	ld	b,19
	call	copy_string
	jr	.show
.find:	ld	hl,msg_find
	ld	de,linebuf+13
	ld	b,5
	call	copy_string
	ld	hl,search
	ld	a,(searchlen)
	ld	c,a
	ld	b,0
	ldir
.show:	ld	a,STATUS_ROW
	jp	put_line

; Message HL on the bottom line
show_message:
	push	hl
	call	fill_line
	pop	hl
	ld	de,linebuf+1
	ld	b,30
	call	copy_string
	ld	a,STATUS_ROW
	jp	put_line

fill_line:
	ld	hl,linebuf
	ld	de,linebuf+1
	ld	bc,31
	ld	(hl),' '
	ldir
	ret

; linebuf to screen row A
put_line:
	ld	l,a
	ld	h,0
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,hl
	ld	de,(T32NAM)
	add	hl,de
	ex	de,hl
	ld	hl,linebuf
	ld	bc,32
	jp	LDIRVM

; Copy the 0 terminated string HL to DE, at most B characters. Anything that is not plain ASCII
; (eg. Japanese file names) shows as '?'. DE is left after the last one
copy_string:
	ld	a,(hl)
	or	a
	ret	z
	call	printable
	ld	(de),a
	inc	hl
	inc	de
	djnz	copy_string
	ret

printable:
	cp	0x20
	jr	c,.q
	cp	0x7F
	ret	c
.q:	ld	a,'?'
	ret

upper:
	cp	'a'
	ret	c
	cp	'z'+1
	ret	nc
	sub	0x20
	ret

; HL as 5 characters at DE, right aligned. DE is left after them
num5:
	push	de
	ld	bc,-10000
	call	.digit
	ld	bc,-1000
	call	.digit
	ld	bc,-100
	call	.digit
	ld	bc,-10
	call	.digit
	ld	a,l
	add	a,'0'
	ld	(de),a
	inc	de
	pop	hl
	; leading zeros to spaces
	ld	b,4
.zero:	ld	a,(hl)
	cp	'0'
	ret	nz
	ld	(hl),' '
	inc	hl
	djnz	.zero
	ret
.digit:	ld	a,'0'-1
.d:	inc	a
	add	hl,bc
	jr	c,.d
	sbc	hl,bc
	ld	(de),a
	inc	de
	ret

; Colours, a light yellow on black list, the selected row and title inverted, and the markers
setup_vram:
	ld	hl,colours
	ld	de,(T32COL)
	ld	bc,32
	call	LDIRVM
	; 0xA0-0xFF: the font of 0x20-0x7F again (the colours make it inverted)
	ld	hl,(T32CGP)
	ld	de,0x20*8
	add	hl,de
	ld	de,FONTBUF
	ld	bc,96*8
	call	LDIRMV
	ld	hl,(T32CGP)
	ld	de,0xA0*8
	add	hl,de
	ex	de,hl
	ld	hl,FONTBUF
	ld	bc,96*8
	call	LDIRVM
	ld	hl,patterns
.loop:	ld	a,(hl)
	or	a
	ret	z
	inc	hl
	push	hl
	ld	l,a
	ld	h,0
	add	hl,hl
	add	hl,hl
	add	hl,hl
	ld	de,(T32CGP)
	add	hl,de
	ex	de,hl
	pop	hl
	push	hl
	ld	bc,8
	call	LDIRVM
	pop	hl
	ld	de,8
	add	hl,de
	jr	.loop

colours:
	ds	2, 0xB1			; 0x00-0x7F light yellow on black
	db	0x51			; but 0x10 light blue: music
	db	0x31			; and 0x18 light green: tapes
	ds	12, 0xB1
	db	0xA1			; 0x80 dark yellow: folders
	db	0x71			; 0x88 cyan: disks
	db	0xD1			; 0x90 magenta: roms
	db	0xF1			; 0x98 white: ".."
	ds	12, 0x1B		; 0xA0-0xFF black on light yellow

patterns:
	db	CH_FOLDER, 0x00,0x70,0xFE,0xFE,0xFE,0xFE,0xFE,0x00
	db	CH_DISK,   0x00,0xFE,0xC6,0xFE,0xFE,0xC6,0xFE,0x00
	db	CH_SET,    0x7E,0x42,0xFE,0xC6,0xFE,0xC6,0xFE,0x00
	db	CH_ROM,    0x00,0x7C,0x7C,0x7C,0x7C,0x54,0x54,0x00
	db	CH_UP,     0x10,0x38,0x7C,0xFE,0x38,0x38,0x38,0x00
	db	CH_COVER,  0x00,0xFE,0x82,0x8A,0xA2,0xD6,0xFE,0x00	; a picture
	db	CH_TAPE,   0x00,0xFE,0x82,0xAA,0x82,0xBA,0xFE,0x00	; a cassette
	db	CH_MUSIC,  0x00,0x3E,0x22,0x22,0x22,0x66,0xEE,0xC4	; two notes
	db	CH_STRIPE0,0x00,0x00,0x00,0xFF,0xFF,0x00,0x00,0x00
	db	CH_STRIPE1,0x00,0x00,0x00,0xFF,0xFF,0x00,0x00,0x00
	db	CH_STRIPE2,0x00,0x00,0x00,0xFF,0xFF,0x00,0x00,0x00
	db	CH_STRIPE3,0x00,0x00,0x00,0xFF,0xFF,0x00,0x00,0x00
	db	0

;------------------------------------------------
; find_rom_page_2
; original name     : LOCALIZAR_SEGUNDA_PAGINA
; Original author   : Eduardo Robsy Petrus
; Snippet taken from: http://karoshi.auic.es/index.php?topic=117.msg1465
;
; Finds and enables page 2 (0x8000) of the slot this rom is in.
; Works when loaded into RAM and with expanded slots
;------------------------------------------------
find_rom_page_2:
	ld	hl,0x4000
	ld	b,(hl)
	xor	a
	ld	(hl),a
	ld	a,(hl)
	or	a
	jr	nz,.rom
	; running from RAM - nothing to do
	ld	(hl),b
	ret
.rom:
	di
	call	our_slot
	ld	h,0x80
	call	ENASLT
	ei
	ret

; A = the slot of this rom (page 1), as ENASLT and RDSLT take it
our_slot:
	; primary slot
	call	RSLREG
	rrca
	rrca
	and	0x03
	; secondary slot
	ld	c,a
	ld	hl,EXPTBL
	add	a,l
	ld	l,a
	ld	a,(hl)
	and	0x80
	or	c
	ld	c,a
	inc	l
	inc	l
	inc	l
	inc	l
	ld	a,(hl)
	; slot id
	and	0x0c
	or	c
	ret

; ---------------------------------------------------------------------------------------------
; Tapes. After a .cas has been started the board presents this rom again with CTRL_TAPE set.
; Instead of the menu, init copies the BIOS to the RAM in page 0. There the BIOS's own TAPION
; and TAPIN start with a stub that calls tape_tapion and tape_tapin in this rom, so anything that
; loads through the BIOS (CLOAD, BLOAD"CAS:", RUN"CAS:", loaders that load more) reads the .cas.
; When BASIC starts, tape_autostart (from H.STKE) types the command that loads the tape, which
; first switches the copy in with USR(0) (usr_code). The tape is read through banks 8-15 at
; 0xA000, which the board fills with 64K of it at a time (CMD_TAPE_WINDOW).
;
; The tape variables, slotfix and the EXTROM stub follow the TAPION stub, in what was the BIOS's
; TAPION.

TAPE_STUB	equ	13		; push ix, push iy, rst 30h + slot + address, pop iy, pop ix, ret
TV_POS		equ	0		; 24 bit
TV_SIZE		equ	3		; 24 bit
TV_SLOT		equ	6		; this rom's slot
TV_BANK		equ	7		; bank at 0xA000 now
TV_WIN		equ	8		; 16 bit: first 8K block of the tape in banks 8-15
TV_IX		equ	10		; 16 bit: IX for EXTROM (MSX2)
TV_ROMP		equ	12		; the main ROM's primary slot
TV_LEN		equ	13

; A = this rom's slot
tape_init:
	ld	(tslot),a
	ld	a,i			; P/V: interrupts were on
	push	af
	di
	call	page3_slot		; the RAM, in all likelihood in page 0 too
	ld	(ramslot),a
	ld	a,(EXPTBL)		; the BIOS's slot
	ld	(biosslot),a
	call	copy_bios
	jp	c,.noram
	ld	a,(ramslot)
	call	page0_to
	call	check_bios
	jr	nc,.patch
	call	page0_bios		; an odd BIOS: leave it be
	jp	.noram
.patch:
	ld	de,(TAPION+1)
	ld	hl,tape_tapion
	call	put_stub
	ld	de,(TAPIN+1)
	ld	hl,tape_tapin
	call	put_stub
	call	patch_slots
	call	patch_ext
	call	tape_vars
	ld	a,(biosslot)
	and	3
	ld	(ix+TV_ROMP),a
	xor	a
	ld	(ix+TV_POS),a
	ld	(ix+TV_POS+1),a
	ld	(ix+TV_POS+2),a
	ld	(ix+TV_BANK),0xFF
	ld	(ix+TV_WIN),0xFF
	ld	(ix+TV_WIN+1),0xFF
	ld	a,(tslot)
	ld	(ix+TV_SLOT),a
	IFDEF SIMTAPE
	ld	hl,(sim_tape_size)
	ld	(ix+TV_SIZE),l
	ld	(ix+TV_SIZE+1),h
	ld	a,(sim_tape_size+2)
	ld	(ix+TV_SIZE+2),a
	; page 2 of this rom is bank 0 too, with another "AB" in it
	ld	a,2
	ld	(0x7000),a
	ELSE
	ld	hl,CTRL_TAPE_SIZE
	call	.size
	ld	(ix+TV_SIZE),a
	call	.size
	ld	(ix+TV_SIZE+1),a
	call	.size
	ld	(ix+TV_SIZE+2),a
	ENDIF
	; what loads the first file, while the copy is in
	call	tape_kind
	ld	(USR_CMD),hl
	; The BIOS puts page 0 back when init returns, and a disk ROM can do it again later, so the
	; copy is switched in by the command typed, through usr_code
	call	page0_bios
	ld	hl,usr_code
	ld	de,USR_AT
	ld	bc,USR_LEN
	ldir
	ld	a,(ramslot)
	ld	(USR_AT+USR_RAM),a
	ld	hl,tape_autostart
	jr	.hook
.noram:	ld	hl,tape_noram
.hook:	; BASIC calls H.STKE when it starts: rst 30h to HL here
	ld	a,0xF7
	ld	(H_STKE),a
	ld	a,(tslot)
	ld	(H_STKE+1),a
	ld	(H_STKE+2),hl
	ld	a,0xC9
	ld	(H_STKE+4),a
	pop	af
	ret	po
	ei
	ret
	IFNDEF SIMTAPE
.size:	ld	a,(tslot)
	push	hl
	call	RDSLT
	pop	hl
	inc	hl
	ret
	ENDIF

; A = the slot of page 3 (RAM), as ENASLT takes it
page3_slot:
	in	a,(0xA8)
	rlca
	rlca
	and	3
	ld	c,a
	ld	hl,EXPTBL
	add	a,l
	ld	l,a
	bit	7,(hl)
	ld	a,c
	ret	z
	ld	a,l
	add	a,SLTTBL-EXPTBL
	ld	l,a
	ld	a,(hl)
	rlca
	rlca
	and	3
	add	a,a
	add	a,a
	or	c
	or	0x80
	ret

; Page 0 to slot A, which is not expanded or is in the primary slot of page 3. Interrupts off,
; and nothing in page 0 may be called while it is not a BIOS
page0_to:
	ld	c,a
	bit	7,a
	jr	z,.prim
	and	0x0C
	rrca
	rrca
	ld	b,a
	ld	a,c
	and	3
	ld	hl,SLTTBL
	add	a,l
	ld	l,a
	ld	a,(hl)
	and	0xFC
	or	b
	ld	(hl),a
	ld	(0xFFFF),a		; the secondary slot register of page 3's slot
.prim:	in	a,(0xA8)
	and	0xFC
	ld	b,a
	ld	a,c
	and	3
	or	b
	out	(0xA8),a
	ret

; Page 0 back to the BIOS. Its secondary slot is only set if it is in the same primary slot as
; the RAM (otherwise it was never changed)
page0_bios:
	ld	a,(biosslot)
	ld	c,a
	ld	a,(ramslot)
	xor	c
	and	3
	ld	a,c
	jr	z,page0_to
	and	3
	jr	page0_to

; Copy the BIOS to page 0 of ramslot, 256 bytes at a time through COPYBUF. Carry set if there is
; no RAM there. Page 0 is the BIOS again at the end
copy_bios:
	ld	a,(ramslot)
	call	page0_to
	ld	hl,0x0100
	ld	(hl),0x55
	ld	a,(hl)
	cp	0x55
	jr	nz,.none
	ld	(hl),0xAA
	ld	a,(hl)
	cp	0xAA
	jr	nz,.none
	call	page0_bios
	ld	hl,0
.loop:	push	hl
	ld	de,COPYBUF
	ld	bc,256
	ldir
	ld	a,(ramslot)
	call	page0_to
	pop	de
	push	de
	ld	hl,COPYBUF
	ld	bc,256
	ldir
	call	page0_bios
	pop	hl
	inc	h
	ld	a,h
	cp	0x40
	jr	c,.loop
	or	a
	ret
.none:	call	page0_bios
	scf
	ret

; NC if TAPION and TAPIN are JPs, and there is room for the stubs and the variables
check_bios:
	ld	a,(TAPION)
	cp	0xC3
	jr	nz,.bad
	ld	a,(TAPIN)
	cp	0xC3
	jr	nz,.bad
	ld	hl,(TAPIN+1)
	ld	de,(TAPION+1)
	or	a
	sbc	hl,de
	jr	c,.before
	ld	de,TAPE_STUB+TV_LEN+SLOTFIX_LEN+EXT_STUB	; TAPIN after TAPION: room for it all
	sbc	hl,de
	ret
.before:
	ld	hl,(TAPION+1)		; TAPIN first: room for its stub
	ld	de,(TAPIN+1)
	or	a
	sbc	hl,de
	ld	de,TAPE_STUB
	sbc	hl,de
	ret
.bad:	scf
	ret

; Write a stub at DE that calls HL in this rom
put_stub:
	push	hl
	ld	hl,stub_head
	ld	bc,5
	ldir
	ld	a,(tslot)
	ld	(de),a
	inc	de
	pop	hl
	ex	de,hl
	ld	(hl),e
	inc	hl
	ld	(hl),d
	inc	hl
	ex	de,hl
	ld	hl,stub_tail
	ld	bc,5
	ldir
	ret

stub_head	db	0xDD,0xE5,0xFD,0xE5,0xF7	; push ix, push iy, rst 30h (CALLF)
stub_tail	db	0xFD,0xE1,0xDD,0xE1,0xC9	; pop iy, pop ix, ret

; The BIOS sets a secondary slot with this routine (RDSLT, WRSLT, CALSLT, ENASLT, EXTROM). It runs
; in page 0: OUT to 0xA8 with page 3 in the slot's primary slot, write 0xFFFF, OUT the old 0xA8
; (B) back. With the copy in page 0, from RAM in an expanded slot that also has the SUB-ROM
; (3-2 and 3-0 on an NMS 8250), setting page 0's secondary slot pulls the code from under it.
; slotfix (put after the tape variables) is called in place of its IN A,(0xA8) / LD B,A. For
; page 0 (E = 3) of another slot in the primary slot page 0 is in now, page 0 goes to the main
; ROM in the first OUT and stays there: the code is the same in the ROM, so it runs on. That
; leaves the main ROM in page 0 (the tape is lost, but nothing crashes). The SUB-ROM is called
; through EXTROM, which goes round this (ext_wrapper), so this is for anything else
slot_routine	db	0xF5,0x7A,0xE6,0xC0,0x4F,0xF1,0xF5,0x57,0xDB,0xA8,0x47
SLOT_IN		equ	8		; the IN A,(0xA8) / LD B,A in it

slotfix:
	in	a,(0xA8)
	ld	b,a
	ld	a,e
	cp	3
	jr	nz,.done		; not page 0
	ld	a,b
	xor	d			; D is the slot
	and	3
	jr	nz,.done		; page 0 is in another primary slot
	ld	a,b
	and	0xFC
	db	0xF6			; or the main ROM's primary slot
.rom:	db	0
	ld	b,a
.done:	ld	a,b
	ret
SLOTFIX_LEN	equ	$-slotfix
SLOTFIX_ROM	equ	slotfix.rom-slotfix

; MSX2: EXTROM in the copy jumps to a stub (after slotfix) that keeps IX in TV_IX and calls
; ext_wrapper here. It puts the main ROM in page 0, calls its EXTROM, which sets page 0 to the
; SUB-ROM and back the usual way, and then puts the copy back. Every register is passed on both
; ways; IX is the address in the SUB-ROM
EXTROM		equ	0x015F
EXT_STUB	equ	4+TAPE_STUB		; ld (TV_IX),ix and a stub as put_stub makes

ext_wrapper:
	exx				; the caller's BC, DE, HL
	ex	af,af'			; and AF
	call	tape_vars
	ld	l,(ix+TV_IX)
	ld	h,(ix+TV_IX+1)
	push	hl
	in	a,(0xA8)
	ld	h,a			; with the copy in page 0, for afterwards
	and	0xFC
	or	(ix+TV_ROMP)
	pop	ix
	out	(0xA8),a		; page 0: the main ROM. The same code, but for the tape
	push	hl
	ex	af,af'
	exx
	call	EXTROM
	ex	(sp),hl			; H: 0xA8 with the copy, and HL kept
	push	af
	ld	a,h
	out	(0xA8),a		; page 0: the copy again
	pop	af
	pop	hl
	ret

; Have EXTROM in the copy call ext_wrapper, on an MSX2 or later
patch_ext:
	ld	a,(MSXVER)
	or	a
	ret	z
	ld	a,(EXTROM)
	cp	0xC3			; JP
	ret	nz
	call	tape_vars
	push	ix
	pop	hl
	ld	de,TV_LEN+SLOTFIX_LEN
	add	hl,de
	ld	(EXTROM+1),hl
	ex	de,hl			; DE: the stub
	ld	a,0xDD			; ld (TV_IX),ix
	ld	(de),a
	inc	de
	ld	a,0x22
	ld	(de),a
	inc	de
	push	ix
	pop	hl
	ld	bc,TV_IX
	add	hl,bc
	ex	de,hl
	ld	(hl),e
	inc	hl
	ld	(hl),d
	inc	hl
	ex	de,hl
	ld	hl,ext_wrapper
	jp	put_stub

; Find the routine in the copy and have it call slotfix. Nothing to do if it is not there
patch_slots:
	ld	hl,0
.find:	push	hl
	ld	de,slot_routine
	ld	b,SLOT_IN+3
.cmp:	ld	a,(de)
	cp	(hl)
	jr	nz,.no
	inc	hl
	inc	de
	djnz	.cmp
	pop	hl
	; slotfix after the stub and the variables
	call	tape_vars
	push	ix
	pop	de
	ld	a,e
	add	a,TV_LEN
	ld	e,a
	jr	nc,.put
	inc	d
.put:	push	hl
	push	de
	ld	hl,slotfix
	ld	bc,SLOTFIX_LEN
	ldir
	pop	de
	ld	hl,SLOTFIX_ROM
	add	hl,de
	ld	a,(biosslot)
	and	3
	ld	(hl),a
	pop	hl
	ld	bc,SLOT_IN
	add	hl,bc
	ld	(hl),0xCD		; call slotfix
	inc	hl
	ld	(hl),e
	inc	hl
	ld	(hl),d
	ret
.no:	pop	hl
	inc	hl
	ld	a,h
	cp	0x40
	jr	c,.find
	ret

; Copied to USR_AT for the typed command to call with USR(0) just before it loads: switch the
; BIOS copy in for good. From BASIC, not through an inter-slot call, so it stays. Not with ENASLT,
; which runs in page 0 and (on an MSX2 with its RAM in slot 3-2) switches page 0 to the slot before
; it sets the secondary slot. As page0_to: the RAM is in page 3's primary slot, so its secondary
; slot register is at 0xFFFF. USR_AT is in BASIC's program area, which is empty until then. Not
; below HIMEM: a disk ROM keeps its own things at 0xF1C9-0xF37F, and some games want all of it
USR_AT		equ	0x9000
USR_CMD		equ	USR_AT+48		; what tape_autostart is to type
usr_code:
	di
	db	0x3E			; ld a,the RAM's slot
.ram:	db	0
	ld	c,a
	bit	7,a
	jr	z,.prim
	and	0x0C
	rrca
	rrca
	ld	b,a
	ld	a,c
	and	3
	ld	hl,SLTTBL
	add	a,l
	ld	l,a
	ld	a,(hl)
	and	0xFC
	or	b
	ld	(hl),a
	ld	(0xFFFF),a
.prim:	in	a,(0xA8)
	and	0xFC
	ld	b,a
	ld	a,c
	and	3
	or	b
	out	(0xA8),a
	ei
	ret
USR_LEN		equ	$-usr_code
USR_RAM		equ	usr_code.ram-usr_code
	ASSERT	USR_LEN <= 48

; HL = the command that loads the first file on the tape, which is rewound. After its header
; come ten bytes of 0xD0 (machine code), 0xD3 (tokenised BASIC) or 0xEA (BASIC as text)
tape_kind:
	call	tape_tapion
	ld	a,0
	call	nc,tape_get
	ld	(ix+TV_POS),0
	ld	(ix+TV_POS+1),0
	ld	(ix+TV_POS+2),0
	ld	hl,cmd_bload
	cp	0xD0
	ret	z
	ld	hl,cmd_cload
	cp	0xD3
	ret	z
	ld	hl,cmd_run
	ret

; From H.STKE, once: type the command. Every register is kept, BASIC has its return address in
; BC and its new stack in HL there
tape_autostart:
	push	af
	push	bc
	push	de
	push	hl
	call	unhook
	ld	hl,(USR_CMD)
	jr	tape_type

; From H.STKE when the tape could not be set up
tape_noram:
	push	af
	push	bc
	push	de
	push	hl
	call	unhook
	ld	hl,cmd_noram
tape_type:
	call	type_keys
	pop	hl
	pop	de
	pop	bc
	pop	af
	ret

unhook:
	ld	hl,H_STKE
	ld	b,5
.r:	ld	(hl),0xC9
	inc	hl
	djnz	.r
	ret

; Put the 0 terminated HL in the keyboard buffer
type_keys:
	ld	de,KEYBUF
	ld	(GETPNT),de
.c:	ld	a,(hl)
	or	a
	jr	z,.end
	ld	(de),a
	inc	hl
	inc	de
	jr	.c
.end:	ld	(PUTPNT),de
	ret

; At most 39 characters, the keyboard buffer's size. USR(0) switches the BIOS copy in
	ASSERT	USR_AT == 0x9000
cmd_run		db	"DEFUSR=&H9000:A=USR(0):RUN\"CAS:\"", 13, 0
cmd_bload	db	"DEFUSR=&H9000:A=USR(0):BLOAD\"CAS:\",R", 13, 0
cmd_cload	db	"DEFUSR=&H9000:A=USR(0):CLOAD", 13, "RUN", 13, 0
cmd_noram	db	"PRINT\"NO 64K RAM FOR TAPES\"", 13, 0

; TAPION, from the stub: the next block header from the tape position on. The position is left
; just after it. Carry set if there is none
tape_tapion:
	call	tape_vars
.find:	ld	b,8
	call	tape_left
	ret	c
	ld	l,(ix+TV_POS)
	ld	h,(ix+TV_POS+1)
	ld	c,(ix+TV_POS+2)
	push	hl
	push	bc
	ld	hl,cas_header
	ld	b,8
.cmp:	push	bc
	push	hl
	call	tape_get
	pop	hl
	pop	bc
	jr	c,.fail
	cp	(hl)
	jr	nz,.no
	inc	hl
	djnz	.cmp
	pop	bc
	pop	hl
	or	a
	ret
.no:	; try again from the next byte
	pop	bc
	pop	hl
	inc	hl
	ld	a,h
	or	l
	jr	nz,.at
	inc	c
.at:	ld	(ix+TV_POS),l
	ld	(ix+TV_POS+1),h
	ld	(ix+TV_POS+2),c
	jr	.find
.fail:	pop	bc
	pop	hl
	scf
	ret

cas_header	db	0x1F,0xA6,0xDE,0xBA,0xCC,0x13,0x7D,0x74

; TAPIN, from the stub: A = the next byte on the tape. Carry set at the end of it
tape_tapin:
	call	tape_vars
	ld	b,1
	call	tape_left
	ret	c
	jp	tape_get

; IX = the tape variables, after the stub in what was the BIOS's TAPION
tape_vars:
	ld	ix,(TAPION+1)
	ld	de,TAPE_STUB
	add	ix,de
	ret

; Carry set if fewer than B bytes are left on the tape
tape_left:
	ld	a,(ix+TV_SIZE)
	sub	(ix+TV_POS)
	ld	l,a
	ld	a,(ix+TV_SIZE+1)
	sbc	a,(ix+TV_POS+1)
	ld	h,a
	ld	a,(ix+TV_SIZE+2)
	sbc	a,(ix+TV_POS+2)
	ret	c
	or	h
	ret	nz
	ld	a,l
	cp	b
	ret

; A = the byte at the tape position, which moves on one. Carry set if the board did not answer
tape_get:
	; HL = the 8K block it is in
	ld	l,(ix+TV_POS+1)
	ld	h,(ix+TV_POS+2)
	ld	b,5
.shift:	srl	h
	rr	l
	djnz	.shift
	IFDEF SIMTAPE
	ld	a,l			; all of the tape is in the rom
	ELSE
	ld	e,(ix+TV_WIN)
	ld	d,(ix+TV_WIN+1)
	or	a
	sbc	hl,de
	jr	c,.move
	ld	a,h
	or	a
	jr	nz,.move
	ld	a,l
	cp	TAPE_WINDOW
	jr	c,.bank
.move:	add	hl,de
	call	tape_window
	ret	c
	xor	a
.bank:
	ENDIF
	add	a,BANK_FIRST
	cp	(ix+TV_BANK)
	call	nz,tape_bank
	ld	a,(ix+TV_POS+1)
	and	0x1F
	or	high WINDOW
	ld	h,a
	ld	l,(ix+TV_POS)
	ld	a,(ix+TV_SLOT)
	call	RDSLT
	inc	(ix+TV_POS)
	jr	nz,.done
	inc	(ix+TV_POS+1)
	jr	nz,.done
	inc	(ix+TV_POS+2)
.done:	or	a
	ret

; Show bank A at 0xA000
tape_bank:
	ld	(ix+TV_BANK),a
	ld	e,a
	ld	hl,TAPE_BANK_REG
	jr	tape_write

	IFNDEF SIMTAPE
; Have the board put 64K of the tape from 8K block HL on in banks 8-15. Carry set if it does not
; answer. Interrupts are off, so the wait is counted
tape_window:
	ld	(ix+TV_WIN),l
	ld	(ix+TV_WIN+1),h
	ld	e,l
	ld	hl,CTRL_TAPE_BLOCK
	call	tape_write
	ld	e,(ix+TV_WIN+1)
	ld	hl,CTRL_TAPE_BLOCK+1
	call	tape_write
	ld	e,CMD_TAPE_WINDOW
	ld	hl,CMD_REG
	call	tape_write
	ld	bc,0
.wait:	push	bc
	ld	hl,CMD_REG
	ld	a,(ix+TV_SLOT)
	call	RDSLT
	pop	bc
	or	a
	ret	z
	dec	bc
	ld	a,b
	or	c
	jr	nz,.wait
	scf
	ret
	ENDIF

; Write E to HL in this rom's slot
tape_write:
	ld	a,(ix+TV_SLOT)
	jp	WRSLT

; ---------------------------------------------------------------------------------------------
; Snapshots. After a .msxsnap has been started the board presents this rom again with CTRL_SNAP
; set, the snapshot's 64K of RAM in banks 8-15, its VRAM in banks 3-4 and its registers in bank 5
; (the layout is in ../tools/cas_snapshot.py). init comes here instead of the menu and puts it
; all back. With interrupts off, from page 1:
;   VRAM, VDP and PSG registers, port C of the PPI
;   RAM page 0 from the window at 0xA000 (page 2 this rom)
;   RAM page 2 from 0x6000 (BANK_REG_6000), page 2 switched to RAM and back
;   the final routine into the control block, with the registers in it
;   RAM page 3 (this rom's stack and variables go), with some of the MSX's own (CB_KEEP)
; then on in the final routine, which runs in page 0: the board shows the control block there
; too, and at 0x2000 the bank of 0xA000. It puts page 1 back, then the registers, switches pages
; 1-3 to the game's slots and jumps to a stub of 9 bytes just below the game's stack: OUT (0xA8)
; for the game's slots, POP AF, EI if interrupts were on, RET to the game's PC.
;
; The game's RAM goes in the RAM of page 3's slot, and its BIOS pages in the main ROM's. A stack
; in page 0 can not be done (the final routine is there).

SNAP_VRAM	equ	3		; banks 3-4
SNAP_STATE	equ	5
SNAP_RAM	equ	8		; banks 8-15: 0x0000-0xFFFF
ST_PAGES	equ	9		; in the state: 0 RAM, 1 BIOS, for pages 0-3
ST_PSG		equ	13
ST_VDP		equ	29
ST_PPIC		equ	37
ST_AF		equ	38
ST_BC		equ	40
ST_DE		equ	42
ST_HL		equ	44
ST_IX		equ	46
ST_IY		equ	48
ST_SP		equ	50
ST_PC		equ	52
ST_AF2		equ	54
ST_BC2		equ	56
ST_DE2		equ	58
ST_HL2		equ	60
ST_I		equ	62
ST_R		equ	63
ST_IM		equ	64
ST_IFF		equ	65
CB_AF2		equ	0x8064		; in the control block: AF' for the final routine
CB_STUB		equ	0x8068		; 9 bytes: the stub
CB_FINAL	equ	0x8090		; the final routine (run at 0x0090)
; The MSX's own system variables that go back over the game's: its slot tables (EXPTBL and SLTTBL)
; and on an MSX2 its MSX2 variables (DPPAGE to LOGOPR and RG8SAV to 0xFFFE), which an MSX1's
; snapshot has no say in. Kept in the control block where the path is shown. And RAMAD0-3 (the RAM's
; slot in each page), if the game's loader set them to the VG-8020's (cas_snapshot.py takes the
; snapshots on one), get this MSX's
CB_KEEP		equ	0x8020
KEEP_2A		equ	0xFAF5
KEEP_2A_LEN	equ	14
KEEP_2B		equ	0xFFE7
KEEP_2B_LEN	equ	24
CB_KEEP_BITS	equ	CB_KEEP+8+KEEP_2A_LEN+KEEP_2B_LEN	; what goes back: bit 0 KEEP_2A, bit 1 KEEP_2B, bit 2 RAMAD0-3
CB_RAMAD	equ	CB_KEEP_BITS+1				; for RAMAD0-3
	ASSERT	CB_RAMAD < 0x8060
RAMAD0		equ	0xF341
SNAP_RAMSLOT	equ	3		; the VG-8020's RAM

; A = this rom's slot
snap_init:
	ld	(tslot),a
	di
	call	page3_slot
	ld	(ramslot),a
	ld	a,(EXPTBL)
	ld	(biosslot),a
	ld	a,(0x002D)		; the main ROM is in page 0 still
	ld	(snap_msx),a
	; RAM in an expanded slot: its secondary slot in every page
	ld	a,(ramslot)
	bit	7,a
	jr	z,.mapper
	rrca
	rrca
	and	3
	ld	b,a
	add	a,a
	add	a,a
	or	b
	ld	b,a
	add	a,a
	add	a,a
	add	a,a
	add	a,a
	or	b
	ld	(0xFFFF),a
	ld	(snap_ffff),a
.mapper:
	; a memory mapper (MSX2) as the BIOS leaves it: segment 3-p in page p
	ld	a,3
	out	(0xFC),a
	dec	a
	out	(0xFD),a
	dec	a
	out	(0xFE),a
	dec	a
	out	(0xFF),a
	; the 0xA8 values. D = this rom's primary slot, E = the RAM's
	ld	a,(tslot)
	and	3
	ld	d,a
	ld	a,(ramslot)
	and	3
	ld	e,a
	ld	b,e
	ld	c,d
	ld	h,d
	ld	l,e
	call	a8_make
	ld	(a8_p1),a
	ld	h,e
	call	a8_make
	ld	(a8_p1r2),a
	ld	b,d
	ld	h,d
	call	a8_make
	ld	(a8_x),a
	ld	c,e
	call	a8_make
	ld	(a8_f),a
	ld	a,(a8_p1)
	out	(0xA8),a		; page 0 RAM, page 2 this rom
	; what is kept of the MSX's own (see CB_KEEP), with the RAM's secondary slots in SLTTBL
	push	de
	ld	hl,EXPTBL
	ld	de,CB_KEEP
	ld	bc,8
	ldir
	ld	hl,KEEP_2A
	ld	c,KEEP_2A_LEN
	ldir
	ld	hl,KEEP_2B
	ld	c,KEEP_2B_LEN
	ldir
	ld	a,(ramslot)
	bit	7,a
	jr	z,.kept
	and	3
	ld	hl,CB_KEEP+4
	add	a,l
	ld	l,a
	ld	a,(snap_ffff)
	ld	(hl),a
.kept:	pop	de
	ld	a,SNAP_STATE
	ld	(BANK_REG),a
	; the game's slots: its RAM pages in the RAM's slot, its BIOS pages in the main ROM's
	ld	a,(biosslot)
	and	3
	ld	c,a
	ld	hl,WINDOW+ST_PAGES+3
	ld	b,4
	xor	a
.pages:	add	a,a
	add	a,a
	bit	0,(hl)
	jr	z,.ram
	or	c
	jr	.page
.ram:	or	e
.page:	dec	hl
	djnz	.pages
	ld	(a8_end),a
	; I and the interrupt mode
	ld	a,(WINDOW+ST_I)
	ld	i,a
	ld	a,(WINDOW+ST_IM)
	cp	2
	jr	z,.im2
	cp	1
	jr	z,.im1
	im	0
	jr	.im
.im1:	im	1
	jr	.im
.im2:	im	2
.im:
	; the stub: out (0xA8),a / pop af / ei (or nop) / ret, then F, A and PC for it
	ld	hl,snapstub
	ld	(hl),0xD3
	inc	hl
	ld	(hl),0xA8
	inc	hl
	ld	(hl),0xF1
	inc	hl
	ld	a,(WINDOW+ST_IFF)
	or	a
	jr	z,.di
	ld	a,0xFB
.di:	ld	(hl),a
	inc	hl
	ld	(hl),0xC9
	inc	hl
	ld	de,(WINDOW+ST_AF)
	ld	(hl),e
	inc	hl
	ld	(hl),d
	inc	hl
	ld	de,(WINDOW+ST_PC)
	ld	(hl),e
	inc	hl
	ld	(hl),d
	ld	hl,snapstub
	ld	de,CB_STUB
	ld	bc,9
	ldir
	ld	hl,(WINDOW+ST_AF2)
	ld	(CB_AF2),hl
	ld	hl,(WINDOW+ST_SP)
	ld	(snap_sp),hl
	; what goes back (CB_KEEP_BITS). On an MSX2 its MSX2 variables, but not where the game has its
	; stack
	ld	b,0
	ld	a,(snap_msx)
	or	a
	jr	z,.keepb
	ld	b,3
	ld	a,h
	cp	0xFA			; KEEP_2A is 0xFAF5-0xFB02
	jr	z,.no2a
	cp	0xFB
	jr	nz,.k2b
.no2a:	res	0,b
.k2b:	cp	0xFF
	jr	z,.no2b
	or	a
	jr	nz,.keepb
.no2b:	res	1,b
.keepb:	; RAMAD0-3, if they are all the VG-8020's RAM
	ld	a,SNAP_RAM+7
	ld	(BANK_REG),a
	ld	hl,WINDOW+RAMAD0-0xE000
	ld	c,4
	ld	a,SNAP_RAMSLOT
.ramad:	cp	(hl)
	jr	nz,.noramad
	inc	hl
	dec	c
	jr	nz,.ramad
	set	2,b
	ld	a,(ramslot)
	ld	(CB_RAMAD),a
.noramad:
	ld	a,b
	ld	(CB_KEEP_BITS),a
	ld	a,SNAP_STATE
	ld	(BANK_REG),a
	; the final routine, and what goes in it
	ld	hl,fin_code
	ld	de,CB_FINAL
	ld	bc,FIN_LEN
	ldir
	ld	a,(a8_f)
	ld	(CB_FINAL+fin.a8f-fin),a
	ld	a,(a8_end)
	ld	(CB_FINAL+fin.a8end-fin),a
	and	0xFC
	ld	b,a
	ld	a,(tslot)
	and	3
	or	b
	ld	(CB_FINAL+fin.a8mid-fin),a
	ld	a,(WINDOW+ST_R)
	ld	(CB_FINAL+fin.r-fin),a
	ld	hl,(snap_sp)
	ld	de,-4
	add	hl,de
	ld	(CB_FINAL+fin.sp-fin),hl
	dec	hl
	dec	hl
	dec	hl
	dec	hl
	dec	hl
	ld	(CB_FINAL+fin.stub-fin),hl
	ld	(CB_FINAL+fin.jp-fin),hl
	ld	hl,(WINDOW+ST_BC2)
	ld	(CB_FINAL+fin.bc2-fin),hl
	ld	hl,(WINDOW+ST_DE2)
	ld	(CB_FINAL+fin.de2-fin),hl
	ld	hl,(WINDOW+ST_HL2)
	ld	(CB_FINAL+fin.hl2-fin),hl
	ld	hl,(WINDOW+ST_IX)
	ld	(CB_FINAL+fin.ix-fin),hl
	ld	hl,(WINDOW+ST_IY)
	ld	(CB_FINAL+fin.iy-fin),hl
	ld	hl,(WINDOW+ST_BC)
	ld	(CB_FINAL+fin.bc-fin),hl
	ld	hl,(WINDOW+ST_DE)
	ld	(CB_FINAL+fin.de-fin),hl
	ld	hl,(WINDOW+ST_HL)
	ld	(CB_FINAL+fin.hl-fin),hl
	; a stack in page 2 gets its stub below, not in the final routine (page 2 is this rom there)
	ld	a,(snap_sp+1)
	and	0xC0
	cp	0x80
	jr	nz,.vram
	ld	hl,0
	ld	(CB_FINAL+fin.copy-fin),hl	; nop, nop for its ldir
.vram:	; VRAM, with the screen off so the VDP takes it at full speed
	ld	a,0x80
	out	(0x99),a
	ld	a,0x81
	out	(0x99),a
	xor	a
	out	(0x99),a
	ld	a,0x40
	out	(0x99),a
	ld	a,SNAP_VRAM
	call	.vbank
	ld	a,SNAP_VRAM+1
	call	.vbank
	; VDP registers 0-7
	ld	a,SNAP_STATE
	ld	(BANK_REG),a
	ld	hl,WINDOW+ST_VDP
	ld	b,0x80
.vdp:	ld	a,(hl)
	out	(0x99),a
	ld	a,b
	out	(0x99),a
	inc	hl
	inc	b
	ld	a,b
	cp	0x88
	jr	nz,.vdp
	; PSG registers 0-13. 7: port A in, port B out, as on every MSX
	ld	hl,WINDOW+ST_PSG
	ld	b,0
.psg:	ld	a,b
	out	(0xA0),a
	ld	c,(hl)
	cp	7
	ld	a,c
	jr	nz,.psgv
	and	0x3F
	or	0x80
.psgv:	out	(0xA1),a
	inc	hl
	inc	b
	ld	a,b
	cp	14
	jr	nz,.psg
	; port C of the PPI, with the tape motor off
	ld	a,(WINDOW+ST_PPIC)
	or	0x10
	out	(0xAA),a
	; RAM page 0
	ld	a,SNAP_RAM
	ld	de,0x0000
	call	.ram8
	ld	a,SNAP_RAM+1
	ld	de,0x2000
	call	.ram8
	; RAM page 2, through 0x6000
	ld	a,SNAP_RAM+4
	ld	de,0x8000
	call	.ram8hi
	ld	a,SNAP_RAM+5
	ld	de,0xA000
	call	.ram8hi
	ld	a,(snap_sp+1)
	and	0xC0
	cp	0x80
	jr	nz,.page3
	ld	hl,(snap_sp)		; page 2 is still RAM: the stub
	ld	de,-9
	add	hl,de
	ex	de,hl
	ld	hl,snapstub
	ld	bc,9
	ldir
.page3:	ld	a,(a8_p1)
	out	(0xA8),a
	; 0xFFFF is the secondary slot register if the RAM is in an expanded slot: that stays
	ld	a,SNAP_RAM+7
	ld	(BANK_REG),a
	ld	a,(ramslot)
	bit	7,a
	ld	a,(WINDOW+0x1FFF)
	jr	z,.ffff
	ld	a,(snap_ffff)
.ffff:	ld	ixl,a
	; RAM page 3, and with it this rom's stack and variables: none of them from here on
	ld	a,(a8_x)
	ex	af,af'
	ld	a,SNAP_RAM+6
	ld	(BANK_REG),a
	ld	hl,WINDOW
	ld	de,0xC000
	ld	bc,0x2000
	ldir
	ld	a,SNAP_RAM+7
	ld	(BANK_REG),a
	ld	hl,WINDOW
	ld	de,0xE000
	ld	bc,0x1FFF
	ldir
	ld	a,ixl
	ld	(0xFFFF),a
	ld	hl,CB_KEEP
	ld	de,EXPTBL
	ld	bc,8
	ldir
	ld	a,(CB_KEEP_BITS)
	rrca
	jr	nc,.k2
	ld	hl,CB_KEEP+8
	ld	de,KEEP_2A
	ld	bc,KEEP_2A_LEN
	ldir
.k2:	rrca
	jr	nc,.k3
	ld	hl,CB_KEEP+8+KEEP_2A_LEN
	ld	de,KEEP_2B
	ld	bc,KEEP_2B_LEN
	ldir
.k3:	rrca
	jr	nc,.k4
	ld	a,(CB_RAMAD)
	ld	hl,RAMAD0
	ld	(hl),a
	inc	hl
	ld	(hl),a
	inc	hl
	ld	(hl),a
	inc	hl
	ld	(hl),a
.k4:	ex	af,af'
	out	(0xA8),a		; page 0 this rom: the control block is there too
	jp	CB_FINAL-0x8000

; 8K of VRAM from bank A
.vbank:	ld	(BANK_REG),a
	ld	hl,WINDOW
	ld	c,0x98
	ld	b,0
	ld	d,32
.v:	otir
	dec	d
	jr	nz,.v
	ret

; 8K of RAM to DE from bank A, through 0xA000
.ram8:	ld	(BANK_REG),a
	ld	hl,WINDOW
	ld	bc,0x2000
	ldir
	ret

; 8K of RAM to DE (page 2) from bank A, through 0x6000. Page 2 is RAM at the end
.ram8hi:
	ld	c,a
	ld	a,(a8_p1)
	out	(0xA8),a
	ld	a,c
	ld	(BANK_REG_6000),a
	ld	a,(a8_p1r2)
	out	(0xA8),a
	ld	hl,0x6000
	ld	bc,0x2000
	ldir
	ret

; A = 0xA8 for page 0 in slot B, page 1 in C, page 2 in H, page 3 in L
a8_make:
	ld	a,l
	add	a,a
	add	a,a
	or	h
	add	a,a
	add	a,a
	or	c
	add	a,a
	add	a,a
	or	b
	ret

; The final routine, copied to the control block. The values in it are filled in there
fin_code:
	DISP	CB_FINAL-0x8000
fin:	ld	a,0
.a8f	equ	$-1
	out	(0xA8),a		; page 1 RAM, pages 0 and 2 this rom
	ld	a,SNAP_RAM+2
	ld	(BANK_REG),a
	ld	hl,0x2000		; the bank of 0xA000 shows at 0x2000 too
	ld	de,0x4000
	ld	bc,0x2000
	ldir
	ld	a,SNAP_RAM+3
	ld	(BANK_REG),a
	ld	hl,0x2000
	ld	de,0x6000
	ld	bc,0x2000
	ldir
	ld	hl,CB_STUB-0x8000
	ld	de,0
.stub	equ	$-2
	ld	bc,9
.copy:	ldir
	ld	sp,CB_AF2-0x8000
	pop	af
	ex	af,af'
	exx
	ld	bc,0
.bc2	equ	$-2
	ld	de,0
.de2	equ	$-2
	ld	hl,0
.hl2	equ	$-2
	exx
	ld	ix,0
.ix	equ	$-2
	ld	iy,0
.iy	equ	$-2
	ld	bc,0
.bc	equ	$-2
	ld	de,0
.de	equ	$-2
	ld	hl,0
.hl	equ	$-2
	ld	a,0
.r	equ	$-1
	ld	r,a
	ld	sp,0
.sp	equ	$-2
	ld	a,0
.a8mid	equ	$-1
	out	(0xA8),a		; the game's slots in pages 1-3: the stub can be in any of them
	ld	a,0
.a8end	equ	$-1
	jp	0
.jp	equ	$-2
	ENT
FIN_LEN		equ	$-fin_code
	ASSERT	CB_FINAL+FIN_LEN <= 0x8100

; ---------------------------------------------------------------------------------------------
; Copied to STUB and run from there: ask the board for the selected entry, wait for the menu
; rom to be replaced, then reset so the BIOS finds the new rom or disk rom
	IFNDEF SIM
stub_src:
	DISP	STUB
stub_start:
	; First PREPARE: a rom over 128K goes to the board's flash, and the board does not answer
	; now and then while it writes (the bus reads 0xFF). So wait for all of "RDY!"
	xor	a
	ld	(CTRL_READY),a
	ld	a,CMD_PREPARE
	ld	(CMD_REG),a
	ld	hl,(JIFFY)
	ld	(stub_t),hl
.ready:	ld	hl,CTRL_READY
	ld	de,.rdy
	ld	b,4
.cmp:	ld	a,(de)
	cp	(hl)
	jr	nz,.not_yet
	inc	hl
	inc	de
	djnz	.cmp
	jr	.load
.not_yet:
	call	.elapsed
	ld	de,2500			; 40 seconds or more
	or	a
	sbc	hl,de
	jr	c,.ready
.load:	ld	a,CMD_LOAD_ROM
	ld	(CMD_REG),a
	ld	hl,(JIFFY)
	ld	(stub_t),hl
.wait:
	ld	a,(CMD_REG)
	cp	CMD_LOAD_ROM
	jr	nz,.changed
	call	.elapsed
	ld	de,300			; about 6 seconds
	or	a
	sbc	hl,de
	jr	c,.wait
	jr	.reset
.changed:
	; the board copies the new rom in. Give it a moment to finish
	ld	hl,(JIFFY)
	ld	(stub_t),hl
.settle:
	call	.elapsed
	ld	de,10
	or	a
	sbc	hl,de
	jr	c,.settle
.reset:
	di
	rst	0
.elapsed:
	ld	hl,(JIFFY)
	ld	de,(stub_t)
	or	a
	sbc	hl,de
	ret
.rdy:	db	"RDY!"
	ENT
stub_end:
	ENDIF

; ---------------------------------------------------------------------------------------------
; menu-sim.rom: a made up list instead of the board
	IFDEF SIM
SIM_COUNT	equ	700
SIM_FILES	equ	(sim_files_end-sim_files)/ENTRY_SIZE

sim_version	db	"2.0.0", 0
sim_path	db	"/DSKS/MSX 2", 0

; HL = address of made up entry HL: "..", two folders, then the files over and over
entry_addr:
	ld	a,h
	or	a
	jr	nz,.file
	ld	a,l
	cp	3
	jr	nc,.file
	ld	h,0
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,hl
	ld	de,sim_dirs
	add	hl,de
	ret
.file:	ld	de,3
	or	a
	sbc	hl,de
	ld	de,SIM_FILES
.mod:	or	a
	sbc	hl,de
	jr	nc,.mod
	add	hl,de
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,hl
	add	hl,hl
	ld	de,sim_files
	add	hl,de
	ret

	MACRO	SIMENT type, name, size
	db	type, name, 0
	ds	ENTRY_SIZE_K - ($ & 31), 0
	dw	size
	ENDM

	ALIGN	32, 0
sim_dirs:
	SIMENT	'U', "..", 0
	SIMENT	'F', "Konami", 0
	SIMENT	'F', "Ys 3", 0
COVER	equ	0x8000			; in the size: there is a cover
sim_files:
	SIMENT	'S', "Aleste 2", COVER
	SIMENT	'D', "Arkanoid 2", 720
	SIMENT	'R', "Gradius 2", 128
	SIMENT	'R', "Knightmare", 32|COVER
	SIMENT	'D', "Metal Gear 2 - Solid Snake", 720
	SIMENT	'R', "Nemesis", 128
	SIMENT	'S', "Psy-o-Blade", 0
	SIMENT	'R', "Road Fighter", 16|COVER
	SIMENT	'D', "Shalom - Knightmare III", 720
	SIMENT	'R', "The Maze of Galious", 128
	SIMENT	'D', "Xak - The Art of Visual St", 720
	SIMENT	'T', "Yie Ar Kung-Fu 2", 26|COVER
	SIMENT	'M', "Nemesis 1-2", 3
	SIMENT	'M', "Vampire Killer 1", 2
	SIMENT	'R', "Zanac", 32
sim_files_end:
	ENDIF

	IFDEF SIMTAPE
; menu-simtape.rom: tools/test_tapes.py makes an ASCII8 rom of it with a tape from bank 8 on, to
; try tapes in openMSX. It starts with all four banks 0, so everything has to be in bank 0
	ASSERT	$ <= 0x5FFC
	ds	0x5FFC-$, 0xFF
sim_tape_size	dd	0		; filled in by test_tapes.py
	ds	0x2000, 0xFF		; bank 1
	ds	0x2000, 0		; bank 2: at 0x8000 after init, without the "AB" of bank 0
	ELSE
	IFNDEF SIM
	ASSERT	$ <= 0x6000		; snap_init has other banks at 0x6000
	ENDIF
	ASSERT	$ <= 0x8000		; the menu has to fit in 16K
	ds	0x8000-$, 0xFF
	ENDIF

; menu-sim.rom is 32K. Every cover is this one (sim-cover.sc2, made with make_covers.ps1), and
; every song sim-song.vgm (made with ../tools/mid2vgm.py, 4K at most)
	IFDEF SIM
sim_cover:
	incbin	"sim-cover.sc2", 7, COVER_PART
	incbin	"sim-cover.sc2", 7+0x2000, COVER_PART
sim_song:
	incbin	"sim-song.vgm"
SIM_SONG_LEN	equ	$-sim_song
	ASSERT	$ <= 0xC000
	ds	0xC000-$, 0xFF
	ENDIF
