#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#include "plat.h"
#include "gpu.h"
#include "gpu_gles.h"
#include "input_sdl.h"
#include "rt_host.h"
#include <SDL.h>
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

struct PlatThread { void (*fn)(void *); void *arg; };
struct PlatMutex { SDL_mutex *handle; };
struct PlatCond { SDL_cond *handle; };
struct PlatEvent {
    SDL_mutex *mutex;
    SDL_cond *cond;
    int manual, signaled;
};

volatile uint8_t plat_keys[256];

static const char *game_dir, *save_dir;
static SDL_Window *window;
static SDL_Renderer *renderer;
static SDL_Texture *texture;
static int width, height, running = 1;
static SDL_AudioDeviceID audio;
static SDL_mutex *frame_lock;
static SDL_atomic_t guest_done;
static uint32_t *frame;
static size_t frame_capacity;
static int frame_width, frame_height, frame_pending;

void hle_key_event(uint8_t code, int down);
void hle_audio_mix(float *out, int frames, int rate);

static void log_message(const char *format, va_list args) {
    flockfile(stderr);
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    funlockfile(stderr);
}
void plat_log(const char *format, ...) {
    va_list args;
    va_start(args, format);
    log_message(format, args);
    va_end(args);
}
void plat_fatal(const char *format, ...) {
    va_list args;
    va_start(args, format);
    log_message(format, args);
    va_end(args);
    exit(1);
}
uint64_t plat_ticks_us(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000 + t.tv_nsec / 1000;
}
void plat_sleep_us(uint32_t us) {
    struct timespec t = {us / 1000000, (us % 1000000) * 1000};
    while (nanosleep(&t, &t) < 0 && errno == EINTR) {}
}
void plat_sleep_ms(uint32_t ms) { SDL_Delay(ms); }
void *plat_reserve(size_t size) {
    void *memory = mmap(NULL, size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    return memory == MAP_FAILED ? NULL : memory;
}
static void *new_object(size_t size) {
    void *object = calloc(1, size);
    if (!object) plat_fatal("Brak pamięci");
    return object;
}
static int thread_entry(void *arg) {
    PlatThread *thread = arg;
    thread->fn(thread->arg);
    return 0;
}
PlatThread *plat_thread_start(void (*fn)(void *), void *arg) {
    PlatThread *thread = new_object(sizeof *thread);
    thread->fn = fn;
    thread->arg = arg;
    SDL_Thread *handle = SDL_CreateThread(thread_entry, "nfs4", thread);
    if (!handle) plat_fatal("SDL_CreateThread: %s", SDL_GetError());
    SDL_DetachThread(handle);
    return thread;
}
uint32_t plat_thread_id(void) { return (uint32_t)SDL_ThreadID(); }
PlatMutex *plat_mutex_new(void) {
    PlatMutex *mutex = new_object(sizeof *mutex);
    mutex->handle = SDL_CreateMutex();
    if (!mutex->handle) plat_fatal("SDL_CreateMutex: %s", SDL_GetError());
    return mutex;
}
void plat_mutex_lock(PlatMutex *mutex) { SDL_LockMutex(mutex->handle); }
void plat_mutex_unlock(PlatMutex *mutex) { SDL_UnlockMutex(mutex->handle); }
PlatCond *plat_cond_new(void) {
    PlatCond *cond = new_object(sizeof *cond);
    cond->handle = SDL_CreateCond();
    if (!cond->handle) plat_fatal("SDL_CreateCond: %s", SDL_GetError());
    return cond;
}
int plat_cond_wait(PlatCond *cond, PlatMutex *mutex, uint32_t ms) {
    return SDL_CondWaitTimeout(cond->handle, mutex->handle, ms) == 0;
}
void plat_cond_broadcast(PlatCond *cond) { SDL_CondBroadcast(cond->handle); }
PlatEvent *plat_event_new(int manual, int initial) {
    PlatEvent *event = new_object(sizeof *event);
    event->mutex = SDL_CreateMutex();
    event->cond = SDL_CreateCond();
    if (!event->mutex || !event->cond) plat_fatal("SDL event: %s", SDL_GetError());
    event->manual = manual;
    event->signaled = initial;
    return event;
}
void plat_event_set(PlatEvent *event) {
    SDL_LockMutex(event->mutex);
    event->signaled = 1;
    SDL_CondBroadcast(event->cond);
    SDL_UnlockMutex(event->mutex);
}
void plat_event_reset(PlatEvent *event) {
    SDL_LockMutex(event->mutex);
    event->signaled = 0;
    SDL_UnlockMutex(event->mutex);
}
int plat_event_wait(PlatEvent *event, uint32_t ms) {
    const uint64_t end = plat_ticks_us() / 1000 + ms;
    SDL_LockMutex(event->mutex);
    while (!event->signaled) {
        const uint64_t now = plat_ticks_us() / 1000;
        if (ms == UINT32_MAX) {
            if (SDL_CondWait(event->cond, event->mutex) != 0) break;
        } else if (now >= end ||
                   SDL_CondWaitTimeout(event->cond, event->mutex, (uint32_t)(end - now)) != 0) {
            break;
        }
    }
    const int signaled = event->signaled;
    if (!event->manual) event->signaled = 0;
    SDL_UnlockMutex(event->mutex);
    return signaled;
}
const char *plat_game_dir(void) { return game_dir; }
const char *plat_save_dir(void) { return save_dir; }
const char *plat_mods_dir(void) { return getenv("NFS4_MODS"); }
int plat_mkdir(const char *path) { return mkdir(path, 0755); }
int plat_truncate(FILE *file, long length) {
    return fflush(file) == 0 ? ftruncate(fileno(file), length) : -1;
}
int plat_list_dir(const char *path, void (*fn)(const char *, int, uint32_t, void *), void *ctx) {
    DIR *dir = opendir(path);
    if (!dir) return 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        struct stat info;
        if (fstatat(dirfd(dir), entry->d_name, &info, 0) == 0)
            fn(entry->d_name, S_ISDIR(info.st_mode), (uint32_t)info.st_size, ctx);
    }
    closedir(dir);
    return 1;
}
void plat_local_time(uint16_t out[8]) {
    struct timespec t;
    struct tm local;
    clock_gettime(CLOCK_REALTIME, &t);
    localtime_r(&t.tv_sec, &local);
    const uint16_t fields[] = {local.tm_year + 1900, local.tm_mon + 1, local.tm_wday,
        local.tm_mday, local.tm_hour, local.tm_min, local.tm_sec, t.tv_nsec / 1000000};
    memcpy(out, fields, sizeof fields);
}
/* NFS4_WIDE=<w/h> (np. 1.7778) lub "auto" (proporcje pulpitu); brak = 4:3. Wyścig rysowany do 16:9. */
float plat_wide_aspect(void) {
    const char *e = getenv("NFS4_WIDE");
    if (!e) return 0;
    if (strcmp(e, "auto")) return (float)atof(e);
    SDL_DisplayMode m;
    return SDL_GetDesktopDisplayMode(0, &m) == 0 && m.h > 0 ? (float)m.w / m.h : 0;
}
int plat_frame_cap(void) {
    const char *setting = getenv("NFS4_FPS");
    if (!setting) return 30;
    char *end;
    long value = strtol(setting, &end, 10);
    if (!*setting || *end || value < 0 || value > 120)
        plat_fatal("NFS4_FPS: oczekiwano liczby 0..120");
    return (int)value;
}

