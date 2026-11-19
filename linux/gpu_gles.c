/* OpenGL ES 3.0 implementation of the shared Glide GPU interface. */
#include "gpu.h"
#include "plat.h"
#include "gpu_gles.h"
#include "gpu_gles_shaders.h"
#include <SDL.h>
#include <GLES3/gl3.h>
#include <EGL/egl.h>
#include <stdio.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

static SDL_Window *window;
static SDL_GLContext context;
static EGLDisplay egl_display = EGL_NO_DISPLAY;
static EGLContext egl_context = EGL_NO_CONTEXT;
static EGLSurface egl_surface = EGL_NO_SURFACE;
static GLuint program, vertices, uniforms, vao, target, color, depth;
static GLint size_uniform;
static int width, height;
static uint32_t *pixels, *flipped;
#define MAX_TEXTURES 4096
static struct { GLuint name; int w, h, mipmapped; int pmin, pmag, pws, pwt; } textures[MAX_TEXTURES];   /* p*: ostatnio ustawione parametry (0 = nieznane) */
static int sync_read = -1;       /* 1 = odczyt synchroniczny (NFS4_SYNC_READBACK, self-test) */
static GLuint pbo[2];            /* asynchroniczny odczyt klatki: wynik poprzedniej klatki, bez czekania na GPU */
static int pbo_index, pbo_filled;
static void gl_state_invalidate(void);
static void flush_draws(void);
typedef struct { GpuState s; int first, n; } DrawCmd;
static DrawCmd *cmds; static int ncmds, cmds_cap;
static GpuVertex *vbuf; static int vcount, vcap;
static int batch = -1;

static void check_gl(const char *operation) {
    GLenum error = glGetError();
    if (error != GL_NO_ERROR) plat_fatal("GLES: %s: GL error 0x%04x", operation, error);
}

int plat_direct(void);
SDL_Window *plat_gl_window(void);
void plat_fps_overlay(int w, int h, int screen_h, void (*rect)(int x, int y, int rw, int rh, int shade));

