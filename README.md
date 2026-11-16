# RickPlay

An AVI player for **Windows 3.0 in real mode**, for an 8088 PC with CGA.

Video for Windows needs Windows 3.1 and a 386 or later, so it can't run on that hardware. RickPlay is a small player
written from scratch in 8086 assembly. It plays standard `.AVI` files whose video is
**Microsoft Video 1** (`CRAM`/`MSVC`), the codec of the original Video for Windows samples:

- 8-bit palette (e.g. `WNDSURF1.AVI` from the VfW 1.0 disk)
- 16-bit RGB555 (e.g. `rickroll.avi`)
- frame size up to 320×240, with width and height multiples of 4

Frames are decoded straight to dithered black and white. Each source pixel is doubled
horizontally, because CGA pixels in the 640×200 mono mode are tall and narrow. Playback
follows the clock: on a slow machine every frame is still decoded (Video 1 frames build on
the previous one), but fewer of them are drawn. Sound is not played.

## Use

Copy `build/RICKPLAY.EXE` to the PC and run it from Windows 3.0, in any mode, including `win /r`.

- **File ▸ Open…** chooses a file. Windows 3.0 has no common dialogs, so this is a classic
  3.0-style Open box: type a name, or pick from the list of `*.AVI` files,
  `[directories]` and `[-drives-]`. Typing a pattern such as `*.*` or a folder such as `\VIDEOS\`
  lists that instead.
- On the command line: `RICKPLAY.EXE C:\VIDEOS\RICKROLL.AVI`. A bare name is looked for in the
  current directory, then next to `RICKPLAY.EXE`.
- The video loops until you close the window. Minimizing the window pauses it.
- `/T` is for testing: it plays one pass, writes `RICK.LOG` next to the exe, and exits Windows.
  The log has frames decoded and drawn, total ms, and ms spent reading, decoding, drawing and
  elsewhere. A `RICK.FRM` file holds the last decoded frame.

## Speed

Measured in DOSBox-X with a 4.77 MHz 8088, CGA and an XT-speed hard disk (~90 KB/s), so the
numbers are approximate:

- `rickroll.avi` (160×120, 16-bit, 15 fps): about 46 ms to decode a frame, 60 ms per draw and
  15 ms to read it. That's close to real time, but it draws only about every 4th frame (~4 fps on screen).
- `WNDSURF1.AVI` (156×120, 8-bit): limited by the disk. It needs ~196 KB/s, about twice what an
  XT hard disk delivers, so it plays at under half of real speed whatever the CPU does.
- Keep the client area byte-aligned (the window class asks for it). An unaligned BitBlt on
  CGA was ~5× slower.
- The first 16-bit file you open builds a 32 KB colour table (about 1 s on an 8088). It is
  reused for later files.

Files from the VfW disks ending in `_` (such as `WNDSURF1.AV_`) are compressed with
COMPRESS.EXE. Expand them first, with DOS `EXPAND` or `python3 tools/expand.py WNDSURF1.AV_ WNDSURF1.AVI`.

## Build

Needs `python3` and `nasm`:

```bash
./build.sh
```

- `src/rickplay.asm`: the whole program: startup, window, menu commands, Open dialog,
  AVI parser and Video 1 decoder. `cpu 8086` makes NASM reject anything an 8088 can't run.
- `tools/mkne.py`: a tiny linker that wraps NASM's flat output into a Windows 3.0 NE
  executable. It writes the import table, the menu and dialog resources, and the header
  (8086, not protected-mode-only, expects Windows 3.00). Both segments are FIXED, so the
  real-mode kernel never moves them.
- `tools/gentables.py`: the dither patterns and colour→grey lookup tables.
- `tools/refcheck.py`: checks a `/T` run. It compares `RICK.FRM` bit for bit with ffmpeg's
  decode of the same AVI, pushed through the same tables.
- `tools/expand.py`: expands COMPRESS.EXE (`SZDD`) files. Only needed for the helper step
  above; the player itself reads plain `.AVI`.