static const uint8_t key_codes[SDL_NUM_SCANCODES] = {
    [SDL_SCANCODE_ESCAPE]=0x01, [SDL_SCANCODE_1]=0x02, [SDL_SCANCODE_2]=0x03,
    [SDL_SCANCODE_3]=0x04, [SDL_SCANCODE_4]=0x05, [SDL_SCANCODE_5]=0x06,
    [SDL_SCANCODE_6]=0x07, [SDL_SCANCODE_7]=0x08, [SDL_SCANCODE_8]=0x09,
    [SDL_SCANCODE_9]=0x0A, [SDL_SCANCODE_0]=0x0B, [SDL_SCANCODE_BACKSPACE]=0x0E,
    [SDL_SCANCODE_TAB]=0x0F, [SDL_SCANCODE_Q]=0x10, [SDL_SCANCODE_W]=0x11,
    [SDL_SCANCODE_E]=0x12, [SDL_SCANCODE_R]=0x13, [SDL_SCANCODE_T]=0x14,
    [SDL_SCANCODE_Y]=0x15, [SDL_SCANCODE_U]=0x16, [SDL_SCANCODE_I]=0x17,
    [SDL_SCANCODE_O]=0x18, [SDL_SCANCODE_P]=0x19, [SDL_SCANCODE_RETURN]=0x1C,
    [SDL_SCANCODE_LCTRL]=0x1D, [SDL_SCANCODE_A]=0x1E, [SDL_SCANCODE_S]=0x1F,
    [SDL_SCANCODE_D]=0x20, [SDL_SCANCODE_F]=0x21, [SDL_SCANCODE_G]=0x22,
    [SDL_SCANCODE_H]=0x23, [SDL_SCANCODE_J]=0x24, [SDL_SCANCODE_K]=0x25,
    [SDL_SCANCODE_L]=0x26, [SDL_SCANCODE_LSHIFT]=0x2A, [SDL_SCANCODE_Z]=0x2C,
    [SDL_SCANCODE_X]=0x2D, [SDL_SCANCODE_C]=0x2E, [SDL_SCANCODE_V]=0x2F,
    [SDL_SCANCODE_B]=0x30, [SDL_SCANCODE_N]=0x31, [SDL_SCANCODE_M]=0x32,
    [SDL_SCANCODE_RSHIFT]=0x36, [SDL_SCANCODE_LALT]=0x38, [SDL_SCANCODE_SPACE]=0x39,
    [SDL_SCANCODE_F1]=0x3B, [SDL_SCANCODE_F2]=0x3C, [SDL_SCANCODE_F3]=0x3D,
    [SDL_SCANCODE_F4]=0x3E, [SDL_SCANCODE_F5]=0x3F, [SDL_SCANCODE_F6]=0x40,
    [SDL_SCANCODE_F7]=0x41, [SDL_SCANCODE_F8]=0x42, [SDL_SCANCODE_F9]=0x43,
    [SDL_SCANCODE_F10]=0x44, [SDL_SCANCODE_F11]=0x57, [SDL_SCANCODE_F12]=0x58,
    [SDL_SCANCODE_RCTRL]=0x9D, [SDL_SCANCODE_RALT]=0xB8, [SDL_SCANCODE_HOME]=0xC7,
    [SDL_SCANCODE_UP]=0xC8, [SDL_SCANCODE_PAGEUP]=0xC9, [SDL_SCANCODE_LEFT]=0xCB,
    [SDL_SCANCODE_RIGHT]=0xCD, [SDL_SCANCODE_END]=0xCF, [SDL_SCANCODE_DOWN]=0xD0,
    [SDL_SCANCODE_PAGEDOWN]=0xD1, [SDL_SCANCODE_DELETE]=0xD3
};
int plat_pump(void) {
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        switch (event.type) {
        case SDL_QUIT:
            running = 0;
            break;
        case SDL_KEYDOWN:
        case SDL_KEYUP: {
            const unsigned scan = event.key.keysym.scancode;
            const int down = event.type == SDL_KEYDOWN;
            const uint8_t code = scan < SDL_NUM_SCANCODES ? key_codes[scan] : 0;
            if (code && !event.key.repeat) {
                linux_input_key(code, down);
            }
            break;
        }
        case SDL_MOUSEMOTION:
            plat_mouse_dx += event.motion.xrel;
            plat_mouse_dy += event.motion.yrel;
            break;
        case SDL_MOUSEBUTTONDOWN:
        case SDL_MOUSEBUTTONUP:
            if (event.button.button == SDL_BUTTON_LEFT)
                linux_input_mouse(event.type == SDL_MOUSEBUTTONDOWN);
            break;
        case SDL_WINDOWEVENT:
            if (event.window.event == SDL_WINDOWEVENT_FOCUS_LOST) {
                linux_input_reset();
            }
            break;
        }
    }
    if (!linux_input_poll(hle_glide_in_menu())) running = 0;
    return running;
}
void plat_present(const uint32_t *rgba, int w, int h) {
    if (w <= 0 || h <= 0 || (size_t)w > SIZE_MAX / sizeof *frame / (size_t)h)
        plat_fatal("Nieprawidłowy rozmiar klatki: %d x %d", w, h);
    const size_t bytes = (size_t)w * (size_t)h * sizeof *frame;
    SDL_LockMutex(frame_lock);
    if (bytes > frame_capacity) {
        uint32_t *next = realloc(frame, bytes);
        if (!next) plat_fatal("Brak pamięci na klatkę");
        frame = next;
        frame_capacity = bytes;
    }
    memcpy(frame, rgba, bytes);
    frame_width = w;
    frame_height = h;
    frame_pending = 1;
    SDL_UnlockMutex(frame_lock);
}
static void show_frame(const uint32_t *rgba, int w, int h) {
    if (!texture || w != width || h != height) {
        SDL_DestroyTexture(texture);
        texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA32,
                                    SDL_TEXTUREACCESS_STREAMING, w, h);
        if (!texture || SDL_RenderSetLogicalSize(renderer, w, h) < 0)
            plat_fatal("SDL tekstura: %s", SDL_GetError());
        width = w;
        height = h;
        if (!getenv("NFS4_FULLSCREEN")) {
            SDL_SetWindowSize(window, w, h);
            SDL_SetWindowPosition(window, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED);
        }
    }
    if (SDL_UpdateTexture(texture, NULL, rgba, w * 4) < 0 ||
        SDL_RenderClear(renderer) < 0 ||
        SDL_RenderCopy(renderer, texture, NULL, NULL) < 0)
        plat_fatal("SDL klatka: %s", SDL_GetError());
    SDL_RenderPresent(renderer);
}
static void show_pending_frame(void) {
    SDL_LockMutex(frame_lock);
    if (frame_pending) {
        show_frame(frame, frame_width, frame_height);
        frame_pending = 0;
    }
    SDL_UnlockMutex(frame_lock);
}

