#!/usr/bin/env python3
"""Expand a file compressed with Microsoft COMPRESS.EXE (SZDD, e.g. WNDSURF1.AV_).

  expand.py <input> <output>
"""
import struct, sys

def expand(data):
    if data[:8] != b"SZDD\x88\xf0\x27\x33":
        raise ValueError("not an SZDD (COMPRESS.EXE) file")
    size = struct.unpack_from("<I", data, 10)[0]
    p = 14
    win = bytearray(b" " * 4096)
    wp = 4096 - 16
    out = bytearray()
    while p < len(data) and len(out) < size:
        ctl = data[p]; p += 1
        for bit in range(8):
            if p >= len(data):
                break
            if ctl & (1 << bit):            # literal byte
                c = data[p]; p += 1
                out.append(c); win[wp] = c; wp = (wp + 1) & 4095
            else:                           # 12-bit window offset, 4-bit length (+3)
                if p + 1 >= len(data):
                    break
                lo, hi = data[p], data[p + 1]; p += 2
                off = lo | ((hi & 0xF0) << 4)
                for i in range((hi & 0x0F) + 3):
                    c = win[(off + i) & 4095]
                    out.append(c); win[wp] = c; wp = (wp + 1) & 4095
    if len(out) < size:
        raise ValueError("truncated input")
    return bytes(out[:size])

if __name__ == "__main__":
    out = expand(open(sys.argv[1], "rb").read())
    open(sys.argv[2], "wb").write(out)
    print(f"{sys.argv[2]}: {len(out)} bytes")