void gpu_gles_prepare(void) {
    if (getenv("NFS4_SOFTWARE")) return;
    if (plat_direct()) {   /* okno SDL z kontekstem GLES; używa go wątek gry */
        window = plat_gl_window();
        context = window ? SDL_GL_CreateContext(window) : NULL;
        if (!context) plat_fatal("GLES (NFS4_DIRECT): %s. Ustaw NFS4_DIRECT=0.", SDL_GetError());
        plat_log("GLES: prezentacja prosto z okna (bez odczytu klatki)");
        if (SDL_GL_MakeCurrent(window, NULL) < 0) plat_fatal("GLES odłączenie kontekstu: %s", SDL_GetError());
        return;
    }
    /* Borrow SDL's initialized EGL display, but never its window surface:
     * EGL cannot bind one surface concurrently on the game and SDL threads. */
    EGLDisplay display = eglGetCurrentDisplay();
    if (display != EGL_NO_DISPLAY) {
        const EGLint config_attributes[] = {
            EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE
        };
        const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
        const EGLint surface_attributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
        EGLConfig config;
        EGLint count;
        EGLenum previous_api = eglQueryAPI();
        if (eglBindAPI(EGL_OPENGL_ES_API) &&
            eglChooseConfig(display, config_attributes, &config, 1, &count) && count) {
            egl_context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
            if (egl_context != EGL_NO_CONTEXT)
                egl_surface = eglCreatePbufferSurface(display, config, surface_attributes);
        }
        eglBindAPI(previous_api);
        if (egl_context != EGL_NO_CONTEXT && egl_surface != EGL_NO_SURFACE) {
            egl_display = display;
            plat_log("GLES: osobny kontekst EGL pbuffer, bez drugiego okna");
            return;
        }
        plat_log("GLES: EGL pbuffer niedostępny (0x%x); próba okna SDL", eglGetError());
        if (egl_context != EGL_NO_CONTEXT) eglDestroyContext(display, egl_context);
        egl_context = EGL_NO_CONTEXT;
    }
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
    SDL_GL_SetAttribute(SDL_GL_SHARE_WITH_CURRENT_CONTEXT, 0);
    window = SDL_CreateWindow("NFS4 GLES", 0, 0, 32, 32,
                              SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
    if (window) context = SDL_GL_CreateContext(window);
    if (!context) {
        plat_log("GLES niedostępny: %s; renderer programowy", SDL_GetError());
        return;
    }
    /* The guest thread owns this context after gpu_init(). */
    if (SDL_GL_MakeCurrent(window, NULL) < 0)
        plat_fatal("GLES odłączenie kontekstu: %s", SDL_GetError());
}

static GLuint compile_shader(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint ok;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char message[4096];
        glGetShaderInfoLog(shader, sizeof message, NULL, message);
        plat_log("GLES shader: %s", message);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

/* NFS4_DIAG=lista,po,przecinkach: eksperymenty diagnostyczne wydajności GPU (zmieniają obraz, nie do gry):
 * empty skip2 tex1 flat nodisc mp nodepth noblend nomip noscissor */
static unsigned diag;
enum { D_EMPTY = 1, D_SKIP2 = 2, D_TEX1 = 4, D_FLAT = 8, D_NODISC = 16, D_MP = 32, D_NODEPTH = 64, D_NOBLEND = 128, D_NOMIP = 256, D_NOSCISSOR = 512 };
static void diag_parse(void) {
    static const struct { const char *n; unsigned f; } names[] = {{"empty",D_EMPTY},{"skip2",D_SKIP2},{"tex1",D_TEX1},{"flat",D_FLAT},
        {"nodisc",D_NODISC},{"mp",D_MP},{"nodepth",D_NODEPTH},{"noblend",D_NOBLEND},{"nomip",D_NOMIP},{"noscissor",D_NOSCISSOR}};
    const char *e = getenv("NFS4_DIAG");
    if (!e) return;
    size_t el = strlen(e);
    for (unsigned i = 0; i < sizeof names / sizeof *names; ++i) {   /* całe słowa rozdzielone przecinkami: "empty" nie zawiera "mp" */
        size_t nl = strlen(names[i].n);
        for (const char *p = e; (p = strstr(p, names[i].n)); p += nl)
            if ((p == e || p[-1] == ',') && (p + nl == e + el || p[nl] == ',')) { diag |= names[i].f; break; }
    }
    plat_log("DIAG: 0x%x (%s)", diag, e);
}
static char *replace_all(const char *src, const char *from, const char *to) {
    size_t n = 0, lf = strlen(from), lt = strlen(to);
    for (const char *p = src; (p = strstr(p, from)); p += lf) n++;
    char *out = malloc(strlen(src) + n * (lt > lf ? lt - lf : 0) + 1), *o = out;
    for (const char *p = src;;) {
        const char *q = strstr(p, from);
        if (!q) { strcpy(o, p); break; }
        memcpy(o, p, (size_t)(q - p)); o += q - p; memcpy(o, to, lt); o += lt; p = q + lf;
    }
    return out;
}
static const char GPU_FLAT_FRAGMENT[] =
"#version 300 es\nprecision mediump float;\nprecision mediump int;\n"
"layout(std140) uniform Shade { ivec4 cc; ivec4 ac; ivec4 tcm; ivec4 flags; ivec4 mode; vec4 aref; vec4 chroma; vec4 fogc; vec4 constc; vec4 fogtab4[16]; };\n"
"in vec2 v_st; in vec4 v_col; in vec3 v_affine; out vec4 out_color;\n"
"void main() { out_color = v_col / v_affine.z + vec4(float(cc.x) * 0.0); }\n";
static GLuint compile_fragment(int mode, const int32_t *key) {   /* 0 = mediump (kolor) + highp (alfa, tekstura), 1 = highp, 2 = wszystko mediump */
    diag_parse();
    if ((diag & D_FLAT) || mode == 2) return compile_shader(GL_FRAGMENT_SHADER, GPU_FLAT_FRAGMENT);
    char *a = strdup(GPU_GLES_FRAGMENT), *b;
    if (diag & D_NODISC) { b = replace_all(a, "discard;", ";"); free(a); a = b; }
    if (diag & D_MP) { b = replace_all(a, "precision highp float;", "precision mediump float;"); free(a); a = b; }
    if (mode == 1) { b = replace_all(a, "precision mediump float;", "precision highp float;"); free(a); a = b; }   /* stary shader, do porównań */
    if (key) {   /* wariant wyspecjalizowany: kombinacje kolorów, test alfa i mgła jako stałe, kompilator usuwa gałęzie */
        char consts[600];
        snprintf(consts, sizeof consts, "const ivec4 cc = ivec4(%d,%d,%d,%d); const ivec4 ac = ivec4(%d,%d,%d,%d); const ivec4 tcm = ivec4(%d,%d,%d,%d);\n"
                 "const ivec4 flags = ivec4(%d,%d,%d,%d); const ivec4 mode = ivec4(%d,%d,%d,%d);\nuniform sampler2D tex0;\n",
                 key[0], key[1], key[2], key[3], key[4], key[5], key[6], key[7], key[8], key[9], key[10], key[11],
                 key[12], key[13], key[14], key[15], key[16], key[17], key[18], key[19]);
        b = replace_all(a, "ivec4 cc; ivec4 ac; ivec4 tcm; ivec4 flags; ivec4 mode;", "ivec4 cc_u; ivec4 ac_u; ivec4 tcm_u; ivec4 flags_u; ivec4 mode_u;"); free(a); a = b;
        b = replace_all(a, "uniform sampler2D tex0;\n", consts); free(a); a = b;
    }
    GLuint f = compile_shader(GL_FRAGMENT_SHADER, a);
    free(a);
    return f;
}

static GLuint build_program(int mode, const int32_t *key, GLint *size_loc) {
    GLuint vs = compile_shader(GL_VERTEX_SHADER, GPU_GLES_VERTEX);
    GLuint fs = compile_fragment(mode, key);
    if (!vs || !fs) {
        glDeleteShader(vs); glDeleteShader(fs);
        return 0;
    }
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs); glAttachShader(prog, fs);
    glLinkProgram(prog);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char message[4096];
        glGetProgramInfoLog(prog, sizeof message, NULL, message);
        plat_log("GLES link: %s", message);
        glDeleteProgram(prog);
        return 0;
    }
    glUseProgram(prog);
    *size_loc = glGetUniformLocation(prog, "vsize");
    glUniform1i(glGetUniformLocation(prog, "tex0"), 0);
    GLuint block = glGetUniformBlockIndex(prog, "Shade");
    GLint block_size;
    glGetActiveUniformBlockiv(prog, block, GL_UNIFORM_BLOCK_DATA_SIZE, &block_size);
    if (block_size != sizeof(GpuShade)) plat_fatal("GLES: niezgodny rozmiar GpuShade");
    glUniformBlockBinding(prog, block, 0);
    return prog;
}
static struct {
    int valid, scissor_on, depth_on, depth_func, depth_mask, blend_set;
    int sc[4], bl[4];
    int size_w, size_h;
    GpuShade shade; int shade_set;
    GLuint fbo, prog;
} gl_state;
/* Programy: ogólny (generic) i wyspecjalizowane wg kombinacji stanu shadera (ok. 7 w grze), kompilowane przy pierwszym użyciu.
 * NFS4_SPECIALIZE=0 wyłącza. NFS4_PRECISION_AB=1: co 600 klatek tryby: wyspecjalizowany / ogólny / prosty kolor / bez rysowania. */
