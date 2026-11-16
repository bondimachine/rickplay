#!/usr/bin/env python3
"""Check RICK.FRM (the player's last decoded frame, from a /T run) against an
independent reference: ffmpeg's own Microsoft Video 1 decode, pushed through
the same grey/dither tables.  refcheck.py <file.avi> <RICK.FRM> [preview.png]"""
import re, struct, subprocess, sys

def tables():
    t = {}
    cur = None
    for line in open(__file__.replace("tools/refcheck.py", "src/tables.inc")):
        m = re.match(r"(\w+):", line)
        if m:
            cur = t.setdefault(m.group(1), [])
        elif "db" in line:
            cur += [int(v) for v in line.split("db")[1].split(",")]
    return t

def main(avi, frm, png=None):
    T = tables()
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-count_frames",
                            "-show_entries", "stream=width,height,pix_fmt,nb_read_frames",
                            "-of", "csv=p=0", avi], capture_output=True, text=True, check=True).stdout
    w, h, pix, n = probe.strip().split(",")
    w, h, n = int(w), int(h), int(n)
    fmt = "pal8" if pix == "pal8" else "rgb555le"
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", avi, "-map", "0:v:0", "-fps_mode", "passthrough",
                          "-f", "rawvideo", "-pix_fmt", fmt, "-"], capture_output=True, check=True).stdout
    fsz = w * h * (1 if fmt == "pal8" else 2) + (1024 if fmt == "pal8" else 0)
    last = raw[(len(raw) // fsz - 1) * fsz:][:fsz]
    def level(x, y):
        if fmt == "pal8":
            i = last[y * w + x]
            b, g, r = last[w * h + 4 * i], last[w * h + 4 * i + 1], last[w * h + 4 * i + 2]   # ffmpeg pal: ARGB LE = B,G,R,A
            grey = (2 * r + 5 * g + b) >> 3
        else:
            v = last[2 * (y * w + x)] | last[2 * (y * w + x) + 1] << 8
            grey = T["tabLo"][v & 255] + T["tabHi"][v >> 8]
        return T["tabLvl"][grey]
    stride = 40 if w // 4 <= 40 else 80
    ref = bytearray(stride * h)
    for y in range(h):
        r = 3 - (y & 3)                       # pattern row: decoder counts rows bottom-up per block
        for x in range(w):
            p = T["pat"][level(x, y) + r]
            bits = (p >> (6 - 2 * (x & 3))) & 3
            ref[y * stride + x // 4] |= bits << (6 - 2 * (x & 3))
    got = open(frm, "rb").read()
    diff = sum(bin(a ^ b).count("1") for a, b in zip(ref, got))
    print(f"{avi}: {w}x{h} {fmt}, {len(raw)//fsz} frames; RICK.FRM {len(got)} bytes, "
          f"expected {len(ref)}; differing pixels: {diff}")
    if png:
        pbm = b"P4\n%d %d\n" % (stride * 8, h * 2 + 4) + bytes(255 - b for b in got) + b"\0" * stride * 4 + bytes(255 - b for b in ref)
        open(png + ".pbm", "wb").write(pbm)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", png + ".pbm", "-vf",
                        "scale=iw:ih*2.4:flags=neighbor", png], check=True)
    return diff

if __name__ == "__main__":
    sys.exit(1 if main(*sys.argv[1:]) else 0)
