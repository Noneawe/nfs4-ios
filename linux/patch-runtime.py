"""Apply Linux renderer fixes to the pinned upstream checkout."""
from pathlib import Path
import sys


def patch(root):
    path = root / "recomp/runtime/hle_glide.c"
    text = path.read_text()
    changes = (
        ("int format, large_lod, aspect;", "int format, large_lod, small_lod, aspect;", 1),
        ("x->large_lod == t->large_lod && x->aspect",
         "x->large_lod == t->large_lod && x->small_lod == t->small_lod && x->aspect", 2),
        ("e->large_lod = t->large_lod;", "e->large_lod = t->large_lod; e->small_lod = t->small_lod;", 1),
        ("e->id=gpu_texture_create(gw,gh,1);",
         "e->id=gpu_texture_create(gw,gh,t->small_lod < t->large_lod);", 1),
        ("void hle_glide_fix_config(uint8_t *buf,uint32_t off,uint32_t n){(void)buf;(void)off;(void)n;}",
         """void hle_glide_fix_config(uint8_t *buf,uint32_t off,uint32_t n) {
    /* The handheld profile selects the engine's real 640x480 mode. Only the
     * config bytes read by the guest change; the PC source stays untouched. */
    if (!getenv("NFS4_HANDHELD")) return;
    const uint32_t width = 640;
    for (uint32_t i = 0; i < 4; ++i) {
        uint32_t pos = 0x120 + i;
        if (pos >= off && pos - off < n) buf[pos - off] = (uint8_t)(width >> (8 * i));
    }
}""", 1),
    )
    for old, new, count in changes:
        if text.count(new) == count:
            continue
        if text.count(old) != count:
            raise SystemExit(f"Unsupported Glide source while applying: {old}")
        text = text.replace(old, new)
    path.write_text(text)


if __name__ == "__main__":
    patch(Path(sys.argv[1]))