typedef struct { int32_t k[20]; GLuint prog; GLint sloc; int sw, sh; } ProgEntry;
static uint64_t total_frames;
static ProgEntry generic, flat_entry, pcache[128]; static int npc, special = 1, prog_ab, ab_empty;
static ProgEntry *program_for(const GpuShade *sh) {
    if (!special) return &generic;
    for (int i = 0; i < npc; ++i) if (!memcmp(pcache[i].k, sh, sizeof pcache[i].k)) return &pcache[i];
    if (npc == 128) return &generic;
    ProgEntry *e = &pcache[npc];
    memcpy(e->k, sh, sizeof e->k);
    uint64_t t = plat_ticks_us();
    e->prog = build_program(0, e->k, &e->sloc);
    if (!e->prog) { e->prog = 0; return &generic; }
    e->sw = e->sh = 0; npc++;
    glUseProgram(program);   /* build_program zostawił nowy program aktywny; stan w gl_state i tak jest sprawdzany przy rysowaniu */
    plat_log("GLES: shader #%d skompilowany w %llu us: cc %d,%d,%d,%d tc %d,%d,%d,%d mode %d,%d,%d,%d", npc, (unsigned long long)(plat_ticks_us() - t),
             e->k[0], e->k[1], e->k[2], e->k[3], e->k[8], e->k[9], e->k[10], e->k[11], e->k[16], e->k[17], e->k[18], e->k[19]);
    gl_state.prog = 0;
    return e;
}
static int setup_program(void) {
    special = !(getenv("NFS4_SPECIALIZE") && getenv("NFS4_SPECIALIZE")[0] == '0');
    program = build_program(getenv("NFS4_HIGHP") ? 1 : 0, NULL, &size_uniform);
    if (!program) return 0;
    generic.prog = program; generic.sloc = size_uniform;
    if (getenv("NFS4_PRECISION_AB")) {
        flat_entry.prog = build_program(2, NULL, &flat_entry.sloc);
        prog_ab = flat_entry.prog != 0;
    }
    glGenBuffers(1, &uniforms);
    glGenBuffers(1, &vertices);
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glBindBuffer(GL_ARRAY_BUFFER, vertices);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 4, GL_FLOAT, GL_FALSE, sizeof(GpuVertex), (void *)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(GpuVertex), (void *)offsetof(GpuVertex, s));
    glEnableVertexAttribArray(2);
    glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, sizeof(GpuVertex), (void *)offsetof(GpuVertex, fog));
    glEnableVertexAttribArray(3);
    glVertexAttribPointer(3, 4, GL_UNSIGNED_BYTE, GL_TRUE, sizeof(GpuVertex), (void *)offsetof(GpuVertex, rgba));
    glDisable(GL_CULL_FACE);
    glDisable(GL_DITHER);
    check_gl("setup");
    return 1;
}

int gpu_init(int w, int h) {
    ncmds = vcount = 0;
    if (egl_display != EGL_NO_DISPLAY) {
        if (!eglBindAPI(EGL_OPENGL_ES_API) ||
            !eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context)) {
            plat_log("GLES: EGL make-current failed: 0x%x", eglGetError());
            return 0;
        }
    } else if (!context) return 0;
    else if (SDL_GL_MakeCurrent(window, context) < 0) {
        plat_log("GLES kontekst: %s; renderer programowy", SDL_GetError());
        return 0;
    }
    if (plat_direct()) SDL_GL_SetSwapInterval(0);   /* tempo ustala limit klatek gry */
    if (!program) {
        plat_log("GLES vendor: %s; renderer: %s; version: %s",
                 glGetString(GL_VENDOR), glGetString(GL_RENDERER), glGetString(GL_VERSION));
        const char *name = (const char *)glGetString(GL_RENDERER);
        if (name && (strstr(name, "llvmpipe") || strstr(name, "softpipe") || strstr(name, "Software")))
            plat_log("GLES: sterownik renderuje na CPU; brak sprzętowej akceleracji");
        if (!setup_program()) return 0;
    }
    GLint max_size;
    glGetIntegerv(GL_MAX_RENDERBUFFER_SIZE, &max_size);
    if (w <= 0 || h <= 0 || w > max_size || h > max_size) return 0;
    glDeleteFramebuffers(1, &target);
    glDeleteTextures(1, &color);
    glDeleteRenderbuffers(1, &depth);
    glGenFramebuffers(1, &target);
    glBindFramebuffer(GL_FRAMEBUFFER, target);
    glGenTextures(1, &color);
    glBindTexture(GL_TEXTURE_2D, color);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0);
    glGenRenderbuffers(1, &depth);
    glBindRenderbuffer(GL_RENDERBUFFER, depth);
    /* grGet(GR_BITS_DEPTH) advertises Glide's 16-bit precision. Coplanar
     * headlight passes must compare at that precision, including LEQUAL. */
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, w, h);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        plat_fatal("GLES: niekompletny framebuffer %dx%d", w, h);
    width = w; height = h;
    glDeleteBuffers(2, pbo);
    glGenBuffers(2, pbo);
    for (int i = 0; i < 2; ++i) {
        glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo[i]);
        glBufferData(GL_PIXEL_PACK_BUFFER, (GLsizeiptr)w * h * 4, NULL, GL_STREAM_READ);
    }
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    pbo_index = pbo_filled = 0;
    gl_state_invalidate();
    free(pixels); free(flipped);
    pixels = malloc((size_t)w * h * 4);
    flipped = malloc((size_t)w * h * 4);
    if (!pixels || !flipped) plat_fatal("GLES: brak pamięci na klatkę");
    glDisable(GL_SCISSOR_TEST);
    glDepthMask(GL_TRUE);
    glClearColor(0, 0, 0, 1);
    glClearDepthf(1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    check_gl("framebuffer");
    plat_log("GLES: ścieżka 3D aktywna, %dx%d", w, h);
    return 1;
}

int gpu_texture_create(int w, int h, int mipmapped) {
    for (int i = 0; i < MAX_TEXTURES; ++i) {
        if (textures[i].name) continue;
        glGenTextures(1, &textures[i].name);
        glBindTexture(GL_TEXTURE_2D, textures[i].name);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        textures[i].w = w; textures[i].h = h; textures[i].mipmapped = mipmapped;
        textures[i].pmin = textures[i].pmag = textures[i].pws = textures[i].pwt = 0;
        check_gl("texture create");
        return i;
    }
    plat_fatal("GLES: brak wolnych tekstur");
    return -1;
}
void gpu_texture_upload(int id, const uint32_t *rgba) {
    flush_draws();   /* wcześniejsze rysowania muszą zobaczyć starą zawartość tekstury */
    if (id < 0 || id >= MAX_TEXTURES || !textures[id].name) return;
    glBindTexture(GL_TEXTURE_2D, textures[id].name);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, textures[id].w, textures[id].h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    if (textures[id].mipmapped) glGenerateMipmap(GL_TEXTURE_2D);
    check_gl("texture upload");
}
void gpu_texture_destroy(int id) {
    flush_draws();
    if (id < 0 || id >= MAX_TEXTURES) return;
    glDeleteTextures(1, &textures[id].name);
    textures[id].name = 0;
}

