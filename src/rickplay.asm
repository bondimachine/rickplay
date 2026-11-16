; RICKPLAY.EXE - AVI player for Windows 3.0 in REAL MODE on an 8088 with CGA.
;
; Plays standard .AVI files whose video is Microsoft Video 1 (CRAM/MSVC), 8-bit
; palettized or 16-bit RGB555 - the codec Video for Windows 1.0 shipped with.
; Frames are decoded straight to dithered 1-bit pixels (each source pixel is
; doubled horizontally for CGA's 640x200 aspect), then SetBitmapBits + BitBlt.
; Playback follows the clock: if the machine is too slow, frames are still
; decoded (Video 1 frames depend on the previous one) but not all are drawn.
; Sound is not played.
;
; Command line:  RICKPLAY [file.avi] [/T]
;   /T  test run: play one pass, write RICK.LOG next to the exe (and RICK.FRM,
;       the last decoded frame as raw 1-bit rows), exit Windows.
;
; Real-mode rules followed here:
;  * 8086 instructions only (cpu 8086 makes NASM enforce it).
;  * Code and data segments are FIXED (see mkne.py), so nothing of ours moves.
;  * Callbacks use the standard far-frame prolog (inc bp / push bp / mov bp,sp /
;    push ds), so the real-mode kernel can patch return addresses into USER and
;    saved DS values when it moves their segments. DS is taken from SS (all
;    callbacks run on our task's stack, and SS = DGROUP), so no thunks are needed.

cpu 8086
bits 16

%include "imports.inc"

%macro IMP 1
imp_%1: dw 0FFFFh, 0            ; patched by the loader (import by ordinal)
%endmacro
%macro API 1
        call far [cs:imp_%1]
%endmacro
%macro PUSHI 1                   ; 8086 has no PUSH imm (clobbers AX)
        mov ax, %1
        push ax
%endmacro

WM_DESTROY      equ 0002h
WM_PAINT        equ 000Fh
WM_QUIT         equ 0012h
WM_INITDIALOG   equ 0110h
WM_COMMAND      equ 0111h
WS_STYLE_HI     equ 00CAh            ; WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX (high word)
CW_USEDEFAULT   equ 8000h
SRCCOPY_HI      equ 00CCh
SRCCOPY_LO      equ 0020h
IDC_ARROW       equ 32512
BLACK_BRUSH     equ 4
MB_ICONHAND     equ 0010h
MB_ICONINFO     equ 0040h
SWP_NOMOVE_NOZORDER equ 0006h
DDL_DIRS_DRIVES equ 4010h

IDM_OPEN        equ 100              ; menu / dialog ids - must match mkne.py
IDM_EXIT        equ 101
IDM_ABOUT       equ 102
IDD_OPEN        equ 1
IDC_NAME        equ 10
IDC_PATH        equ 11
IDC_LIST        equ 12

CHUNKMAX        equ 30000            ; largest compressed frame
OUTMAX          equ 19200            ; 320x240 source -> 80 bytes x 240 rows
DEF_W           equ 320              ; client size before a file is open
DEF_H           equ 120

; ================================================================ code
section .text vstart=0
        dw code_end                     ; +0  code length          (read by mkne.py)
        dw section..data.start          ; +2  data file offset
        dw data_init_end                ; +4  initialized data length
        dw entry                        ; +6  entry point IP
        dw bss_end                      ; +8  data segment size incl. buffers
        dw 0                            ; +10
        IMPORT_TABLE                    ; +12 import far pointers

entry:
        xor bp, bp                      ; end of the BP frame chain
        push bp
        API INITTASK                    ; DI=hInst SI=hPrev DX=nCmdShow ES:BX=cmdline
        or ax, ax
        jz .fail
        mov [hInst], di
        mov [hPrev], si
        mov [cmdShow], dx
        ; command line: /T (or -T) = test mode, first other word = file name
.scan:  mov al, [es:bx]
        or al, al
        jz .scanned
        inc bx
        cmp al, ' '
        jbe .scan
        cmp al, '/'
        je .opt
        cmp al, '-'
        je .opt
        cmp byte [argName], 0           ; first word only
        jne .skipw
        mov di, argName
        mov cx, 79
.copy:  mov [di], al
        inc di
        mov al, [es:bx]
        cmp al, ' '
        jbe .copied
        inc bx
        loop .copy
.copied:
        mov byte [di], 0
        jmp .scan
.skipw: mov al, [es:bx]
        cmp al, ' '
        jbe .scan
        inc bx
        jmp .skipw
.opt:   mov al, [es:bx]
        inc bx
        and al, 0DFh
        cmp al, 'T'
        jne .scan
        mov byte [testMode], 1
        jmp .scan
.scanned:
        PUSHI 0
        API WAITEVENT
        push word [hInst]
        API INITAPP
        or ax, ax
        jz .fail
        call main
        mov ah, 4Ch
        int 21h
.fail:  mov ax, 4CFFh
        int 21h

; ================================================================ main
main:
        push bp
        mov bp, sp

        ; exePath = full name of RICKPLAY.EXE, exeNameAt -> its file name part
        push word [hInst]
        push ds
        PUSHI exePath
        PUSHI 128
        API GETMODULEFILENAME
        mov si, exePath
        add si, ax
.back:  cmp si, exePath
        je .gotdir
        mov al, [si-1]
        cmp al, '\'
        je .gotdir
        cmp al, ':'
        je .gotdir
        dec si
        jmp .back
.gotdir:
        mov [exeNameAt], si

        ; window class with the menu from the resources
        cmp word [hPrev], 0
        jne .registered
        mov word [wc], 1000h            ; CS_BYTEALIGNCLIENT: byte-aligned blits
        mov word [wc+2], WndProc
        mov word [wc+4], cs
        mov ax, [hInst]
        mov [wc+10], ax
        PUSHI 0
        PUSHI 0
        PUSHI IDC_ARROW
        API LOADCURSOR
        mov [wc+14], ax
        PUSHI BLACK_BRUSH
        API GETSTOCKOBJECT
        mov [wc+16], ax
        mov word [wc+18], 1             ; lpszMenuName = MAKEINTRESOURCE(1)
        mov word [wc+20], 0
        mov word [wc+22], className
        mov [wc+24], ds
        push ds
        PUSHI wc
        API REGISTERCLASS
        or ax, ax
        jnz .registered
        jmp .nowin
.registered:
        mov word [rect+4], DEF_W
        mov word [rect+6], DEF_H
        call outer_size                 ; -> CX, DX
        push ds
        PUSHI className
        push ds
        PUSHI appName
        PUSHI WS_STYLE_HI
        PUSHI 0
        PUSHI CW_USEDEFAULT
        PUSHI 0
        push cx
        push dx
        PUSHI 0                         ; parent
        PUSHI 0                         ; menu (class menu)
        push word [hInst]
        PUSHI 0
        PUSHI 0
        API CREATEWINDOW
        or ax, ax
        jnz .created
.nowin: mov dx, errWnd
        call errbox
        mov al, 1
        jmp .ret
.created:
        mov [hWnd], ax
        push ax
        API GETDC
        mov si, ax
        push ax
        API CREATECOMPATIBLEDC
        mov [hMemDC], ax
        push word [hWnd]
        push si
        API RELEASEDC
        cmp word [hMemDC], 0
        je .nowin

        push word [hWnd]
        push word [cmdShow]
        API SHOWWINDOW
        push word [hWnd]
        API UPDATEWINDOW

        API GETCURRENTTIME
        mov [tStart], ax
        mov [tStart+2], dx

        ; file from the command line
        cmp byte [argName], 0
        je .loop
        call resolve_arg
        call open_avi
        jnc .loop
        cmp byte [testMode], 0
        je .loop
        push word [hWnd]
        API DESTROYWINDOW

        ; ---- message loop: messages first, otherwise decode/show the next frame
.loop:  push ds
        PUSHI msg
        PUSHI 0
        PUSHI 0
        PUSHI 0
        PUSHI 1                         ; PM_REMOVE
        API PEEKMESSAGE
        or ax, ax
        jz .idle
        cmp word [msg+2], WM_QUIT
        je .quit
        push ds
        PUSHI msg
        API TRANSLATEMESSAGE
        push ds
        PUSHI msg
        API DISPATCHMESSAGE
        jmp .loop
.idle:  cmp word [hWnd], 0
        je .loop
        cmp byte [fileOpen], 0
        je .wait
        push word [hWnd]
        API ISICONIC
        or ax, ax
        jnz .iconic
        cmp byte [needResync], 0
        je .play
        call resync
        mov byte [needResync], 0
.play:  call next_frame
        jmp .loop
.iconic:
        mov byte [needResync], 1        ; minimized: pause, don't burn the CPU
.wait:  API WAITMESSAGE
        jmp .loop

.quit:  call close_avi
        call free_gdi
        cmp byte [testMode], 0
        je .done
        call write_log
        PUSHI 0
        PUSHI 0
        PUSHI 0
        API EXITWINDOWS
.done:  xor al, al
.ret:   mov sp, bp
        pop bp
        ret

; outer_size: rect = client size -> CX, DX = window width, height
outer_size:
        mov word [rect+0], 0
        mov word [rect+2], 0
        push ds
        PUSHI rect
        PUSHI WS_STYLE_HI
        PUSHI 0
        PUSHI 1                         ; has a menu
        API ADJUSTWINDOWRECT
        mov cx, [rect+4]
        sub cx, [rect+0]
        mov dx, [rect+6]
        sub dx, [rect+2]
        ret

; resolve_arg: argName -> fileName. A bare name that doesn't exist in the
; current directory is looked up next to RICKPLAY.EXE.
resolve_arg:
        push ds
        pop es
        cld
        mov si, argName
        mov di, fileName
        call strcpy
        mov si, argName
.chk:   lodsb
        or al, al
        jz .bare
        cmp al, ':'
        je .x
        cmp al, '\'
        je .x
        jmp .chk
.bare:  push ds
        PUSHI fileName
        PUSHI 0
        API _LOPEN
        cmp ax, 0FFFFh
        je .exedir
        push ax
        API _LCLOSE
.x:     ret
.exedir:
        push ds
        pop es
        mov si, exePath
        mov di, fileName
        mov cx, [exeNameAt]
        sub cx, si
        rep movsb
        mov si, argName
        call strcpy
        ret

; strcpy: DS:SI -> ES:DI including the zero; DI ends after the zero
strcpy: lodsb
        stosb
        or al, al
        jnz strcpy
        ret

; errbox: message box with the text at DS:DX
errbox: push word [hWnd]
        push ds
        push dx
        push ds
        PUSHI appName
        PUSHI MB_ICONHAND
        API MESSAGEBOX
        ret

; ================================================================ file I/O
; fread: DI = destination, CX = bytes -> AX = bytes read; pos advanced
fread:  push word [hFile]
        push ds
        push di
        push cx
        API _LREAD
        cmp ax, 0FFFFh
        jne .ok
        xor ax, ax
.ok:    add [pos], ax
        adc word [pos+2], 0
        ret

; fseek: DX:AX offset, BL origin (0 = start, 1 = current) -> pos = new position
fseek:  push word [hFile]
        push dx
        push ax
        xor bh, bh
        push bx
        API _LLSEEK
        mov [pos], ax
        mov [pos+2], dx
        ret

; fskip: skip DX:AX bytes
fskip:  mov bl, 1
        jmp fseek

; skip_padded: skip a chunk body of DX:AX bytes (RIFF pads to even)
skip_padded:
        add ax, 1
        adc dx, 0
        and al, 0FEh
        jmp fskip

; readpart: read min(csz, CX) bytes to DI, then skip the rest of the chunk (csz)
readpart:
        mov ax, [csz]
        cmp word [csz+2], 0
        jne .big
        cmp ax, cx
        jae .big
        mov cx, ax
.big:   push cx
        call fread
        pop cx
        mov ax, [csz]
        mov dx, [csz+2]
        sub ax, cx
        sbb dx, 0
        mov bx, ax
        or bx, dx
        jz .r
        call fskip
.r:     ret

; ================================================================ open_avi
; Open fileName, parse the AVI headers, size the window. CF set on error
; (an error box has been shown and no file is open).
open_avi:
        call close_avi
        push ds
        PUSHI fileName
        PUSHI 0                         ; OF_READ
        API _LOPEN
        cmp ax, 0FFFFh
        jne .opened
        mov dx, errOpen
        jmp .err
.opened:
        mov [hFile], ax
        xor ax, ax
        mov [pos], ax
        mov [pos+2], ax
        mov [usPerFrame], ax
        mov [usPerFrame+2], ax
        mov byte [vidStream], 0FFh
        mov byte [strCount], 0
        mov byte [pendingVid], 0
        mov byte [gotFmt], 0

        mov di, ckhdr
        mov cx, 12
        call fread
        cmp ax, 12
        jne .bad
        cmp word [ckhdr], 'RI'
        jne .bad
        cmp word [ckhdr+2], 'FF'
        jne .bad
        cmp word [ckhdr+8], 'AV'
        jne .bad
        cmp word [ckhdr+10], 'I '
        jne .bad

        ; walk the chunks until LIST 'movi'
.chunk: mov di, ckhdr
        mov cx, 8
        call fread
        cmp ax, 8
        jne .bad
        mov ax, [ckhdr+4]
        mov dx, [ckhdr+6]
        add ax, 1
        adc dx, 0
        and al, 0FEh
        mov [csz], ax
        mov [csz+2], dx
        mov ax, [ckhdr]
        mov dx, [ckhdr+2]
        cmp ax, 'LI'
        jne .notlist
        cmp dx, 'ST'
        je .list
.notlist:
        cmp ax, 'av'
        jne .n1
        cmp dx, 'ih'
        je .avih
.n1:    cmp ax, 'st'
        jne .skipall
        cmp dx, 'rh'
        je .strh
        cmp dx, 'rf'
        je .strf
.skipall:
        mov ax, [csz]
        mov dx, [csz+2]
        call fskip
        jmp .chunk

.list:  mov di, ckhdr+8
        mov cx, 4
        call fread
        cmp ax, 4
        jne .bad
        mov ax, [ckhdr+8]
        mov dx, [ckhdr+10]
        cmp ax, 'mo'
        jne .l1
        cmp dx, 'vi'
        je .movi
.l1:    cmp ax, 'hd'
        jne .l2
        cmp dx, 'rl'
        je .chunk                       ; descend into header lists
.l2:    cmp ax, 'st'
        jne .l3
        cmp dx, 'rl'
        je .chunk
.l3:    mov ax, [csz]                   ; skip any other list
        mov dx, [csz+2]
        sub ax, 4
        sbb dx, 0
        call fskip
        jmp .chunk

.avih:  mov di, tmp
        mov cx, 56
        call readpart
        mov ax, [tmp]
        mov [usPerFrame], ax
        mov ax, [tmp+2]
        mov [usPerFrame+2], ax
        jmp .chunk

.strh:  mov word [tmp], 0
        mov di, tmp
        mov cx, 56
        call readpart
        cmp word [tmp], 'vi'
        jne .strh2
        cmp word [tmp+2], 'ds'
        jne .strh2
        cmp byte [vidStream], 0FFh
        jne .strh2
        mov al, [strCount]
        mov [vidStream], al
        mov byte [pendingVid], 1
.strh2: inc byte [strCount]
        jmp .chunk

.strf:  cmp byte [pendingVid], 0
        je .skipall
        mov byte [pendingVid], 0
        push ds
        pop es
        mov di, fmt
        mov cx, FMTSIZE
        xor al, al
        cld
        rep stosb
        mov di, fmt
        mov cx, FMTSIZE
        call readpart
        mov byte [gotFmt], 1
        jmp .chunk

.movi:  mov ax, [pos]
        mov dx, [pos+2]
        mov [moviStart], ax
        mov [moviStart+2], dx
        add ax, [ckhdr+4]
        adc dx, [ckhdr+6]
        sub ax, 4
        sbb dx, 0
        mov [moviEnd], ax
        mov [moviEnd+2], dx

        ; ---- is it something we can play?
        cmp byte [gotFmt], 0
        jne .hasvid
        mov dx, errNoVid
        jmp .err
.hasvid:
        mov ax, [fmt+16]                ; biCompression, upper-cased
        mov dx, [fmt+18]
        and ax, 0DFDFh
        and dx, 0DFDFh
        cmp ax, 'CR'
        jne .c2
        cmp dx, 'AM'
        je .codec
.c2:    cmp ax, 'MS'
        jne .unsup
        cmp dx, 'VC'
        jne .unsup
.codec: mov ax, [fmt+14]                ; biBitCount
        mov byte [depth16], 0
        cmp ax, 8
        je .depth
        mov byte [depth16], 1
        cmp ax, 16
        jne .unsup
.depth: cmp word [fmt+6], 0             ; width/height must fit and be multiples of 4
        jne .unsup
        cmp word [fmt+10], 0
        jne .unsup
        mov ax, [fmt+4]
        mov dx, [fmt+8]
        or ax, ax
        jz .unsup
        or dx, dx
        jz .unsup
        test ax, 3
        jnz .unsup
        test dx, 3
        jnz .unsup
        cmp ax, 320
        ja .unsup
        cmp dx, 240
        ja .unsup
        jmp .geom
.unsup: mov dx, errCodec
        jmp .err
.bad:   mov dx, errFmt
.err:   call close_avi
        call errbox
        stc
        ret

.geom:  mov [vidH], dx
        shr ax, 1
        shr ax, 1
        mov [blocksWide], ax            ; one output byte per 4x4 block
        mov cx, ax
        shl cx, 1
        shl cx, 1
        shl cx, 1
        mov [bmpW], cx                  ; source width x 2 (what we show)
        ; Rows are a fixed 40 or 80 bytes, so the decoder can use the stride as
        ; an immediate. The bitmap is that wide; only bmpW pixels are shown.
        mov bx, 40
        cmp ax, 40
        jbe .s40
        mov bx, 80
.s40:   mov [stride], bx
        mov cx, bx
        shl cx, 1
        shl cx, 1
        shl cx, 1
        mov [bitmapW], cx
        cmp bx, 40
        je .d40
        mov cx, dec8_80
        cmp byte [depth16], 0
        je .dsel
        mov cx, dec16_80
        jmp .dsel
.d40:   mov cx, dec8_40
        cmp byte [depth16], 0
        je .dsel
        mov cx, dec16_40
.dsel:  mov [decoderFn], cx
        cmp byte [depth16], 0
        je .lutok
        push ax
        push bx
        push dx
        call build_lut
        pop dx
        pop bx
        pop ax
        jnc .lutok
        mov dx, errMem
        jmp .err
.lutok:
        mov ax, bx
        mov cx, dx
        shr cx, 1
        shr cx, 1
        mov [blocksHigh], cx
        mul dx                          ; stride * height
        mov [outSize], ax
        sub ax, [stride]
        add ax, outBuf
        mov [outBottom], ax             ; first decoded row = bottom row

        ; the video chunk id is "NNdc" / "NNdb", NN = stream number
        mov al, [vidStream]
        aam
        add ax, '00'
        xchg al, ah
        mov [vidId], ax

        ; ms per frame * 16 = usPerFrame * 2 / 125
        mov ax, [usPerFrame]
        mov dx, [usPerFrame+2]
        mov bx, ax
        or bx, dx
        jnz .usok
        mov ax, 046Bh                   ; default 66667 us (15 fps)
        mov dx, 1
.usok:  shl ax, 1
        rcl dx, 1
        mov cx, 125
        cmp dx, cx
        jb .div
        mov ax, 0FFFFh
        jmp .msok
.div:   div cx
.msok:  mov [msx16], ax

        ; 8-bit: palette -> dither level per colour index
        cmp byte [depth16], 0
        jne .nopal
        mov cx, [fmt+32]                ; biClrUsed
        or cx, cx
        jz .c256
        cmp cx, 256
        jbe .ncol
.c256:  mov cx, 256
.ncol:  mov si, [fmt]                   ; biSize: palette follows the header
        cmp si, 40
        jb .bsz
        cmp si, 64
        jbe .bszok
.bsz:   mov si, 40
.bszok: add si, fmt
        push ds
        pop es
        mov di, palLvl
        cld
.pal:   xor ah, ah
        mov al, [si+2]                  ; grey = (2R + 5G + B) / 8
        shl ax, 1
        mov bx, ax
        mov al, [si+1]
        xor ah, ah
        mov dx, ax
        shl ax, 1
        shl ax, 1
        add ax, dx
        add bx, ax
        mov al, [si]
        xor ah, ah
        add ax, bx
        push cx
        mov cl, 3
        shr ax, cl
        pop cx
        mov bx, tabLvl
        xlat
        stosb
        add si, 4
        loop .pal
.nopal:
        ; fresh bitmap of the video size in the memory DC
        call free_bmp
        push word [bitmapW]
        push word [vidH]
        PUSHI 1
        PUSHI 1
        PUSHI 0
        PUSHI 0
        API CREATEBITMAP
        or ax, ax
        jnz .bmp
        mov dx, errMem
        jmp .err
.bmp:   mov [hBmp], ax
        push word [hMemDC]
        push ax
        API SELECTOBJECT
        cmp word [hOldBmp], 0
        jne .sel
        mov [hOldBmp], ax
.sel:
        push ds
        pop es
        mov di, outBuf
        mov cx, [outSize]
        xor al, al
        cld
        rep stosb

        ; window: client = video size, title = file name
        mov ax, [bmpW]
        mov [rect+4], ax
        mov ax, [vidH]
        mov [rect+6], ax
        call outer_size
        push word [hWnd]
        PUSHI 0
        PUSHI 0
        PUSHI 0
        push cx
        push dx
        PUSHI SWP_NOMOVE_NOZORDER
        API SETWINDOWPOS
        mov si, fileName
        mov bx, si
.tl:    lodsb
        or al, al
        jz .tdone
        cmp al, '\'
        je .tset
        cmp al, ':'
        jne .tl
.tset:  mov bx, si
        jmp .tl
.tdone: push word [hWnd]
        push ds
        push bx
        API SETWINDOWTEXT
        push word [hWnd]
        PUSHI 0
        PUSHI 0
        PUSHI 1
        API INVALIDATERECT

        ; start playing from the first frame
        call rewind
        mov byte [fileOpen], 1
        clc
        ret

; build_lut: once, a 32 KB table RGB555 -> dither pattern offset, so a 16-bit
; colour costs one lookup in the decoder instead of three. CF set if no memory.
build_lut:
        cmp word [lutSeg], 0
        jne .ok
        PUSHI 0                         ; GMEM_FIXED
        PUSHI 0
        PUSHI 8000h                     ; 32768 bytes
        API GLOBALALLOC
        or ax, ax
        jz .fail
        mov [hLut], ax
        push ax
        API GLOBALLOCK
        mov [lutSeg], dx
        mov es, dx
        xor di, di
        cld
        xor dh, dh                      ; high byte
.hi:    mov al, dh
        mov bx, tabHi
        xlat
        mov dl, al
        xor si, si                      ; low byte
.lo:    mov ax, si
        mov bx, tabLo
        xlat
        add al, dl
        mov bx, tabLvl
        xlat
        stosb
        inc si
        cmp si, 256
        jb .lo
        inc dh
        cmp dh, 128
        jb .hi
.ok:    clc
        ret
.fail:  stc
        ret

; rewind: back to the first frame, clock restarted
rewind: mov ax, [moviStart]
        mov dx, [moviStart+2]
        xor bl, bl
        call fseek
        mov word [frameNo], 0
        mov word [behind], 0
        ; fall through
; resync: set the clock so that frame frameNo is due now
resync: API GETCURRENTTIME
        mov [lastLap], ax
        push dx
        push ax
        mov ax, [frameNo]
        call due
        mov cx, ax
        pop ax
        pop dx
        sub ax, cx
        sbb dx, 0
        mov [t0], ax
        mov [t0+2], dx
        ret

; due: AX = frame number -> AX = its time in ms from t0 (saturates at 65535)
due:    mul word [msx16]
        shr dx, 1
        rcr ax, 1
        shr dx, 1
        rcr ax, 1
        shr dx, 1
        rcr ax, 1
        shr dx, 1
        rcr ax, 1
        or dx, dx
        jz .x
        mov ax, 0FFFFh
.x:     ret

close_avi:
        mov byte [fileOpen], 0
        mov byte [shownAny], 0
        mov ax, [hFile]
        cmp ax, 0FFFFh
        je .x
        push ax
        API _LCLOSE
        mov word [hFile], 0FFFFh
.x:     ret

free_bmp:
        mov ax, [hBmp]
        or ax, ax
        jz .x
        push word [hMemDC]
        push word [hOldBmp]
        API SELECTOBJECT
        push word [hBmp]
        API DELETEOBJECT
        mov word [hBmp], 0
.x:     ret

free_gdi:
        call free_bmp
        mov ax, [hLut]
        or ax, ax
        jz .nolut
        push ax
        API GLOBALUNLOCK
        push word [hLut]
        API GLOBALFREE
        mov word [hLut], 0
        mov word [lutSeg], 0
.nolut:
        mov ax, [hMemDC]
        or ax, ax
        jz .x
        push ax
        API DELETEDC
        mov word [hMemDC], 0
.x:     ret

; ================================================================ playback
; next_frame: if the next frame is due, read and decode it; draw it unless
; we are behind (but never skip more than 3 draws in a row).
next_frame:
        API GETCURRENTTIME
        sub ax, [t0]
        sbb dx, [t0+2]
        or dx, dx
        jz .e16
        mov ax, 0FFFFh
.e16:   mov [elapsed], ax
        mov ax, [frameNo]
        call due
        cmp [elapsed], ax
        jb .ret                         ; not yet
        mov bx, tIdle
        call lap
.again1:
        call read_vchunk
        jc .eof
        push cx
        mov bx, tRead
        call lap
        pop cx
        jcxz .nodec                     ; empty chunk = repeat previous frame
        mov si, chunkBuf
        push bp
        call [decoderFn]
        pop bp
.nodec: mov bx, tDecode
        call lap
        inc word [frameNo]
        inc word [decoded]
        mov ax, [frameNo]
        call due
        cmp [elapsed], ax
        jb .show                        ; next frame not due yet: time to draw
        inc word [behind]               ; behind: decode the next one right away,
        cmp word [behind], 4            ; without a trip through the message loop,
        jb .again1                      ; but draw at least every 4th frame
.show:  mov word [behind], 0
        call present
        mov bx, tDraw
        call lap
.ret:   ret
.eof:   inc word [loops]
        cmp byte [testMode], 0
        je .again
        push word [hWnd]                ; test run: one pass, then quit
        API DESTROYWINDOW
        ret
.again: call rewind
        ret

; lap (test mode only): add the ms since the previous lap to the word at BX
lap:    cmp byte [testMode], 0
        je .x
        push bx
        API GETCURRENTTIME
        pop bx
        mov dx, ax
        sub ax, [lastLap]
        mov [lastLap], dx
        add [bx], ax
.x:     ret

; present: decoded frame -> bitmap -> window
present:
        push word [hBmp]
        PUSHI 0
        push word [outSize]
        push ds
        PUSHI outBuf
        API SETBITMAPBITS
        push word [hWnd]
        API GETDC
        push si
        mov si, ax
        call blit
        push word [hWnd]
        push si
        API RELEASEDC
        pop si
        mov byte [shownAny], 1
        inc word [shown]
        ret

; blit: BitBlt the memory bitmap to the DC in SI
blit:   push si
        PUSHI 0
        PUSHI 0
        push word [bmpW]
        push word [vidH]
        push word [hMemDC]
        PUSHI 0
        PUSHI 0
        PUSHI SRCCOPY_HI
        PUSHI SRCCOPY_LO
        API BITBLT
        ret

; read_vchunk: next video chunk of the movi list into chunkBuf.
; CF set at the end of the movie; else CX = bytes (0 = empty or oversized frame).
read_vchunk:
.next:  mov ax, [pos]
        mov dx, [pos+2]
        cmp dx, [moviEnd+2]
        ja .end
        jb .go
        cmp ax, [moviEnd]
        jae .end
.go:    mov di, ckhdr
        mov cx, 8
        call fread
        cmp ax, 8
        jne .end
        cmp word [ckhdr], 'LI'
        jne .notlist
        cmp word [ckhdr+2], 'ST'
        jne .notlist
        mov di, ckhdr+8                 ; 'rec ' list: just step inside
        mov cx, 4
        call fread
        jmp .next
.notlist:
        mov ax, [ckhdr+4]
        mov dx, [ckhdr+6]
        mov bx, [ckhdr]
        cmp bx, [vidId]
        jne .skip
        mov bx, [ckhdr+2]
        cmp bx, 'dc'
        je .vid
        cmp bx, 'db'
        jne .skip
.vid:   or dx, dx
        jnz .drop
        cmp ax, CHUNKMAX
        ja .drop
        mov cx, ax
        push ax
        mov di, chunkBuf
        call fread
        pop cx
        test cl, 1
        jz .even
        push cx
        mov ax, 1
        xor dx, dx
        call fskip
        pop cx
.even:  clc
        ret
.drop:  call skip_padded
        xor cx, cx
        clc
        ret
.skip:  call skip_padded
        jmp .next
.end:   stc
        ret

; ================================================================ decoder
; Microsoft Video 1 frame at SI -> outBuf (1 bit, 2x wide, rows of S bytes).
; Blocks come bottom row first, left to right; each 4x4 block is one output
; byte wide and 4 rows tall (rows at DI, DI-S, DI-2S, DI-3S). Skipped blocks
; keep the previous frame's pixels. A colour becomes a dither pattern offset
; (level * 4) into pat; the 4 bytes there are the block's 4 rows.
;
; Hot loop registers: SI stream, DI block (bottom row), CX blocks left in row.
; BP and BX are scratch here (BP addresses SS, which is DGROUP like DS).
; Trailing junk past the chunk can only produce junk pixels: the loop is
; bounded by the block count and only writes inside outBuf.

; colour -> pattern offset in AL (clobbers BX, AH)
%macro LVL8 0
        mov bx, palLvl
        xlat
%endmacro
%macro LVL16 0                          ; AX = RGB555, ES = lut (see build_lut)
        and ah, 7Fh
        mov bx, ax
        mov al, [es:bx]
%endmacro

; write the 4 rows of a 2-colour block: flag 1 -> pattern at BP+pat,
; flag 0 -> pattern at SI+pat, flags in DX (DL = rows 0,1; DH = rows 2,3)
%macro ROWS2 1                          ; %1 = stride
        mov al, dl
        mov bx, expandLo
        xlat
        mov ah, [bp+pat]
        xor ah, [si+pat]
        and ah, al
        xor ah, [si+pat]
        mov [di], ah
        mov al, dl
        mov bx, expandHi
        xlat
        mov ah, [bp+pat+1]
        xor ah, [si+pat+1]
        and ah, al
        xor ah, [si+pat+1]
        mov [di-%1], ah
        mov al, dh
        mov bx, expandLo
        xlat
        mov ah, [bp+pat+2]
        xor ah, [si+pat+2]
        and ah, al
        xor ah, [si+pat+2]
        mov [di-2*%1], ah
        mov al, dh
        mov bx, expandHi
        xlat
        mov ah, [bp+pat+3]
        xor ah, [si+pat+3]
        and ah, al
        xor ah, [si+pat+3]
        mov [di-3*%1], ah
%endmacro

; one row of the combined 8-colour patterns: left half from lv[q]/lv[q+1],
; right half from lv[q+2]/lv[q+3]
%macro QROW 2                           ; %1 = row, %2 = q
        mov bl, [lv+%2]
        mov al, [pat+bx+%1]
        and al, 0F0h
        mov bl, [lv+%2+2]
        mov ah, [pat+bx+%1]
        and ah, 0Fh
        or al, ah
        mov [tmpA+%1], al
        mov bl, [lv+%2+1]
        mov al, [pat+bx+%1]
        and al, 0F0h
        mov bl, [lv+%2+3]
        mov ah, [pat+bx+%1]
        and ah, 0Fh
        or al, ah
        mov [tmpB+%1], al
%endmacro

%macro DECODER 2                        ; %1 = 8 or 16 bits, %2 = stride
dec%1_%2:
%if %1 == 16
        mov es, [lutSeg]
%endif
        cld
        mov ax, [blocksHigh]
        mov [byLeft], ax
        mov di, [outBottom]
        mov [rowBase], di
        mov cx, [blocksWide]
.blk:   lodsw                           ; AL = byte_a, AH = byte_b
        mov bl, ah
        and bl, 0FCh
        cmp bl, 84h
        je .skip
%if %1 == 8
        cmp ah, 80h
        jb .two
        cmp ah, 90h
        jae .eight
        LVL8                            ; 1 colour: byte_a
%else
        cmp ah, 80h
        jb .multi
        LVL16                           ; 1 colour: the word itself
%endif
        xor ah, ah
        mov bx, ax
        mov ax, [pat+bx]
        mov [di], al
        mov [di-%2], ah
        mov ax, [pat+bx+2]
        mov [di-2*%2], al
        mov [di-3*%2], ah
.next:  inc di
        loop .blk
.rowend:
        dec word [byLeft]
        jz .done
        mov di, [rowBase]
        sub di, 4*%2
        mov [rowBase], di
        mov cx, [blocksWide]
        jmp .blk

.skip:  sub ah, 84h                     ; skip AX blocks (this one included)
        jz .skz
.skr:   cmp ax, cx
        jb .skin
        sub ax, cx                      ; rest of this row
        dec word [byLeft]
        jz .done
        mov di, [rowBase]
        sub di, 4*%2
        mov [rowBase], di
        mov cx, [blocksWide]
        or ax, ax
        jnz .skr
        jmp .blk
.skz:   or al, al                       ; a skip of 0 ends the frame
        jnz .skr
        jmp .done
.skin:  add di, ax
        sub cx, ax
        jnz .blk
        jmp .rowend

%if %1 == 8
.two:   mov dx, ax                      ; flags
        lodsb
        LVL8
        xor ah, ah
        mov bp, ax                      ; flag 1: first colour
        lodsb
        LVL8
        xor ah, ah
        push si
        mov si, ax
        ROWS2 %2
        pop si
        jmp .next
.eight: mov dx, ax                      ; 8 colours, 2 per quadrant
        mov bx, palLvl
%assign k 0
%rep 8
        lodsb
        xlat
        mov [lv+k], al
%assign k k+1
%endrep
%else
.multi: mov dx, ax                      ; flags
        lodsw
        test ah, 80h
        jnz .eight
        LVL16
        xor ah, ah
        mov bp, ax                      ; flag 1: first colour
        lodsw
        LVL16
        xor ah, ah
        push si
        mov si, ax
        ROWS2 %2
        pop si
        jmp .next
.eight: LVL16                           ; 8 colours (flag in bit 15 of the first)
        mov [lv], al
%assign k 1
%rep 7
        lodsw
        LVL16
        mov [lv+k], al
%assign k k+1
%endrep
%endif
        xor bh, bh
        QROW 0, 0
        QROW 1, 0
        QROW 2, 4
        QROW 3, 4
        mov bp, tmpA - pat
        push si
        mov si, tmpB - pat
        ROWS2 %2
        pop si
        jmp .next

.done:  ret
%endmacro

        DECODER 8, 40
        DECODER 8, 80
        DECODER 16, 40
        DECODER 16, 80

; ================================================================ log (test mode)
; RICK.LOG next to the exe: "frames=N shown=N ms=N"
write_log:
        push ds
        pop es
        cld
        mov si, exePath
        mov di, logPath
        mov cx, [exeNameAt]
        sub cx, si
        rep movsb
        mov si, logName
        call strcpy
        dec di
        mov [logNameEnd], di            ; -> zero after "RICK.LOG"
        mov di, logBuf
        mov si, sFrames
        call puts
        mov ax, [decoded]
        call putu
        mov si, sShown
        call puts
        mov ax, [shown]
        call putu
        mov si, sMs
        call puts
        API GETCURRENTTIME
        sub ax, [tStart]
        call putu
        mov si, sRead
        call puts
        mov ax, [tRead]
        call putu
        mov si, sDecode
        call puts
        mov ax, [tDecode]
        call putu
        mov si, sDraw
        call puts
        mov ax, [tDraw]
        call putu
        mov si, sIdle
        call puts
        mov ax, [tIdle]
        call putu
        mov ax, 0A0Dh
        stosw
        sub di, logBuf
        mov [logLen], di

        push ds
        PUSHI logPath
        PUSHI 0
        API _LCREAT
        cmp ax, 0FFFFh
        je .x
        mov si, ax
        push ax
        push ds
        PUSHI logBuf
        push word [logLen]
        API _LWRITE
        push si
        API _LCLOSE
        ; last decoded frame -> RICK.FRM
        mov di, [logNameEnd]
        mov word [di-3], 'FR'
        mov byte [di-1], 'M'
        push ds
        PUSHI logPath
        PUSHI 0
        API _LCREAT
        cmp ax, 0FFFFh
        je .x
        mov si, ax
        push ax
        push ds
        PUSHI outBuf
        push word [outSize]
        API _LWRITE
        push si
        API _LCLOSE
.x:     ret

puts:   lodsb                           ; zero-terminated DS:SI -> ES:DI
        or al, al
        jz .e
        stosb
        jmp puts
.e:     ret

putu:   mov bx, 10                      ; AX as unsigned decimal -> ES:DI
        xor cx, cx
.d:     xor dx, dx
        div bx
        push dx
        inc cx
        or ax, ax
        jnz .d
.o:     pop ax
        add al, '0'
        stosb
        loop .o
        ret

; ================================================================ WndProc
; LONG FAR PASCAL WndProc(HWND, WORD msg, WORD wParam, LONG lParam)
WndProc:
        mov ax, ss                      ; our DGROUP (callbacks run on our stack)
        inc bp                          ; real-mode far frame marker
        push bp
        mov bp, sp
        push ds
        mov ds, ax
        push si
        push di

        mov ax, [bp+12]
        cmp ax, WM_PAINT
        je .paint
        cmp ax, WM_COMMAND
        je .cmd
        cmp ax, WM_DESTROY
        je .destroy
.def:   push word [bp+14]
        push word [bp+12]
        push word [bp+10]
        push word [bp+8]
        push word [bp+6]
        API DEFWINDOWPROC
        jmp .ret

.paint: push word [bp+14]
        push ds
        PUSHI ps
        API BEGINPAINT
        mov si, ax
        cmp byte [shownAny], 0
        je .nopaint
        call blit
.nopaint:
        push word [bp+14]
        push ds
        PUSHI ps
        API ENDPAINT
        jmp .zero

.cmd:   mov ax, [bp+10]
        cmp ax, IDM_OPEN
        je .open
        cmp ax, IDM_EXIT
        je .exit
        cmp ax, IDM_ABOUT
        jne .def
        push word [bp+14]
        push ds
        PUSHI aboutText
        push ds
        PUSHI aboutTitle
        PUSHI MB_ICONINFO
        API MESSAGEBOX
        mov byte [needResync], 1
        jmp .zero
.open:  push word [hInst]
        PUSHI 0
        PUSHI IDD_OPEN                  ; MAKEINTRESOURCE(1)
        push word [bp+14]
        push cs
        PUSHI DlgProc
        API DIALOGBOX
        mov byte [needResync], 1
        cmp ax, 1
        jne .zero
        push ds
        pop es
        cld
        mov si, selBuf
        mov di, fileName
        call strcpy
        call open_avi
        jmp .zero
.exit:  push word [bp+14]
        API DESTROYWINDOW
        jmp .zero

.destroy:
        mov word [hWnd], 0
        PUSHI 0
        API POSTQUITMESSAGE
.zero:  xor ax, ax
        xor dx, dx
.ret:   pop di
        pop si
        sub bp, 2
        mov sp, bp
        pop ds
        pop bp
        dec bp
        retf 10

; ================================================================ Open dialog
; Windows 3.0 has no common dialogs, so this is the classic 3.0-style one:
; a file name box plus one list of *.AVI files, [directories] and [-drives-].
; BOOL FAR PASCAL DlgProc(HWND, WORD msg, WORD wParam, LONG lParam)
DlgProc:
        mov ax, ss
        inc bp
        push bp
        mov bp, sp
        push ds
        mov ds, ax
        push si
        push di

        mov ax, [bp+14]
        mov [hDlg], ax
        mov ax, [bp+12]
        cmp ax, WM_INITDIALOG
        je .init
        cmp ax, WM_COMMAND
        je .cmd
.false: xor ax, ax
        jmp .ret

.init:  push ds
        pop es
        cld
        mov si, defSpec
        mov di, specBuf
        call strcpy
        call dirlist
        call spec_to_name
        jmp .true

.cmd:   mov ax, [bp+10]
        cmp ax, IDC_LIST
        je .list
        cmp ax, 1                       ; IDOK
        je .ok
        cmp ax, 2                       ; IDCANCEL
        jne .false
        push word [hDlg]
        PUSHI 0
        API ENDDIALOG
        jmp .true

.list:  mov ax, [bp+8]                  ; notification code
        cmp ax, 2                       ; LBN_DBLCLK
        je .ok
        cmp ax, 1                       ; LBN_SELCHANGE
        jne .true
        push word [hDlg]
        push ds
        PUSHI selBuf
        PUSHI IDC_LIST
        API DLGDIRSELECT
        or ax, ax
        jz .setname
        mov di, selBuf                  ; a directory or drive: show dir\*.AVI
        call append_spec
.setname:
        push word [hDlg]
        PUSHI IDC_NAME
        push ds
        PUSHI selBuf
        API SETDLGITEMTEXT
        jmp .true

.ok:    push word [hDlg]
        PUSHI IDC_NAME
        push ds
        PUSHI selBuf
        PUSHI 128
        API GETDLGITEMTEXT
        or ax, ax
        jz .true
        mov si, selBuf                  ; wildcards or a trailing \ or : = change directory
        xor bl, bl
.scan:  lodsb
        or al, al
        jz .scanned
        mov bl, al
        cmp al, '*'
        je .wild
        cmp al, '?'
        je .wild
        jmp .scan
.scanned:
        cmp bl, '\'
        je .dir
        cmp bl, ':'
        je .dir
        push word [hDlg]                ; a file: done
        PUSHI 1
        API ENDDIALOG
        jmp .true
.dir:   mov di, selBuf
        call append_spec
.wild:  push ds
        pop es
        cld
        mov si, selBuf
        mov di, specBuf
        call strcpy
        call dirlist
        or ax, ax
        jz .true                        ; bad path: leave it for the user to fix
        call spec_to_name
.true:  mov ax, 1
.ret:   pop di
        pop si
        sub bp, 2
        mov sp, bp
        pop ds
        pop bp
        dec bp
        retf 10

; dirlist: fill the list from specBuf (DlgDirList changes the current
; directory and leaves only the file pattern in specBuf). AX = success.
dirlist:
        push word [hDlg]
        push ds
        PUSHI specBuf
        PUSHI IDC_LIST
        PUSHI IDC_PATH
        PUSHI DDL_DIRS_DRIVES
        API DLGDIRLIST
        ret

spec_to_name:
        push word [hDlg]
        PUSHI IDC_NAME
        push ds
        PUSHI specBuf
        API SETDLGITEMTEXT
        push word [hDlg]                ; select it, so typing replaces it
        PUSHI IDC_NAME
        PUSHI 0401h                     ; EM_SETSEL
        PUSHI 0
        PUSHI 7FFFh                     ; end
        PUSHI 0                         ; start
        API SENDDLGITEMMESSAGE
        ret

; append_spec: append "*.AVI" to the string at DI
append_spec:
        push ds
        pop es
        cld
        xor al, al
        mov cx, 0FFFFh
        repne scasb
        dec di
        mov si, defSpec
        call strcpy
        ret

code_end:

; ================================================================ data (DGROUP)
section .data vstart=0 follows=.text align=16
        times 16 db 0                   ; reserved: InitTask fills in stack/heap info
hInst   dw 0
hPrev   dw 0
cmdShow dw 0
hWnd    dw 0
hDlg    dw 0
hMemDC  dw 0
hBmp    dw 0
hOldBmp dw 0
hFile   dw 0FFFFh
exeNameAt dw 0
logLen  dw 0
logNameEnd dw 0
lastLap dw 0
tRead   dw 0
tDecode dw 0
tDraw   dw 0
tIdle   dw 0
; playback state
frameNo dw 0
decoded dw 0
shown   dw 0
behind  dw 0
loops   dw 0
elapsed dw 0
msx16   dw 0
t0      dd 0
tStart  dd 0
pos     dd 0
csz     dd 0
moviStart dd 0
moviEnd dd 0
usPerFrame dd 0
; video geometry
vidH    dw 0
bmpW    dw 0
blocksWide dw 0
blocksHigh dw 0
stride  dw 0
bitmapW dw 0
decoderFn dw 0
hLut    dw 0
lutSeg  dw 0
outSize dw 0
outBottom dw 0
vidId   dw 0
; decoder scratch
rowBase dw 0
byLeft  dw 0
lv      times 8 db 0
tmpA    times 4 db 0
tmpB    times 4 db 0
; flags
fileOpen db 0
shownAny db 0
needResync db 0
testMode db 0
depth16 db 0
vidStream db 0
strCount db 0
pendingVid db 0
gotFmt  db 0
        db 0
; Windows structures
rect    dw 0, 0, 0, 0
wc      dw 0                            ; style
        dd 0                            ; lpfnWndProc
        dw 0, 0                         ; cbClsExtra, cbWndExtra
        dw 0, 0, 0, 0                   ; hInstance, hIcon, hCursor, hbrBackground
        dd 0                            ; lpszMenuName
        dd 0                            ; lpszClassName
msg     times 18 db 0
ps      times 32 db 0
ckhdr   times 12 db 0
tmp     times 56 db 0
FMTSIZE equ 40 + 24 + 1024              ; BITMAPINFOHEADER (+slack) + 256-colour palette
fmt     times FMTSIZE db 0
palLvl  times 256 db 0
; strings
className db "RickPlay", 0
appName db "RickPlay", 0
aboutTitle db "About RickPlay", 0
aboutText db "RickPlay 1.0", 10, 10
        db "AVI player for Windows 3.0 real mode.", 10
        db "Plays Microsoft Video 1 (8 and 16-bit),", 10
        db "dithered for CGA. No sound.", 0
defSpec db "*.AVI", 0
logName db "RICK.LOG", 0
errOpen db "Cannot open the file.", 0
errFmt  db "This is not a valid AVI file.", 0
errNoVid db "This AVI file has no video stream.", 0
errCodec db "Unsupported video: needs Microsoft Video 1, 8 or 16-bit, up to 320x240.", 0
errWnd  db "Cannot create the window.", 0
errMem  db "Not enough memory for the video bitmap.", 0
sFrames db "frames=", 0
sShown  db " shown=", 0
sMs     db " ms=", 0
sRead   db " read=", 0
sDecode db " decode=", 0
sDraw   db " draw=", 0
sIdle   db " other=", 0

; buffers with content that must start as zero
argName times 80 db 0
fileName times 144 db 0
selBuf  times 144 db 0
specBuf times 144 db 0
exePath times 144 db 0
logPath times 144 db 0
logBuf  times 64 db 0
%include "tables.inc"
data_init_end:

; uninitialized buffers: not stored in the EXE, only allocated (see mkne.py)
absolute data_init_end
        alignb 2
chunkBuf resb CHUNKMAX + 32
outBuf  resb OUTMAX
bss_end:
