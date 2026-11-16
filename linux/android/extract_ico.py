import struct, sys
d = open(sys.argv[1], 'rb').read()
pe = struct.unpack_from('<I', d, 0x3c)[0]
nsec = struct.unpack_from('<H', d, pe + 6)[0]
opt = struct.unpack_from('<H', d, pe + 20)[0]
magic = struct.unpack_from('<H', d, pe + 24)[0]
ddoff = pe + 24 + (96 if magic == 0x10b else 112)
rva, size = struct.unpack_from('<II', d, ddoff + 16)   # resource directory
secs = []
for i in range(nsec):
    o = pe + 24 + opt + 40 * i
    vs, va, rs, rp = struct.unpack_from('<IIII', d, o + 8)
    secs.append((va, max(vs, rs), rp))
def off(r):
    for va, sz, rp in secs:
        if va <= r < va + sz: return r - va + rp
    raise ValueError(hex(r))
base = off(rva)
def entries(o):
    n = struct.unpack_from('<HH', d, o + 12); cnt = n[0] + n[1]
    for i in range(cnt):
        nid, tgt = struct.unpack_from('<II', d, o + 16 + 8 * i)
        yield nid, (tgt & 0x7fffffff), bool(tgt & 0x80000000)
def leaf(o):   # first data entry under a subdirectory chain
    while True:
        nid, tgt, sub = next(entries(o))
        if not sub:
            r, s = struct.unpack_from('<II', d, base + tgt); return d[off(r):off(r) + s]
        o = base + tgt
types = {nid: base + tgt for nid, tgt, sub in entries(base) if sub}
icons = {}
for nid, tgt, sub in entries(types[3]):
    icons[nid] = leaf(base + tgt)
res = []
grp = None
for nid, tgt, sub in entries(types[14]):
    grp = leaf(base + tgt); break
_, _, count = struct.unpack_from('<HHH', grp, 0)
out = [struct.pack('<HHH', 0, 1, count)]
imgs = []
pos = 6 + 16 * count
for i in range(count):
    w, h, cc, r, pl, bpp, size, iid = struct.unpack_from('<BBBBHHIH', grp, 6 + 14 * i)
    data = icons[iid]
    out.append(struct.pack('<BBBBHHII', w, h, cc, r, pl, bpp, len(data), pos))
    imgs.append(data); pos += len(data)
open(sys.argv[2], 'wb').write(b''.join(out + imgs))
print(count, 'obrazów')