static void mix(void *ctx, Uint8 *buffer, int size) {
    (void)ctx;
    hle_audio_mix((float *)buffer, size / (2 * sizeof(float)), 44100);
}
static void init_sdl(void) {
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) < 0)
        plat_fatal("SDL: %s", SDL_GetError());
    window = SDL_CreateWindow("NFS 4 - Linux", SDL_WINDOWPOS_CENTERED,
                             SDL_WINDOWPOS_CENTERED, 640, 480,
                             getenv("NFS4_FULLSCREEN") ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0);
    if (!window) plat_fatal("SDL okno: %s", SDL_GetError());
    renderer = SDL_CreateRenderer(window, -1, 0);
    if (!renderer) plat_fatal("SDL renderer: %s", SDL_GetError());
    frame_lock = SDL_CreateMutex();
    if (!frame_lock) plat_fatal("SDL mutex klatki: %s", SDL_GetError());
    linux_input_init();
    plat_log("SDL video: %s; platforma: %s", SDL_GetCurrentVideoDriver(), SDL_GetPlatform());
}
static void start_audio(void) {
    if (SDL_InitSubSystem(SDL_INIT_AUDIO) == 0) {
        const SDL_AudioSpec desired = {.freq=44100, .format=AUDIO_F32SYS,
                                       .channels=2, .samples=1024, .callback=mix};
        audio = SDL_OpenAudioDevice(NULL, 0, &desired, NULL, 0);
    }
    if (audio) SDL_PauseAudioDevice(audio, 0);
    else plat_log("Dźwięk SDL niedostępny: %s", SDL_GetError());
}