static GLenum blend_factor(int f, int src, int alpha) {
    switch (f) {
    case 0: return GL_ZERO;
    case 1: return GL_SRC_ALPHA;
    case 2: return alpha ? (src ? GL_DST_ALPHA : GL_SRC_ALPHA) : (src ? GL_DST_COLOR : GL_SRC_COLOR);
    case 3: return GL_DST_ALPHA;
    case 4: return GL_ONE;
    case 5: return GL_ONE_MINUS_SRC_ALPHA;
    case 6: return alpha ? (src ? GL_ONE_MINUS_DST_ALPHA : GL_ONE_MINUS_SRC_ALPHA)
                         : (src ? GL_ONE_MINUS_DST_COLOR : GL_ONE_MINUS_SRC_COLOR);
    case 7: return GL_ONE_MINUS_DST_ALPHA;
    case 15: return src ? GL_SRC_ALPHA_SATURATE : GL_ONE;
    default: return GL_ONE;
    }
}

static uint64_t prof_map_us, prof_copy_us, prof_pres_us, prof_draw_us, prof_read_us, prof_last_swap_us, prof_frames, prof_draws, prof_verts, prof_wall_us;
void gpu_draw_impl(const GpuState *s, const GpuVertex *v, int n, int first);
/* Nagrywanie rysowań: wierzchołki trafiają do tablicy CPU, sterownik dostaje jeden glBufferData na klatkę,
 * a sąsiednie rysowania z identycznym stanem są łączone w jedno glDrawArrays. NFS4_BATCH=0 = stara ścieżka. */
/* Czas GPU z EXT_disjoint_timer_query (jeśli jest): zapytanie obejmuje rysowania jednej klatki, wyniki z opóźnieniem 3 klatek. */
typedef void (*PFNQ)(GLsizei, GLuint *);
static void (*q_gen)(GLsizei, GLuint *), (*q_begin)(GLenum, GLuint), (*q_end)(GLenum), (*q_geti)(GLuint, GLenum, GLuint *), (*q_get64)(GLuint, GLenum, uint64_t *);
static GLuint q_ids[4]; static unsigned q_issued, q_read; static int q_ok = -1;
static uint64_t prof_gpu_ns, prof_gpu_n;
static void query_init(void) {
    const char *ext = (const char *)glGetString(GL_EXTENSIONS);
    q_ok = 0;
    if (!ext || !strstr(ext, "GL_EXT_disjoint_timer_query") || !getenv("NFS4_GPU_TIMER")) return;   /* zegar sam spowalnia klatkę (serializuje GPU): tylko na żądanie */
    q_gen = (void *)eglGetProcAddress("glGenQueriesEXT"); q_begin = (void *)eglGetProcAddress("glBeginQueryEXT");
    q_end = (void *)eglGetProcAddress("glEndQueryEXT"); q_geti = (void *)eglGetProcAddress("glGetQueryObjectuivEXT");
    q_get64 = (void *)eglGetProcAddress("glGetQueryObjectui64vEXT");
    if (!q_gen || !q_begin || !q_end || !q_geti || !q_get64) return;
    q_gen(4, q_ids); q_ok = 1; plat_log("GLES: zegar GPU (EXT_disjoint_timer_query) aktywny");
}
static struct { int32_t k[20]; uint64_t draws, tris; } keys[512]; static int nkeys, stats_on = -1;
static void shader_stats_dump(void) {
    if (stats_on < 1) return;
    uint64_t total = 0; for (int j = 0; j < nkeys; ++j) total += keys[j].tris;
    plat_log("SHADER_STATS: %d kombinacji, %llu trójkątów łącznie", nkeys, (unsigned long long)total);
    for (int j = 0; j < nkeys; ++j) {
        const int32_t *k = keys[j].k;
        plat_log("SHADER_STATS: cc %d,%d,%d,%d ac %d,%d,%d,%d tc %d,%d,%d,%d fl %d,%d,%d,%d mode %d,%d,%d,%d : %llu rys, %llu tr (%.1f%%)",
                 k[0], k[1], k[2], k[3], k[4], k[5], k[6], k[7], k[8], k[9], k[10], k[11], k[12], k[13], k[14], k[15], k[16], k[17], k[18], k[19],
                 (unsigned long long)keys[j].draws, (unsigned long long)keys[j].tris, total ? 100.0 * keys[j].tris / total : 0.0);
    }
}
static void flush_draws(void) {
    if (stats_on < 0) stats_on = getenv("NFS4_SHADER_STATS") != NULL;
    if (!ncmds) return;
    uint64_t t = plat_ticks_us();
    if (q_ok < 0) query_init();
    const int timing = q_ok == 1 && q_issued - q_read < 4;
    if (timing) q_begin(0x88BF /* GL_TIME_ELAPSED_EXT */, q_ids[q_issued % 4]);
    glBindVertexArray(vao);
    glBindBuffer(GL_ARRAY_BUFFER, vertices);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)vcount * sizeof *vbuf, vbuf, GL_STREAM_DRAW);
    if (stats_on) for (int i = 0; i < ncmds; ++i) {   /* NFS4_SHADER_STATS=1: ile różnych kombinacji shadera używa gra */
        const int32_t *k = (const int32_t *)&cmds[i].s.shade;   /* cc ac tc flags mode: 20 liczb */
        int j = 0;
        for (; j < nkeys; ++j) if (!memcmp(keys[j].k, k, sizeof keys[j].k)) break;
        if (j == nkeys && nkeys < 512) { memcpy(keys[j].k, k, sizeof keys[j].k); keys[j].draws = 0; keys[j].tris = 0; nkeys++; }
        if (j < nkeys) { keys[j].draws++; keys[j].tris += (uint64_t)cmds[i].n / 3; }
    }
    for (int i = 0; i < ncmds; ++i) gpu_draw_impl(&cmds[i].s, NULL, cmds[i].n, cmds[i].first);
    prof_draws += (uint64_t)ncmds;
    {   /* NFS4_COMPARE_FRAME=n: ta sama lista rysowań dwa razy (wyspecjalizowany, potem ogólny shader), porównanie pikseli */
        static long cf = -2;
        if (cf == -2) cf = getenv("NFS4_COMPARE_FRAME") ? atol(getenv("NFS4_COMPARE_FRAME")) : -1;
        if (cf >= 0 && total_frames == (uint64_t)cf && special) {
            const size_t bytes = (size_t)width * height * 4;
            uint8_t *A = malloc(bytes), *Bm = malloc(bytes);
            glBindFramebuffer(GL_FRAMEBUFFER, target);
            glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, A);
            special = 0; glDisable(GL_SCISSOR_TEST); glDepthMask(GL_TRUE); glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
            gl_state_invalidate();
            for (int i = 0; i < ncmds; ++i) gpu_draw_impl(&cmds[i].s, NULL, cmds[i].n, cmds[i].first);
            glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, Bm);
            special = 1; gl_state_invalidate();
            uint64_t differing = 0, big = 0; int mx = 0;
            for (size_t i = 0; i < bytes; ++i) { int d = abs((int)A[i] - (int)Bm[i]); if (d) differing++; if (d > 8) big++; if (d > mx) mx = d; }
            plat_log("COMPARE: klatka %ld, %d rysowań: bajty różne %llu / %zu, >8: %llu, max różnica %d", cf, ncmds, (unsigned long long)differing, bytes, (unsigned long long)big, mx);
            free(A); free(Bm);
        }
    }
    ncmds = vcount = 0;
    if (timing) q_end(0x88BF), q_issued++;
    while (q_ok == 1 && q_read < q_issued) {
        GLuint ready = 0; q_geti(q_ids[q_read % 4], 0x8867 /* QUERY_RESULT_AVAILABLE */, &ready);
        if (!ready) break;
        uint64_t ns = 0; q_get64(q_ids[q_read % 4], 0x8866 /* QUERY_RESULT */, &ns);
        prof_gpu_ns += ns; prof_gpu_n++; q_read++;
    }
    prof_draw_us += plat_ticks_us() - t;
}
void gpu_draw(const GpuState *s, const GpuVertex *v, int n) {
    if (batch < 0) batch = !(getenv("NFS4_BATCH") && getenv("NFS4_BATCH")[0] == '0');
    prof_verts += (uint64_t)(n > 0 ? n : 0);
    if (!batch) {
        uint64_t t = plat_ticks_us();
        gpu_draw_impl(s, v, n, 0);
        prof_draw_us += plat_ticks_us() - t; prof_draws++;
        return;
    }
    if (n <= 0) return;
    if (vcount + n > vcap) {
        vcap = (vcount + n) * 2;
        vbuf = realloc(vbuf, (size_t)vcap * sizeof *vbuf);
        if (!vbuf) plat_fatal("GLES: brak pamięci na wierzchołki");
    }
    memcpy(vbuf + vcount, v, (size_t)n * sizeof *v);
    if (ncmds && !memcmp(&cmds[ncmds - 1].s, s, sizeof *s)) cmds[ncmds - 1].n += n;
    else {
        if (ncmds == cmds_cap) {
            cmds_cap = cmds_cap ? cmds_cap * 2 : 1024;
            cmds = realloc(cmds, (size_t)cmds_cap * sizeof *cmds);
            if (!cmds) plat_fatal("GLES: brak pamięci na rysowania");
        }
        memset(&cmds[ncmds], 0, sizeof cmds[ncmds]);   /* wyzerowane wypełnienie: memcmp stanu jest wiarygodny */
        cmds[ncmds].s = *s; cmds[ncmds].first = vcount; cmds[ncmds].n = n; ncmds++;
    }
    vcount += n;
}
/* Cache stanu GL: sterownik mobilny kosztuje ok. 2 us za każde wywołanie, a batchy jest kilkaset na klatkę. */

