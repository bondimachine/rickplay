#!/bin/sh
# Build build/RICKPLAY.EXE (needs python3 and nasm)
set -e
cd "$(dirname "$0")"
mkdir -p build
python3 -I tools/mkne.py inc src/imports.inc
python3 -I tools/gentables.py src/tables.inc
nasm -f bin -I src/ -o build/rickplay.bin src/rickplay.asm
python3 -I tools/mkne.py link build/rickplay.bin build/RICKPLAY.EXE