static int guest_main(void *unused) {
    (void)unused;
    const int status = rt_boot() ? 0 : 1;
    gpu_gles_release();
    SDL_AtomicSet(&guest_done, 1);
    return status;
}
static void cleanup_sdl(void) {
    if (audio) SDL_CloseAudioDevice(audio);
    linux_input_cleanup();
    gpu_gles_cleanup();
    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_DestroyMutex(frame_lock);
    free(frame);
    SDL_Quit();
}

static int profile_self_test(void) {
    uint8_t bytes[320], expected[320];
    memset(bytes, 0xa5, sizeof bytes);
    memset(expected, 0xa5, sizeof expected);
    unsetenv("NFS4_HANDHELD");
    hle_glide_fix_config(bytes, 0, sizeof bytes);
    if (memcmp(bytes, expected, sizeof bytes)) return 1;
    expected[0x120] = 0x80; expected[0x121] = 2;
    expected[0x122] = expected[0x123] = 0;
    setenv("NFS4_HANDHELD", "1", 1);
    for (unsigned chunk = 1; chunk <= 17; ++chunk) {
        memset(bytes, 0xa5, sizeof bytes);
        for (unsigned off = 0; off < sizeof bytes; off += chunk) {
            unsigned count = sizeof bytes - off;
            if (count > chunk) count = chunk;
            hle_glide_fix_config(bytes + off, off, count);
        }
        if (memcmp(bytes, expected, sizeof bytes)) return 1;
    }
    puts("NFS4 Linux: handheld profile self-test OK");
    return 0;
}

