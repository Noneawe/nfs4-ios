/* OpenGL ES 3.0 implementation of the shared Glide GPU interface. */
#include "gpu.h"
#include "plat.h"
#include "gpu_gles.h"
#include "gpu_gles_shaders.h"
#include <SDL.h>
#include <GLES3/gl3.h>
#include <EGL/egl.h>
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
static struct { GLuint name; int w, h, mipmapped; } textures[MAX_TEXTURES];

static void check_gl(const char *operation) {
    GLenum error = glGetError();
    if (error != GL_NO_ERROR) plat_fatal("GLES: %s: GL error 0x%04x", operation, error);
}

void gpu_gles_prepare(void) {
    if (getenv("NFS4_SOFTWARE")) return;
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

static int setup_program(void) {
    GLuint vs = compile_shader(GL_VERTEX_SHADER, GPU_GLES_VERTEX);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, GPU_GLES_FRAGMENT);
    if (!vs || !fs) {
        glDeleteShader(vs); glDeleteShader(fs);
        return 0;
    }
    program = glCreateProgram();
    glAttachShader(program, vs); glAttachShader(program, fs);
    glLinkProgram(program);
    glDeleteShader(vs); glDeleteShader(fs);
    GLint ok;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char message[4096];
        glGetProgramInfoLog(program, sizeof message, NULL, message);
        plat_log("GLES link: %s", message);
        glDeleteProgram(program); program = 0;
        return 0;
    }
    glUseProgram(program);
    size_uniform = glGetUniformLocation(program, "vsize");
    glUniform1i(glGetUniformLocation(program, "tex0"), 0);
    GLuint block = glGetUniformBlockIndex(program, "Shade");
    GLint block_size;
    glGetActiveUniformBlockiv(program, block, GL_UNIFORM_BLOCK_DATA_SIZE, &block_size);
    if (block_size != sizeof(GpuShade)) plat_fatal("GLES: niezgodny rozmiar GpuShade");
    glUniformBlockBinding(program, block, 0);
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
        check_gl("texture create");
        return i;
    }
    plat_fatal("GLES: brak wolnych tekstur");
    return -1;
}
void gpu_texture_upload(int id, const uint32_t *rgba) {
    if (id < 0 || id >= MAX_TEXTURES || !textures[id].name) return;
    glBindTexture(GL_TEXTURE_2D, textures[id].name);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, textures[id].w, textures[id].h, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    if (textures[id].mipmapped) glGenerateMipmap(GL_TEXTURE_2D);
    check_gl("texture upload");
}
void gpu_texture_destroy(int id) {
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

void gpu_draw(const GpuState *s, const GpuVertex *v, int n) {
    if (n <= 0) return;
    glBindFramebuffer(GL_FRAMEBUFFER, target);
    glViewport(0, 0, width, height);
    int x0 = s->scissor[0] < 0 ? 0 : s->scissor[0];
    int y0 = s->scissor[1] < 0 ? 0 : s->scissor[1];
    int x1 = s->scissor[2] > width ? width : s->scissor[2];
    int y1 = s->scissor[3] > height ? height : s->scissor[3];
    if (x1 <= x0 || y1 <= y0) return;
    glEnable(GL_SCISSOR_TEST);
    glScissor(x0, height - y1, x1 - x0, y1 - y0);
    if (s->depth_func < 0) glDisable(GL_DEPTH_TEST);
    else { glEnable(GL_DEPTH_TEST); glDepthFunc(GL_NEVER + (s->depth_func & 7)); }
    glDepthMask(s->depth_write ? GL_TRUE : GL_FALSE);
    glEnable(GL_BLEND);
    glBlendFuncSeparate(blend_factor(s->blend[0], 1, 0), blend_factor(s->blend[1], 0, 0),
                        blend_factor(s->blend[2], 1, 1), blend_factor(s->blend[3], 0, 1));
    glUseProgram(program);
    glUniform2f(size_uniform, width, height);
    glBindBuffer(GL_UNIFORM_BUFFER, uniforms);
    glBufferData(GL_UNIFORM_BUFFER, sizeof s->shade, &s->shade, GL_STREAM_DRAW);
    glBindBufferBase(GL_UNIFORM_BUFFER, 0, uniforms);
    glActiveTexture(GL_TEXTURE0);
    if (s->tex >= 0 && s->tex < MAX_TEXTURES && textures[s->tex].name) {
        glBindTexture(GL_TEXTURE_2D, textures[s->tex].name);
        int mips = textures[s->tex].mipmapped;
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
                         s->bilinear ? (mips ? GL_LINEAR_MIPMAP_LINEAR : GL_LINEAR)
                                     : (mips ? GL_NEAREST_MIPMAP_NEAREST : GL_NEAREST));
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, s->bilinear ? GL_LINEAR : GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, s->clamp_s ? GL_CLAMP_TO_EDGE : GL_REPEAT);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, s->clamp_t ? GL_CLAMP_TO_EDGE : GL_REPEAT);
    } else glBindTexture(GL_TEXTURE_2D, 0);
    glBindVertexArray(vao);
    glBindBuffer(GL_ARRAY_BUFFER, vertices);
    glBufferData(GL_ARRAY_BUFFER, (size_t)n * sizeof *v, v, GL_STREAM_DRAW);
    glDrawArrays(GL_TRIANGLES, 0, n);
    check_gl("draw");
}

void gpu_swap(void) {
    /* ponytail: synchronous readback keeps SDL presentation; use shared textures if bandwidth limits FPS. */
    glBindFramebuffer(GL_FRAMEBUFFER, target);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    check_gl("readback");
    for (int y = 0; y < height; ++y)
        memcpy(flipped + (size_t)y * width, pixels + (size_t)(height - 1 - y) * width, (size_t)width * 4);
    plat_present(flipped, width, height);
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
    SDL_DestroyWindow(window);
    context = NULL; window = NULL;
    free(pixels); free(flipped);
    pixels = flipped = NULL;
}

/* Exercise the actual shaders, orientation, texture upload, alpha, depth and scissor. */
int gpu_gles_self_test(void) {
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