static void gl_state_invalidate(void) { memset(&gl_state, 0, sizeof gl_state); }

static GLuint tex1x1;
void gpu_draw_impl(const GpuState *s, const GpuVertex *v, int n, int first) {
    if (n <= 0) return;
    static unsigned skip_counter;
    if ((diag & D_EMPTY) || ab_empty || ((diag & D_SKIP2) && (skip_counter++ & 1))) return;
    GpuState tmp;
    if (diag & (D_NODEPTH | D_NOSCISSOR)) {
        tmp = *s; s = &tmp;
        if (diag & D_NODEPTH) { tmp.depth_func = -1; tmp.depth_write = 0; }
        if (diag & D_NOSCISSOR) { tmp.scissor[0] = tmp.scissor[1] = 0; tmp.scissor[2] = width; tmp.scissor[3] = height; }
    }
    if (!gl_state.valid) {   /* pierwszy rysunek po utworzeniu celu: ustaw stały stan raz */
        glUseProgram(program);
        glBindVertexArray(vao);
        glBindBuffer(GL_ARRAY_BUFFER, vertices);
        glBindBuffer(GL_UNIFORM_BUFFER, uniforms);
        glBindBufferBase(GL_UNIFORM_BUFFER, 0, uniforms);
        glActiveTexture(GL_TEXTURE0);
        if (diag & D_NOBLEND) glDisable(GL_BLEND); else glEnable(GL_BLEND);
        glViewport(0, 0, width, height);
        gl_state.valid = 1;
    }
    if (gl_state.fbo != target) { glBindFramebuffer(GL_FRAMEBUFFER, target); glViewport(0, 0, width, height); gl_state.fbo = target; }
    int x0 = s->scissor[0] < 0 ? 0 : s->scissor[0];
    int y0 = s->scissor[1] < 0 ? 0 : s->scissor[1];
    int x1 = s->scissor[2] > width ? width : s->scissor[2];
    int y1 = s->scissor[3] > height ? height : s->scissor[3];
    if (x1 <= x0 || y1 <= y0) return;
    if (!gl_state.scissor_on) { glEnable(GL_SCISSOR_TEST); gl_state.scissor_on = 1; }
    const int sc[4] = {x0, height - y1, x1 - x0, y1 - y0};
    if (memcmp(sc, gl_state.sc, sizeof sc)) { glScissor(sc[0], sc[1], sc[2], sc[3]); memcpy(gl_state.sc, sc, sizeof sc); }
    if (s->depth_func < 0) { if (gl_state.depth_on != 1) { glDisable(GL_DEPTH_TEST); gl_state.depth_on = 1; } }
    else {
        if (gl_state.depth_on != 2) { glEnable(GL_DEPTH_TEST); gl_state.depth_on = 2; }
        if (gl_state.depth_func != s->depth_func + 1) { glDepthFunc(GL_NEVER + (s->depth_func & 7)); gl_state.depth_func = s->depth_func + 1; }
    }
    const int dm = s->depth_write ? 2 : 1;
    if (gl_state.depth_mask != dm) { glDepthMask(dm == 2 ? GL_TRUE : GL_FALSE); gl_state.depth_mask = dm; }
    if (!gl_state.blend_set || memcmp(gl_state.bl, s->blend, sizeof gl_state.bl)) {
        glBlendFuncSeparate(blend_factor(s->blend[0], 1, 0), blend_factor(s->blend[1], 0, 0),
                            blend_factor(s->blend[2], 1, 1), blend_factor(s->blend[3], 0, 1));
        memcpy(gl_state.bl, s->blend, sizeof gl_state.bl); gl_state.blend_set = 1;
    }
    ProgEntry *pe = program_for(&s->shade);
    if (gl_state.prog != pe->prog) { glUseProgram(pe->prog); gl_state.prog = pe->prog; }
    if (pe->sw != width || pe->sh != height) { glUniform2f(pe->sloc, width, height); pe->sw = width; pe->sh = height; }
    if (!gl_state.shade_set || memcmp(&gl_state.shade, &s->shade, sizeof s->shade)) {
        glBufferData(GL_UNIFORM_BUFFER, sizeof s->shade, &s->shade, GL_STREAM_DRAW);
        memcpy(&gl_state.shade, &s->shade, sizeof s->shade); gl_state.shade_set = 1;
    }
    if (s->tex >= 0 && s->tex < MAX_TEXTURES && textures[s->tex].name) {
        if (diag & D_TEX1) {
            if (!tex1x1) {
                const uint32_t px = 0xff808080u;
                glGenTextures(1, &tex1x1); glBindTexture(GL_TEXTURE_2D, tex1x1);
                glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, &px);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            }
            glBindTexture(GL_TEXTURE_2D, tex1x1);
        } else glBindTexture(GL_TEXTURE_2D, textures[s->tex].name);
        int mips = (diag & D_NOMIP) ? 0 : textures[s->tex].mipmapped;
        /* parametry tekstury zmieniamy tylko gdy się różnią: każde glTexParameteri to koszt sterownika */
        const int pmin = s->bilinear ? (mips ? GL_LINEAR_MIPMAP_LINEAR : GL_LINEAR) : (mips ? GL_NEAREST_MIPMAP_NEAREST : GL_NEAREST);
        const int pmag = s->bilinear ? GL_LINEAR : GL_NEAREST;
        const int pws = s->clamp_s ? GL_CLAMP_TO_EDGE : GL_REPEAT, pwt = s->clamp_t ? GL_CLAMP_TO_EDGE : GL_REPEAT;
        if (textures[s->tex].pmin != pmin) { glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, pmin); textures[s->tex].pmin = pmin; }
        if (textures[s->tex].pmag != pmag) { glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, pmag); textures[s->tex].pmag = pmag; }
        if (textures[s->tex].pws != pws) { glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, pws); textures[s->tex].pws = pws; }
        if (textures[s->tex].pwt != pwt) { glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, pwt); textures[s->tex].pwt = pwt; }
    } else glBindTexture(GL_TEXTURE_2D, 0);
    if (v) glBufferData(GL_ARRAY_BUFFER, (size_t)n * sizeof *v, v, GL_STREAM_DRAW);
    glDrawArrays(GL_TRIANGLES, first, n);
}