static int gpu_test_thread(void *unused) {
    (void)unused;
    int ok = gpu_gles_self_test();
    gpu_gles_release();
    return ok;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--profile-self-test")) return profile_self_test();
    if (argc == 2 && !strcmp(argv[1], "--controller-self-test")) {
        init_sdl();
        int status = linux_input_self_test();
        cleanup_sdl();
        puts(status == 0 ? "NFS4 SDL: controller self-test OK" : "NFS4 SDL: controller self-test FAILED/SKIPPED");
        return status;
    }
    if (argc == 2 && !strcmp(argv[1], "--gpu-self-test")) {
        init_sdl();
        gpu_gles_prepare();
        SDL_Thread *test = SDL_CreateThread(gpu_test_thread, "gpu-self-test", NULL);
        if (!test) plat_fatal("SDL wątek testu GPU: %s", SDL_GetError());
        int ok;
        SDL_WaitThread(test, &ok);
        show_pending_frame();
        cleanup_sdl();
        puts(ok ? "NFS4 GLES: GPU self-test OK" : "NFS4 GLES: GPU self-test FAILED");
        return ok ? 0 : 1;
    }
    if (argc == 2 && !strcmp(argv[1], "--self-test")) {
        const size_t size = 16u << 20;
        uint8_t *memory = plat_reserve(size);
        if (!memory || memory[0] || memory[size - 1]) plat_fatal("Test pamięci gościa nie przeszedł");
        memory[0] = 0x5a; memory[size - 1] = 0xa5;
        if (memory[0] != 0x5a || memory[size - 1] != 0xa5 || munmap(memory, size))
            plat_fatal("Test pamięci gościa nie przeszedł");
        init_sdl();
        uint32_t image[4] = {0xff0000ff, 0xff00ff00, 0xffff0000, 0xffffffff};
        plat_present(image, 2, 2);
        show_pending_frame();
        cleanup_sdl();
        puts("NFS4 Linux: SDL self-test OK");
        return 0;
    }
    if (argc != 3) {
        fprintf(stderr, "Użycie: %s <folder gry> <folder zapisów>\n", argv[0]);
        return 2;
    }
    game_dir = argv[1];
    save_dir = argv[2];
    init_sdl();
    gpu_gles_prepare();
    start_audio();
    plat_log("NFS4 Linux, renderer: %s, katalog gry: %s",
             getenv("NFS4_SOFTWARE") ? "programowy (wymuszony)" : "GLES 3D (automatyczny wybór)", game_dir);
    SDL_Thread *guest = SDL_CreateThread(guest_main, "nfs4-guest", NULL);
    if (!guest) plat_fatal("SDL wątek gry: %s", SDL_GetError());
    while (plat_pump() && !SDL_AtomicGet(&guest_done)) {
        show_pending_frame();
        SDL_Delay(2);
    }
    if (!running) exit(0);
    int status;
    SDL_WaitThread(guest, &status);
    cleanup_sdl();
    return status;
}
