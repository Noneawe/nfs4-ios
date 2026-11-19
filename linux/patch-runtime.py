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
        # per-triangle costs seen in a profile on the R36S (A35 @ 1.25 GHz): the 64-entry fog table was converted with
        # fdiv for every triangle, and a texture switch scanned all 2048 cache entries
        ("    if (g_fog_mode & 0xFF) for (int i = 0; i < 64; i++) h->fogtab[i] = g_fog_table[i] / 255.0f;",
         "    if (g_fog_mode & 0xFF) {\n"
         "        static __thread uint8_t last[64]; static __thread float tabf[64]; static __thread int have;\n"
         "        if (!have || memcmp(last, g_fog_table, 64)) {\n"
         "            for (int i = 0; i < 64; i++) tabf[i] = g_fog_table[i] / 255.0f;\n"
         "            memcpy(last, g_fog_table, 64); have = 1;\n"
         "        }\n"
         "        memcpy(h->fogtab, tabf, sizeof tabf);\n"
         "    }", 1),
        ("static int gpu_tex_id(void) {\n",
         "static short g_texhash[512];   /* texture key -> g_texcache index + 1 (checked on use, cleared when the cache is dropped) */\n"
         "#define TEX_KEY_EQ(x, t) ((x)->aspect == (t)->aspect && (x)->small_lod == (t)->small_lod && (x)->large_lod == (t)->large_lod && (x)->format == (t)->format && (x)->addr == (t)->addr)\n"
         "static unsigned tex_hash(const Tex *t) {\n"
         "    uint32_t h = t->addr * 2654435761u;\n"
         "    h ^= (uint32_t)t->format * 40503u + (uint32_t)t->large_lod * 9176u + (uint32_t)t->small_lod * 131u + (uint32_t)t->aspect;\n"
         "    return (h ^ (h >> 15)) & 511;\n"
         "}\n"
         "static int gpu_tex_id(void) {\n", 1),
        ("    TexEntry *e = NULL;\n    for (int i = 0; i < g_ntex; i++) {\n",
         "    TexEntry *e = NULL;\n"
         "    const unsigned th = tex_hash(t);\n"
         "    {\n"
         "        const int hi = g_texhash[th] - 1;\n"
         "        if (hi >= 0 && hi < g_ntex && TEX_KEY_EQ(&g_texcache[hi], t)) e = &g_texcache[hi];\n"
         "    }\n"
         "    for (int i = 0; !e && i < g_ntex; i++) {\n", 1),
        ("            e = x;\n            break;\n", "            e = x; g_texhash[th] = (short)(i + 1);\n            break;\n", 1),
        ("            g_ntex = 0; g_last_tex=-1;", "            g_ntex = 0; g_last_tex=-1; memset(g_texhash, 0, sizeof g_texhash);", 1),
        ("*h = 768; *w = (int)(768 * a) & ~7; return 1;",
         "{ const char *e = getenv(\"NFS4_WIDE_H\"); int hh = e ? atoi(e) : 768; if (hh < 240 || hh > 768) hh = 768; *h = hh; *w = (int)(hh * a) & ~7; } return 1;", 1),
        ("if (a > 16.0f / 9.0f) a = 16.0f / 9.0f;",
         "{ const char *m = getenv(\"NFS4_WIDE_MAX\"); float wm = m ? (float)atof(m) : 2.4f; if (wm < 1.4f) wm = 1.4f; if (a > wm) a = wm; }", 1),
    )
    for old, new, count in changes:
        if text.count(new) == count:
            continue
        if text.count(old) != count:
            raise SystemExit(f"Unsupported Glide source while applying: {old}")
        text = text.replace(old, new)
    path.write_text(text)


POOL_FUNCTIONS = ("{0x0052C7B0, 0x0052C850, 0x0052C8F0, 0x0052CF60, 0x0052D150, 0x0052CAA0, 0x0052CB10, 0x0052CE20, 0x0052C700, 0x0052D7B0, 0x0052D9A0, 0x0052DA30, 0x0052DAA0, 0x0052DB50, 0x0052DC50,\n"
                  "                  0x0052DD70, 0x0052DFB0, 0x0052E0F0, 0x0052E200, 0x0052E300, 0x0052E340, 0x0052E380, 0x0052E3E0}")


def replace_once(path, old, new):
    text = path.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        raise SystemExit(f"Unsupported source in {path.name} while applying: {old[:60]}")
    path.write_text(text.replace(old, new))