static void overlay_rect(int x, int y, int rw, int rh, int shade) {
    int dw, dh; SDL_GL_GetDrawableSize(window, &dw, &dh);
    glScissor(x, dh - y - rh, rw, rh);
    if (shade) glClearColor(1, 1, 1, 1); else glClearColor(0.05f, 0.05f, 0.05f, 1);
    glClear(GL_COLOR_BUFFER_BIT);
}
/* Klatka z FBO od razu do okna: blit z zachowaniem proporcji (czarne pasy), licznik FPS, zamiana buforów. */
static int direct_pending;   /* blit klatki N czeka na SwapWindow na początku klatki N+1: GPU liczy równolegle z logiką gry */
static void present_direct(void) {
    int dw, dh;
    SDL_GL_GetDrawableSize(window, &dw, &dh);
    int vw = dw, vh = (int)((int64_t)dw * height / width);
    if (vh > dh) { vh = dh; vw = (int)((int64_t)dh * width / height); }
    const int x = (dw - vw) / 2, y = (dh - vh) / 2;
    glDisable(GL_SCISSOR_TEST);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
    if (vw < dw || vh < dh) { glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT); }
    glBindFramebuffer(GL_READ_FRAMEBUFFER, target);
    glBlitFramebuffer(0, 0, width, height, x, y, x + vw, y + vh, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    {   /* NFS4_DUMP_FRAME w trybie bezpośrednim: obraz z okna (przed licznikiem), do porównania z odczytem FBO */
        const char *d = getenv("NFS4_DUMP_FRAME");
        if (d && flipped && total_frames == (uint64_t)atoll(d) && vw == width && vh == height) {
            glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
            glReadPixels(x, y, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
            for (int r = 0; r < height; ++r) memcpy(flipped + (size_t)r * width, pixels + (size_t)(height - 1 - r) * width, (size_t)width * 4);
            {   /* ta sama klatka z FBO: bajty zgodne = blit bez odwrócenia i przesunięcia */
                uint32_t *ref = malloc((size_t)width * height * 4);
                glBindFramebuffer(GL_READ_FRAMEBUFFER, target);
                glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, ref);
                size_t diff = 0;
                for (size_t i = 0; ref && i < (size_t)width * height; ++i) diff += (ref[i] & 0xFFFFFFu) != (pixels[i] & 0xFFFFFFu);   /* alfa okna bywa stała */
                plat_log("DIRECT-CHECK: %zu z %d pikseli różni się od FBO", diff, width * height);
                free(ref);
            }
            const char *file = getenv("NFS4_DUMP_FILE");
            FILE *f = file ? fopen(file, "wb") : NULL;
            if (f) { fprintf(f, "P6\n%d %d\n255\n", width, height); for (int i = 0; i < width * height; ++i) fwrite((uint8_t *)&flipped[i], 1, 3, f); fclose(f); }
        }
    }
    glEnable(GL_SCISSOR_TEST);
    plat_fps_overlay(width, height, dh, overlay_rect);
    glDisable(GL_SCISSOR_TEST);
    glFlush();
    direct_pending = 1;
    glBindFramebuffer(GL_FRAMEBUFFER, target);
    gl_state_invalidate();
}

