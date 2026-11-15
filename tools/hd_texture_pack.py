# The redraw results as the game's texture pack (recomp/runtime/hd_textures.c reads it).
#   py -3 tools/hd_texture_pack.py [--root D:/upscale/NFS4] [--out DIR] [TRACK ...]
#       every <root>/output/<TRACK>/<key>.png (tools/redraw_fit.py) -> DIR/hdtex/<game key>.rgba
#   py -3 tools/hd_texture_pack.py --test [--root R] [--out DIR] TRACK
#       a check pack instead: every picture of TRACK 4x enlarged with a magenta frame, so a run shows at a glance
#       which textures were replaced (input/ from tools/redraw_export.py)
# DIR defaults to <root>/pack. The game looks in <mods>/hdtex and in hdtex beside nfs4.exe: copy DIR/hdtex into
# the device's NFS4 › mods folder (Files app), or put it beside nfs4.exe in a PC overlay so "PC에서 받기" brings it.
# The key is worked out from the original picture (input/), the way the game works it out from what it uploads:
# FNV-1a over the size and every texel cut to 4 bits a channel plus 1-bit alpha (checked against a race's dump,
# NFS4_DUMP_TEXTURES, on the test host: every track texture of the race matched).
import sys, json, struct, pathlib
import numpy as np
from PIL import Image

DEFAULT_ROOT = 'D:/upscale/NFS4'


def game_key(img):
    a = np.asarray(img.convert('RGBA')).astype(np.uint32)
    h, w = a.shape[:2]
    b0 = ((a[..., 0] >> 4) | ((a[..., 1] >> 4) << 4)).astype(np.uint8).ravel()
    b1 = ((a[..., 2] >> 4) | ((a[..., 3] >> 7) << 4)).astype(np.uint8).ravel()
    seq = bytes([w & 255, w >> 8, h & 255, h >> 8]) + np.stack([b0, b1], 1).tobytes()
    k, mask = 1469598103934665603, (1 << 64) - 1
    for c in seq:
        k = ((k ^ c) * 1099511628211) & mask
    return '%016x' % k


def write(path, img):
    img = img.convert('RGBA')
    path.write_bytes(struct.pack('<4sII', b'HDT1', img.width, img.height) + img.tobytes())


def main():
    args = sys.argv[1:]
    def option(flag, default):
        if flag in args:
            i = args.index(flag); v = args[i + 1]; del args[i:i + 2]; return v
        return default
    test = '--test' in args
    if test:
        args.remove('--test')
    root = pathlib.Path(option('--root', DEFAULT_ROOT))
    out = pathlib.Path(option('--out', str(root / 'pack'))) / 'hdtex'
    out.mkdir(parents=True, exist_ok=True)
    tracks = [t.upper() for t in args]
    index = json.loads((root / 'input' / 'index.json').read_text(encoding='utf-8'))
    done, size, seen = 0, 0, set()
    for key, e in sorted(index.items()):
        if tracks and e['track'].upper() not in tracks:
            continue
        orig_path = root / 'input' / (key + '.png')
        if test:
            if min(e['w'], e['h']) < 8:
                continue
            orig = Image.open(orig_path).convert('RGBA')
            img = orig.resize((orig.width * 4, orig.height * 4), Image.NEAREST)
            a = np.asarray(img).copy()
            a[:4, :, :3] = a[-4:, :, :3] = a[:, :4, :3] = a[:, -4:, :3] = (255, 0, 255)
            img = Image.fromarray(a, 'RGBA')
        else:
            got = root / 'output' / (key + '.png')
            if not got.exists():
                continue
            orig = Image.open(orig_path).convert('RGBA')
            img = Image.open(got).convert('RGBA')
            if img.width * orig.height != img.height * orig.width or img.width < orig.width:
                print('%s: %dx%d is not the shape of %dx%d, left out' % (key, img.width, img.height, orig.width, orig.height))
                continue
        k = game_key(orig)
        if k in seen:
            continue
        seen.add(k)
        dst = out / (k + '.rgba')
        write(dst, img)
        done += 1
        size += dst.stat().st_size
    print('%s: %d textures, %.1f MB' % (out, done, size / 1e6))


if __name__ == '__main__':
    main()