def patch_pool(root):
    # 0052D8C0 is left out on purpose: it hands work to the loader threads and waits for them, and those threads
    # call pool functions, so holding the lock across it deadlocks (found on the phone and the R36S).
    """Serialise the game's memory pool across guest threads (avoseed/nfs4-ios b3de8f6).

    Must run before recompile.py: it changes the generated C. The pool walks its block chain
    outside a critical section, so threads on several cores can take the same block."""
    rt = root / "recomp/runtime"
    replace_once(rt / "rt.h", "void rt_trace_enter(Cpu *c, uint32_t addr);\n",
                 "void rt_trace_enter(Cpu *c, uint32_t addr);\n"
                 "void rt_pool_enter(uint32_t fn);   /* the game's memory pool, one guest thread at a time */\n"
                 "void rt_pool_leave(void);\n")
    replace_once(rt / "rt_core.c", "#ifdef RT_WATCH\nuint32_t rt_watch_lo",
                 "/* recursive: pool functions call each other. NFS4_POOL_WATCH logs a thread that waits for the lock for 3 s. */\n"
                 "static PlatMutex *g_pool_lock;\nstatic __thread int g_pool_depth;\n"
                 "static volatile uint32_t g_pool_owner_fn, g_pool_owner_tid, g_pool_wait_fn[32], g_pool_wait_since[32];\n"
                 "void rt_pool_enter(uint32_t fn) {\n"
                 "    if (g_pool_depth++) return;\n"
                 "    Cpu *c = rt_current_cpu(); uint32_t tid = (c ? c->thread_id : 0) & 31;\n"
                 "    g_pool_wait_fn[tid] = fn; g_pool_wait_since[tid] = (uint32_t)(plat_ticks_us() / 1000);\n"
                 "    plat_mutex_lock(g_pool_lock);\n"
                 "    g_pool_wait_since[tid] = 0; g_pool_owner_fn = fn; g_pool_owner_tid = tid;\n"
                 "}\n"
                 "void rt_pool_leave(void) { if (!--g_pool_depth) { g_pool_owner_fn = 0; plat_mutex_unlock(g_pool_lock); } }\n"
                 "static void pool_watch(void *p) {\n"
                 "    (void)p; uint32_t logged = 0;\n"
                 "    for (;;) { plat_sleep_ms(1000); uint32_t now = (uint32_t)(plat_ticks_us() / 1000);\n"
                 "        for (int i = 0; i < 32; i++) if (g_pool_wait_since[i] && now - g_pool_wait_since[i] > 3000 && logged++ < 20)\n"
                 "            plat_log(\"POOLWATCH thread %d waits %u ms in pool fn %08X; owner thread %u fn %08X\", i, now - g_pool_wait_since[i], g_pool_wait_fn[i], g_pool_owner_tid, g_pool_owner_fn); }\n"
                 "}\n\n"
                 "#ifdef RT_WATCH\nuint32_t rt_watch_lo")
    replace_once(rt / "rt_core.c", "int rt_boot(void) {\n",
                 "int rt_boot(void) {\n    g_pool_lock = plat_mutex_new();\n    if (getenv(\"NFS4_POOL_WATCH\")) plat_thread_start(pool_watch, NULL);\n")
    rec = root / "recomp/x86rec.py"
    replace_once(rec, "class Emitter:\n",
                 "# entry points of nfs4.exe's memory pool (Modern Patch build)\nPOOL_FUNCTIONS = " + POOL_FUNCTIONS + "\n\n\nclass Emitter:\n")
    replace_once(rec, "        self.out('void %s(Cpu *c) {' % self.fname(fn.entry))\n",
                 "        name = self.fname(fn.entry)\n"
                 "        if self.prefix == 'nfs4' and self.mod.pe.FILE_HEADER.TimeDateStamp == 0x57334341 and fn.entry in POOL_FUNCTIONS:\n"
                 "            self.out('static void %s_locked(Cpu *c);' % name)\n"
                 "            self.out('void %s(Cpu *c) { rt_pool_enter(0x%08Xu); %s_locked(c); rt_pool_leave(); }' % (name, fn.entry, name))\n"
                 "            self.out('static void %s_locked(Cpu *c) {' % name)\n"
                 "        else:\n"
                 "            self.out('void %s(Cpu *c) {' % name)\n")


if __name__ == "__main__":
    patch_pool(Path(sys.argv[1]))
    if len(sys.argv) < 3:
        patch(Path(sys.argv[1]))