void gpu_swap(void) {
    if (direct_pending) { SDL_GL_SwapWindow(window); direct_pending = 0; }
    flush_draws();
    /* ponytail: synchronous readback keeps SDL presentation; use shared textures if bandwidth limits FPS. */
    uint64_t t0 = plat_ticks_us();
    if (sync_read < 0) sync_read = getenv("NFS4_SYNC_READBACK") != NULL;
    if (getenv("NFS4_READBACK_AB")) {   /* test A/B: co 600 klatek zmiana trybu odczytu, ta sama scena */
        int want = (int)((total_frames / 600) & 1);
        if (want != sync_read) { sync_read = want; pbo_filled = 0; }
    }
    if (prog_ab) {
        const int k = (int)((total_frames / 600) % 4);
        if (ab_empty != (k == 3) || special != (k == 0) || (k == 2) != (generic.prog == flat_entry.prog)) {
            static GLuint base; static GLint base_loc; static int base_set;
            if (!base_set) { base = generic.prog; base_loc = generic.sloc; base_set = 1; }
            ab_empty = k == 3; special = k == 0;
            generic.prog = k == 2 ? flat_entry.prog : base; generic.sloc = k == 2 ? flat_entry.sloc : base_loc; generic.sw = generic.sh = 0;
            gl_state_invalidate();
            plat_log("PROF shader=%s", k == 0 ? "WYSPECJALIZOWANY" : k == 1 ? "ogolny" : k == 2 ? "PROSTY-sam-kolor" : "BEZ-rysowania");
        }
    }
    total_frames++;
    glBindFramebuffer(GL_FRAMEBUFFER, target);
    uint64_t t1;
    if (plat_direct()) {
        present_direct();
        t1 = plat_ticks_us();
    } else if (sync_read) {
        glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        check_gl("readback");
        t1 = plat_ticks_us();
        for (int y = 0; y < height; ++y)
            memcpy(flipped + (size_t)y * width, pixels + (size_t)(height - 1 - y) * width, (size_t)width * 4);
        plat_present(flipped, width, height);
    } else {
        /* odczyt do PBO zwraca od razu; pokazujemy klatkę poprzednią (opóźnienie 1 klatki), GPU nie blokuje CPU */
        glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo[pbo_index]);
        glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, (void *)0);
        t1 = plat_ticks_us();
        const int prev = 1 - pbo_index;
        if (pbo_filled) {
            glBindBuffer(GL_PIXEL_PACK_BUFFER, pbo[prev]);
            uint64_t ta = plat_ticks_us();
            const uint32_t *m = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, (GLsizeiptr)width * height * 4, GL_MAP_READ_BIT);
            uint64_t tb = plat_ticks_us();
            if (m) {
                for (int y = 0; y < height; ++y)
                    memcpy(flipped + (size_t)y * width, m + (size_t)(height - 1 - y) * width, (size_t)width * 4);
                glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
                uint64_t tc = plat_ticks_us();
                plat_present(flipped, width, height);
                prof_map_us += tb - ta; prof_copy_us += tc - tb; prof_pres_us += plat_ticks_us() - tc;
            }
        }
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        check_gl("readback");
        pbo_index = prev;
        pbo_filled = 1;
    }
    {   /* NFS4_DUMP_FRAME=n: zapis n-tej klatki do NFS4_DUMP_FILE (PPM), do porównań obrazu */
        const char *d = getenv("NFS4_DUMP_FRAME"), *file = getenv("NFS4_DUMP_FILE");
        if (d && file && total_frames == (uint64_t)atoll(d) && flipped && !plat_direct()) {
            FILE *f = fopen(file, "wb");
            if (f) {
                fprintf(f, "P6\n%d %d\n255\n", width, height);
                for (int i = 0; i < width * height; ++i) fwrite(&flipped[i], 1, 3, f);
                fclose(f);
                plat_log("DUMP: klatka %llu -> %s", (unsigned long long)total_frames, file);
            }
        }
    }
    uint64_t t2 = plat_ticks_us();
    prof_read_us += t2 - t0; (void)t1;
    if (++prof_frames == 300) {
        uint64_t wall = t2 - prof_last_swap_us;
        plat_log("PROF split: map-wait %llu us, copy %llu us, present %llu us", (unsigned long long)(prof_map_us / 300), (unsigned long long)(prof_copy_us / 300), (unsigned long long)(prof_pres_us / 300)); prof_map_us = prof_copy_us = prof_pres_us = 0;
        plat_log("PROF gpu_time: %llu us avg over %llu frames (draws only)", (unsigned long long)(prof_gpu_n ? prof_gpu_ns / prof_gpu_n / 1000 : 0), (unsigned long long)prof_gpu_n); prof_gpu_ns = prof_gpu_n = 0;
        shader_stats_dump();
        plat_log("PROF mode=%s", sync_read ? "sync" : "pbo"); plat_log("PROF per frame: wall %llu us (first window incl.), draws %llu, verts %llu, gpu_draw %llu us, readback+copy+present %llu us (glReadPixels %llu us)",
                 (unsigned long long)(wall / 300), (unsigned long long)(prof_draws / 300), (unsigned long long)(prof_verts / 300),
                 (unsigned long long)(prof_draw_us / 300), (unsigned long long)(prof_read_us / 300), (unsigned long long)((t1 - t0)));
        prof_frames = prof_draws = prof_verts = prof_draw_us = prof_read_us = 0; prof_last_swap_us = t2;
    }
}

void gpu_gles_release(void) {
    if (egl_display != EGL_NO_DISPLAY) {
        if (eglGetCurrentContext() == egl_context)
            eglMakeCurrent(egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    } else if (context) SDL_GL_MakeCurrent(window, NULL);
}
void gpu_gles_cleanup(void) {
    if (egl_display != EGL_NO_DISPLAY) {
        gpu_gles_release();
        eglDestroySurface(egl_display, egl_surface);
        eglDestroyContext(egl_display, egl_context);
        egl_display = EGL_NO_DISPLAY; egl_surface = EGL_NO_SURFACE; egl_context = EGL_NO_CONTEXT;
    }
    if (context) SDL_GL_DeleteContext(context);
    if (!plat_direct()) SDL_DestroyWindow(window);
    context = NULL; window = NULL;
    free(pixels); free(flipped);
    pixels = flipped = NULL;
}

/* Exercise the actual shaders, orientation, texture upload, alpha, depth and scissor. */
int gpu_gles_self_test(void) {
    sync_read = 1;   /* test sprawdza klatkę zaraz po gpu_swap */
    if (!gpu_init(8, 8)) return 0;
    GpuState s = {0};
    s.shade.cc[0] = s.shade.ac[0] = 1;
    s.shade.mode[1] = 7;
    s.blend[0] = s.blend[2] = 4;
    s.depth_func = 7; s.depth_write = 1;
    s.scissor[2] = s.scissor[3] = 8;
    s.tex = -1;
    GpuVertex quad[6] = {
        {0,0,0.5f,1,0,0,0,0xff0000ff}, {8,0,0.5f,1,1,0,0,0xff0000ff},
        {8,8,0.5f,1,1,1,0,0xff0000ff}, {0,0,0.5f,1,0,0,0,0xff0000ff},
        {8,8,0.5f,1,1,1,0,0xff0000ff}, {0,8,0.5f,1,0,1,0,0xff0000ff}
    };
    gpu_draw(&s, quad, 6);
    gpu_swap();
    if (flipped[0] != 0xff0000ff || flipped[63] != 0xff0000ff) return 0;
    uint32_t texels[4] = {0xff00ff00, 0xff00ff00, 0xffff0000, 0xffff0000};
    s.tex = gpu_texture_create(2, 2, 1);
    gpu_texture_upload(s.tex, texels);
    s.shade.cc[0] = 3; s.shade.cc[1] = 8; s.shade.cc[3] = 1;
    s.shade.tc[0] = s.shade.tc[2] = 1;
    s.shade.mode[0] = 1;
    s.scissor[2] = 4;
    s.depth_func = 1;
    for (int i = 0; i < 6; ++i) if (quad[i].y == 8) quad[i].oow = 0.25f;
    /* A farther quad must fail depth testing. */
    for (int i = 0; i < 6; ++i) quad[i].d = 0.75f;
    gpu_draw(&s, quad, 6);
    gpu_swap();
    if (flipped[0] != 0xff0000ff) return 0;
    for (int i = 0; i < 6; ++i) quad[i].d = 0.25f;
    gpu_draw(&s, quad, 6);
    gpu_swap();
    if (flipped[0] != 0xff00ff00 || flipped[32] != 0xff00ff00 ||
        flipped[56] != 0xffff0000 || flipped[7] != 0xff0000ff) return 0;
    /* Alpha NEVER must reject the closer textured quad. */
    s.shade.mode[1] = 0;
    s.shade.cc[0] = 1; s.shade.cc[2] = 1;
    for (int i = 0; i < 4; ++i) s.shade.constc[i] = 1;
    for (int i = 0; i < 6; ++i) quad[i].d = 0;
    gpu_draw(&s, quad, 6);
    gpu_swap();
    if (flipped[0] != 0xff00ff00) return 0;
    gpu_texture_destroy(s.tex);
    /* Depth differences smaller than one Glide step are coplanar. A
     * higher-precision buffer rejects the overlay, producing headlight stripes. */
    s = (GpuState){0};
    s.shade.cc[0] = s.shade.ac[0] = 1;
    s.shade.mode[1] = 7;
    s.blend[0] = s.blend[2] = 4;
    s.scissor[2] = s.scissor[3] = 8;
    s.depth_func = 7; s.depth_write = 1; s.tex = -1;
    for (int i = 0; i < 6; ++i) { quad[i].d = 0.5f; quad[i].rgba = 0xff0000ff; }
    gpu_draw(&s, quad, 6);
    s.depth_func = 3; s.depth_write = 0;
    for (int i = 0; i < 6; ++i) { quad[i].d = 0.500001f; quad[i].rgba = 0xff00ff00; }
    gpu_draw(&s, quad, 6);
    gpu_swap();
    for (int i = 0; i < 64; ++i) if (flipped[i] != 0xff00ff00) return 0;
    /* A projector crossing q=0 must not reflect its texture behind its origin. */
    uint32_t green = 0xff00ff00;
    s.tex = gpu_texture_create(1, 1, 0);
    gpu_texture_upload(s.tex, &green);
    s.shade.mode[0] = 1;
    s.shade.cc[0] = 3; s.shade.cc[1] = 8; s.shade.cc[3] = 1;
    s.shade.tc[0] = s.shade.tc[2] = 1;
    s.depth_func = -1;
    s.clamp_s = s.clamp_t = 1;
    for (int i = 0; i < 6; ++i) { quad[i].rgba = 0xff0000ff; quad[i].oow = 1; }
    s.shade.mode[0] = 0; s.shade.cc[0] = 1; s.shade.cc[1] = s.shade.cc[3] = 0;
    gpu_draw(&s, quad, 6);
    s.shade.mode[0] = 1; s.shade.cc[0] = 3; s.shade.cc[1] = 8; s.shade.cc[3] = 1;
    for (int i = 0; i < 6; ++i) {
        quad[i].s = quad[i].t = 0.5f;
        quad[i].oow = quad[i].y == 0 ? -1 : 1;
    }
    gpu_draw(&s, quad, 6);
    gpu_swap();
    if (flipped[0] != 0xff0000ff || flipped[56] != green) return 0;
    gpu_texture_destroy(s.tex);
    /* Single-level projector masks keep their dark border under minification. */
    uint32_t mask[64] = {0};
    for (int y = 2; y < 6; ++y) for (int x = 2; x < 6; ++x) mask[y * 8 + x] = green;
    s.tex = gpu_texture_create(8, 8, 0);
    gpu_texture_upload(s.tex, mask);
    s.blend[0] = 1; s.blend[1] = 4;
    s.shade.ac[0] = 3; s.shade.ac[1] = 8; s.shade.ac[3] = 1;
    for (int i = 0; i < 6; ++i) {
        quad[i].oow = 1;
        quad[i].s = quad[i].x;
        quad[i].t = quad[i].y;
    }
    gpu_draw(&s, quad, 6);
    gpu_swap();
    if ((flipped[7] & 0xffffff) != 0x0000ff ||
        (flipped[0] & 0xffffff) != 0x00ffff) return 0;
    gpu_texture_destroy(s.tex);
    /* Resolution switches must also rebuild the depth/color targets. */
    return gpu_init(16, 12);
}
