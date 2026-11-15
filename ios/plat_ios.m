// iOS host for the recompiled NFS4: UIKit shell, Metal presentation, touch/gamepad input,
// AudioUnit output and the POSIX side of the platform interface (plat.h).
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <pthread.h>
#include <stdatomic.h>
#include "power_policy.h"
#include "log_sink.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>
#include <time.h>
#include <stdarg.h>
#include <mach/mach_time.h>
#include <signal.h>
#include <ctype.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <sys/ucontext.h>
#include <os/proc.h>
#include "plat.h"
#include "rt_host.h"
#import "port_save_sync.h"

void hle_key_event(uint8_t sc, int down);
id<MTLTexture> gpu_metal_display_texture(uint64_t *serial);
int g_screen_height_px;            // device height in landscape, used for render upscaling
int g_screen_width_px;             // width the picture may use (beside the Dynamic Island), the same in pixels
int g_msaa_samples = 4;            // in-app setting, read by gpu_metal.m
static float g_wide_aspect;        // aspect of the area beside the Dynamic Island, 0 = keep 4:3
static BOOL g_overlay_editing;     // overlay editor open: touches move controls, nothing reaches the game
float plat_wide_aspect(void) { return g_wide_aspect; }
void hle_audio_mix(float *out, int frames, int rate);

volatile uint8_t plat_keys[256];
static char g_game[1024], g_save[1024];
static Nfs4LogSink g_log;
static int g_console_logging;
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

// ---------------------------------------------------------------- logging / time

void plat_log(const char *fmt, ...) {
    char buf[4096];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    pthread_mutex_lock(&g_log_lock);
    nfs4_log_append(&g_log,buf,4u<<20);
    pthread_mutex_unlock(&g_log_lock);
    if(g_console_logging || !strncmp(buf,"FATAL:",6) || !strncmp(buf,"CRASH:",6))NSLog(@"%s",buf);
}

void plat_fatal(const char *fmt, ...) {
    char buf[4096];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    plat_log("FATAL: %s", buf);
    NSString *msg = [NSString stringWithUTF8String:buf];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"NFS4Fatal" object:msg];
    });
    for (;;) sleep(1000);   // keep the message on screen; the game threads are dead anyway
}

// ---------------------------------------------------------------- crash report
// A crash writes where it happened to nfs4host.log: the host addresses as offsets into this image
// (looked up in the CI link map, NFS4-LinkMap.txt) and the guest thread's last API and call stack.

static void log_host_addr(const char *label, uintptr_t p) {
    Dl_info di;
    if (dladdr((void *)p, &di) && di.dli_fbase)
        plat_log("  %s %p = %s+0x%lx (%s)", label, (void *)p, strrchr(di.dli_fname, '/') ? strrchr(di.dli_fname, '/') + 1 : di.dli_fname,
                 (unsigned long)(p - (uintptr_t)di.dli_fbase), di.dli_sname ? di.dli_sname : "?");
    else
        plat_log("  %s %p", label, (void *)p);
}

static void crash_handler(int sig, siginfo_t *si, void *ctx) {
    ucontext_t *uc = ctx;
    plat_log("CRASH: signal %d, fault address %p", sig, si->si_addr);
    log_host_addr("pc", (uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss));
    log_host_addr("lr", (uintptr_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss));
    void *bt[48];
    int n = backtrace(bt, 48);
    for (int i = 0; i < n; i++) {
        char label[8];
        snprintf(label, sizeof label, "#%d", i);
        log_host_addr(label, (uintptr_t)bt[i]);
    }
    Cpu *c = rt_current_cpu();
    if (c) {
        plat_log("guest thread %u, last API %s, esp %08X", c->thread_id, c->hle_name ? c->hle_name : "-", c->esp);
        rt_backtrace(c);
    }
    rt_dump_threads();
    signal(sig, SIG_DFL);                      // let iOS write its own crash report too
    raise(sig);
}

static void objc_exception_handler(NSException *e) {
    plat_log("CRASH: Objective-C exception %s: %s", e.name.UTF8String, e.reason.UTF8String);
    for (NSString *s in e.callStackSymbols) plat_log("  %s", s.UTF8String);
}

static void install_crash_handlers(void) {
    struct sigaction sa = { 0 };
    sa.sa_sigaction = crash_handler;
    sa.sa_flags = SA_SIGINFO;
    int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };
    for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; i++) sigaction(sigs[i], &sa, NULL);
    NSSetUncaughtExceptionHandler(objc_exception_handler);
}

static uint64_t raw_ticks_us(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom / 1000;
}

// Game pause (E:\ios-ports\README.md section 10), as in the FF7 port: while the app is inactive or a window is
// over the game (settings and its choices, the PC transfer screen, the button editor, a save sync) the game's
// clock stands still, the game threads wait in plat_sleep_* (the swap pacing sleeps there every frame) and the
// sound is silent. The clock then goes on from where it stopped, so nothing jumps.
static int g_app_active = 1, g_ui_pause;
static int g_running = 1;
static pthread_mutex_t g_clock_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_paused_us, g_pause_begin;

uint64_t plat_ticks_us(void) {
    pthread_mutex_lock(&g_clock_lock);
    uint64_t now = __atomic_load_n(&g_running, __ATOMIC_RELAXED) ? raw_ticks_us() : g_pause_begin;
    uint64_t result = now >= g_paused_us ? now - g_paused_us : 0;
    pthread_mutex_unlock(&g_clock_lock);
    return result;
}
static void update_running_locked(void) {
    int old = __atomic_load_n(&g_running, __ATOMIC_RELAXED);
    int run = g_app_active && !g_ui_pause;
    if (old == run) return;
    uint64_t now = raw_ticks_us();
    if (run) { if (now >= g_pause_begin) g_paused_us += now - g_pause_begin; }
    else g_pause_begin = now;
    __atomic_store_n(&g_running, run, __ATOMIC_RELEASE);
}
static void set_app_active(int active) {
    pthread_mutex_lock(&g_clock_lock);
    g_app_active = active;
    update_running_locked();
    pthread_mutex_unlock(&g_clock_lock);
}
static void set_ui_pause(int pause) {
    pthread_mutex_lock(&g_clock_lock);
    int changed = g_ui_pause != pause;
    g_ui_pause = pause;
    update_running_locked();
    pthread_mutex_unlock(&g_clock_lock);
    if (changed) plat_log("game %s for a window", pause ? "paused" : "resumed");
}
static int game_running_now(void) { return __atomic_load_n(&g_running, __ATOMIC_ACQUIRE); }

void plat_sleep_ms(uint32_t ms) {
    while (!game_running_now()) usleep(50000);
    if (!ms) { sched_yield(); return; }
    usleep(ms * 1000);
}
void plat_sleep_us(uint32_t us) {
    while (!game_running_now()) usleep(50000);
    usleep(us);
}

// The game thread only reads an atomic cap. UIKit notifications update power
// state on the main thread, so no Objective-C thermal query is made per swap.
static int g_fps_setting = 60, g_thermal_state, g_low_power;
static atomic_int g_effective_frame_cap = 60;
static Nfs4PowerPolicy g_power_policy;
static void update_power_cap(void) {
    int cap=nfs4_power_cap(&g_power_policy,g_fps_setting,g_thermal_state,g_low_power,g_app_active,plat_ticks_us());
    cap=nfs4_scene_cap(cap,hle_glide_in_menu());
    int previous=atomic_exchange_explicit(&g_effective_frame_cap,cap,memory_order_relaxed);
    if(previous!=cap)plat_log("power: %d fps, thermal %d, low power %d, active %d",cap,g_thermal_state,g_low_power,g_app_active);
}
int plat_frame_cap(void) { return atomic_load_explicit(&g_effective_frame_cap,memory_order_relaxed); }

void *plat_reserve(size_t size) {
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    return p == MAP_FAILED ? NULL : p;
}

// ---------------------------------------------------------------- threads / sync

struct PlatThread { pthread_t t; };
typedef struct { void (*fn)(void *); void *arg; } Tramp;
static void *tramp(void *p) { Tramp t = *(Tramp *)p; free(p); t.fn(t.arg); return NULL; }

PlatThread *plat_thread_start(void (*fn)(void *), void *arg) {
    Tramp *t = malloc(sizeof *t);
    t->fn = fn; t->arg = arg;
    PlatThread *pt = malloc(sizeof *pt);
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setstacksize(&a, 16u << 20);   // recompiled code nests one C frame per guest call
    pthread_create(&pt->t, &a, tramp, t);
    pthread_attr_destroy(&a);
    return pt;
}
uint32_t plat_thread_id(void) { uint64_t id; pthread_threadid_np(NULL, &id); return (uint32_t)id; }

struct PlatMutex { pthread_mutex_t m; };
PlatMutex *plat_mutex_new(void) { PlatMutex *m = malloc(sizeof *m); pthread_mutex_init(&m->m, NULL); return m; }
void plat_mutex_lock(PlatMutex *m) { pthread_mutex_lock(&m->m); }
void plat_mutex_unlock(PlatMutex *m) { pthread_mutex_unlock(&m->m); }

struct PlatCond { pthread_cond_t c; };
PlatCond *plat_cond_new(void) { PlatCond *c = malloc(sizeof *c); pthread_cond_init(&c->c, NULL); return c; }
static struct timespec deadline_after(uint32_t ms) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += ms / 1000;
    ts.tv_nsec += (long)(ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
    return ts;
}
int plat_cond_wait(PlatCond *c, PlatMutex *m, uint32_t ms) {
    if (ms == 0xFFFFFFFFu) { pthread_cond_wait(&c->c, &m->m); return 1; }
    struct timespec ts = deadline_after(ms);
    return pthread_cond_timedwait(&c->c, &m->m, &ts) == 0;
}
void plat_cond_broadcast(PlatCond *c) { pthread_cond_broadcast(&c->c); }

struct PlatEvent { pthread_mutex_t m; pthread_cond_t c; int manual, set; };
PlatEvent *plat_event_new(int manual, int initial) {
    PlatEvent *e = calloc(1, sizeof *e);
    pthread_mutex_init(&e->m, NULL);
    pthread_cond_init(&e->c, NULL);
    e->manual = manual; e->set = initial;
    return e;
}
void plat_event_set(PlatEvent *e) {
    pthread_mutex_lock(&e->m); e->set = 1; pthread_cond_broadcast(&e->c); pthread_mutex_unlock(&e->m);
}
void plat_event_reset(PlatEvent *e) { pthread_mutex_lock(&e->m); e->set = 0; pthread_mutex_unlock(&e->m); }
int plat_event_wait(PlatEvent *e, uint32_t ms) {
    pthread_mutex_lock(&e->m);
    struct timespec ts = deadline_after(ms == 0xFFFFFFFFu ? 0 : ms);
    while (!e->set) {
        if (ms == 0xFFFFFFFFu) pthread_cond_wait(&e->c, &e->m);
        else if (pthread_cond_timedwait(&e->c, &e->m, &ts) != 0) break;
    }
    int ok = e->set;
    if (ok && !e->manual) e->set = 0;
    pthread_mutex_unlock(&e->m);
    return ok;
}

// ---------------------------------------------------------------- files

const char *plat_game_dir(void) { return g_game; }
const char *plat_save_dir(void) { return g_save; }
static char g_mods[1024];
const char *plat_mods_dir(void) { return g_mods[0] ? g_mods : NULL; }
int plat_mkdir(const char *p) { return mkdir(p, 0755); }
int plat_truncate(FILE *f, long size) { return ftruncate(fileno(f), size); }

int plat_list_dir(const char *path, void (*fn)(const char *, int, uint32_t, void *), void *ctx) {
    DIR *d = opendir(path);
    if (!d) return 0;
    struct dirent *e;
    fn(".", 1, 0, ctx);
    fn("..", 1, 0, ctx);
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char full[2048];
        snprintf(full, sizeof full, "%s/%s", path, e->d_name);
        struct stat st;
        if (stat(full, &st) != 0) continue;
        fn(e->d_name, S_ISDIR(st.st_mode), (uint32_t)st.st_size, ctx);
    }
    closedir(d);
    return 1;
}

void plat_local_time(uint16_t out[8]) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm;
    localtime_r(&ts.tv_sec, &tm);
    out[0] = (uint16_t)(tm.tm_year + 1900); out[1] = (uint16_t)(tm.tm_mon + 1); out[2] = (uint16_t)tm.tm_wday;
    out[3] = (uint16_t)tm.tm_mday; out[4] = (uint16_t)tm.tm_hour; out[5] = (uint16_t)tm.tm_min;
    out[6] = (uint16_t)tm.tm_sec; out[7] = (uint16_t)(ts.tv_nsec / 1000000);
}

// ---------------------------------------------------------------- video

static pthread_mutex_t g_frame_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t *g_frame;
static int g_fw, g_fh;
static volatile int g_frame_serial;

void plat_present(const uint32_t *rgba, int w, int h) {
    pthread_mutex_lock(&g_frame_lock);
    if (w != g_fw || h != g_fh) { free(g_frame); g_frame = malloc((size_t)w * h * 4); g_fw = w; g_fh = h; }
    memcpy(g_frame, rgba, (size_t)w * h * 4);
    g_frame_serial++;
    pthread_mutex_unlock(&g_frame_lock);
}

int plat_pump(void) { return 1; }

// ---------------------------------------------------------------- audio

static OSStatus audio_render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                             UInt32 frames, AudioBufferList *io) {
    (void)ref; (void)flags; (void)ts; (void)bus;
    // paused: the play cursors stand with the clock, so mixing would repeat the same few milliseconds
    if (!game_running_now()) { memset(io->mBuffers[0].mData, 0, (size_t)frames * 2 * sizeof(float)); return noErr; }
    hle_audio_mix((float *)io->mBuffers[0].mData, (int)frames, 44100);
    return noErr;
}

// Sound (README section 10): Playback, so the ring/silent switch does not mute the game (it did under Ambient).
// "다른 앱 소리와 함께" (default on) mixes other apps' audio in. The game's music cannot be told apart from its
// effects here (every sound is a DirectSound buffer the game streams into), so music is not silenced on its own
// while another app plays; with mixing on both simply play together.
static NSString *const kMixAudio = @"mixOtherAudio";
static BOOL mix_audio_on(void) {
    NSNumber *v = [[NSUserDefaults standardUserDefaults] objectForKey:kMixAudio];
    return v ? v.boolValue : YES;
}
static void apply_audio_mix(void) {
    BOOL mix = mix_audio_on();
    NSError *err = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    if (![s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault
                options:mix ? AVAudioSessionCategoryOptionMixWithOthers : 0 error:&err])
        plat_log("audio: setCategory failed: %s", err.localizedDescription.UTF8String);
    plat_log("audio: category %s, mix with others %s, other audio playing %d", s.category.UTF8String, mix ? "on" : "off",
             (int)s.secondaryAudioShouldBeSilencedHint);
}

static void start_audio(void) {
    apply_audio_mix();
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    AudioComponentDescription d = { kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0 };
    AudioComponent comp = AudioComponentFindNext(NULL, &d);
    AudioUnit unit;
    if (AudioComponentInstanceNew(comp, &unit) != noErr) return;
    AudioStreamBasicDescription f = { 0 };
    f.mSampleRate = 44100; f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mChannelsPerFrame = 2; f.mBitsPerChannel = 32; f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 8; f.mBytesPerPacket = 8;
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
    AURenderCallbackStruct cb = { audio_render, NULL };
    AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    AudioUnitInitialize(unit);
    AudioOutputUnitStart(unit);
    // An interruption (call, Siri, alarm) stops the unit: start it again once the session is ours, and when
    // the app comes back to the front (an interruption that ended in the background sends no "ended").
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    void (^restart)(const char *) = ^(const char *why) {
        NSError *err = nil;
        [[AVAudioSession sharedInstance] setActive:YES error:&err];
        OSStatus st = AudioOutputUnitStart(unit);
        plat_log("audio: output restarted (%s), status %d%s%s", why, (int)st, err ? ", session: " : "",
                 err ? err.localizedDescription.UTF8String : "");
    };
    __block BOOL interrupted = NO;             // the unit is stopped and not yet started again
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
        plat_log("audio: interruption %s", type == AVAudioSessionInterruptionTypeBegan ? "began" : "ended");
        if (type == AVAudioSessionInterruptionTypeBegan) interrupted = YES;
        else if (g_app_active) { interrupted = NO; restart("interruption ended"); }
    }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (interrupted) { interrupted = NO; restart("app active"); }
    }];
}

// Heat and frame pacing on record (README section 10): once a minute for the first 15 minutes of play, then
// every 5. The frame times themselves are in the "glide: ... frames" lines (hle_glide.c, every 300 frames).
static void start_thermal_log(void) {
    __block int minutes = 0;
    [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer *t) {
        if (!game_running_now()) return;       // paused or in the background: not play time
        minutes++;
        if (minutes > 15 && minutes % 5) return;
        NSProcessInfo *p = NSProcessInfo.processInfo;
        plat_log("thermal: %d min of play, state %ld, low power %d, cap %d fps, %s", minutes, (long)p.thermalState,
                 (int)p.lowPowerModeEnabled, plat_frame_cap(), hle_glide_in_menu() ? "menu" : "race");
    }];
}

// ---------------------------------------------------------------- input helpers

// The race reads Player 1 from the joystick ("Touch Wheel", hle_dinput.c): with a joystick present
// the game binds steering to its X axis, accelerate/brake to Y and the other actions to buttons
// A..H (look behind stays on the keyboard). So every key the overlay or the pad presses is also
// given to the joystick, and the analog sources (touch stick, pad stick and triggers) add to it.
// On menu screens the keys alone navigate, and the joystick rests so nothing moves twice.
static float g_touch_steer, g_pad_steer, g_pad_throttle;   // -1 .. 1, set on the main thread
static BOOL g_cruise;                                       // auto-accelerate toggle (set_cruise)
static BOOL g_cruise_paused;                                // on, but the brake is held
static void cruise_glow(void);

static void update_joy(void) {
    if (hle_glide_in_menu()) { plat_joy_x = plat_joy_y = 0; plat_joy_buttons = 0; return; }
    // braking pauses auto-accelerate; letting go of the brake resumes it
    BOOL braking = plat_keys[0xD0] || g_pad_throttle > 0.2f;
    BOOL paused = g_cruise && braking;
    if (paused != g_cruise_paused) { g_cruise_paused = paused; cruise_glow(); }
    float kx = (plat_keys[0xCD] ? 1.f : 0.f) - (plat_keys[0xCB] ? 1.f : 0.f);       // arrows
    float ky = (plat_keys[0xD0] ? 1.f : 0.f) - (plat_keys[0xC8] || (g_cruise && !braking) ? 1.f : 0.f);   // up = accelerate
    float x = kx + g_touch_steer + g_pad_steer, y = ky + g_pad_throttle;
    plat_joy_x = x < -1 ? -1 : x > 1 ? 1 : x;
    plat_joy_y = y < -1 ? -1 : y > 1 ? 1 : y;
    // buttons A..H: handbrake, camera, shift up, shift down, horn/siren, reset, spike strip, lights
    static const uint8_t button_keys[8] = { 0x39, 0x2E, 0x1E, 0x2C, 0x23, 0x13, 0x1F, 0x26 };
    uint32_t b = 0;
    for (int i = 0; i < 8; i++) if (plat_keys[button_keys[i]]) b |= 1u << i;
    plat_joy_buttons = b;
}

static void key(uint8_t sc, int down) {
    if (!!plat_keys[sc] == !!down) return;
    plat_keys[sc] = down ? 0x80 : 0;
    hle_key_event(sc, down);
    update_joy();
}

// ---------------------------------------------------------------- game thread

static volatile int g_game_running;

static void game_main(void *p) {
    (void)p;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);   // the game's main loop: frames come out more evenly
    g_game_running = 1;
    rt_boot();
    plat_log("game ended");
    exit(0);
}

// Find a path ignoring case (the game folder comes from Windows, iOS file systems are case sensitive).
static NSString *find_ci(NSString *dir, NSString *name) {
    for (NSString *e in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil])
        if ([e caseInsensitiveCompare:name] == NSOrderedSame) return [dir stringByAppendingPathComponent:e];
    return nil;
}

// Data root shared by the iOS port apps (E:\ios-ports\README.md): the app's Documents, or
// <LiveContainer Documents>/Games/<PortDataFolder> inside LiveContainer, whose per-app
// Data/Application/<UUID> folders are hard to find in the Files app.
static NSString *port_data_root(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        root = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *home = NSHomeDirectory();
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"^(.*/(Documents|LiveContainer))/Data/Application/[0-9A-Fa-f-]{36}/?$"
                                 options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:home options:0 range:NSMakeRange(0, home.length)];
        if (m) {
            NSDictionary *info = NSBundle.mainBundle.infoDictionary;
            NSString *name = info[@"PortDataFolder"] ?: info[@"CFBundleName"] ?: @"Game";
            root = [[[home substringWithRange:[m rangeAtIndex:1]] stringByAppendingPathComponent:@"Games"]
                    stringByAppendingPathComponent:name];
        }
        [NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:@"game"]
                                withIntermediateDirectories:YES attributes:nil error:nil];
        // The game and mod data (hundreds of MB) come back from the PC, so they stay out of the iCloud/computer
        // backup, as in the FF7 port; the saves are in the sibling save folder and stay in it.
        for (NSString *name in @[ @"game", @"mods" ]) {
            NSString *p = [root stringByAppendingPathComponent:name];
            [NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
            [[NSURL fileURLWithPath:p isDirectory:YES] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
        }
    });
    return root;
}

// The PC game is copied into <root>/game; the folder holding nfs4.exe is searched breadth-first
// a few levels down (an unzipped release lands one or two folders deeper). Older builds used the
// root itself, which is searched last.
static NSString *locate_game_dir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = port_data_root();
    for (NSString *top in @[ [root stringByAppendingPathComponent:@"game"], root ]) {
        NSMutableArray<NSString *> *level = [NSMutableArray arrayWithObject:top];
        for (int depth = 0; depth <= 6 && level.count; depth++) {
            NSMutableArray<NSString *> *next = [NSMutableArray array];
            for (NSString *dir in level) {
                if (find_ci(dir, @"nfs4.exe")) return dir;
                for (NSString *e in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                    NSString *p = [dir stringByAppendingPathComponent:e];
                    BOOL isDir = NO;
                    // a dot folder is a copy from Files still in progress (pickFolder), never the game
                    if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir && ![e isEqualToString:@"save"] && ![e hasPrefix:@"."])
                        [next addObject:p];
                }
            }
            level = next;
        }
    }
    return nil;
}

// ================================================================ UI

@interface GameView : MTKView <MTKViewDelegate>
@property(nonatomic) id<MTLCommandQueue> queue;
@property(nonatomic) id<MTLRenderPipelineState> pipeline;
@property(nonatomic) id<MTLTexture> texture;
@property(nonatomic) int lastSerial;
@property(nonatomic) uint64_t lastGPUSerial;
@property(nonatomic) BOOL hasPresented;
@property(nonatomic) CGRect gameRect;     // where the 4:3 picture is drawn, in points
@end

static NSString *const kShader =
    @"#include <metal_stdlib>\nusing namespace metal;\n"
     "struct V { float4 p [[position]]; float2 uv; };\n"
     "vertex V vs(uint id [[vertex_id]], constant float4 &r [[buffer(0)]]) {\n"
     "  float2 q = float2(id & 1, id >> 1);\n"
     "  V o; o.uv = float2(q.x, q.y);\n"
     "  o.p = float4(r.x + q.x * r.z, r.y - q.y * r.w, 0, 1); return o; }\n"
     "fragment float4 fs(V i [[stage_in]], texture2d<float> t [[texture(0)]]) {\n"
     "  constexpr sampler s(filter::linear); return float4(t.sample(s, i.uv).rgb, 1); }\n";

@implementation GameView

- (instancetype)initWithFrame:(CGRect)f {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:f device:dev];
    self.delegate = self;
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.preferredFramesPerSecond = 60;
    self.multipleTouchEnabled = YES;
    _queue = [dev newCommandQueue];
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kShader options:nil error:&err];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = self.colorPixelFormat;
    _pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    [self powerStateChanged:nil];
    NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
    for(NSString *name in @[NSProcessInfoThermalStateDidChangeNotification, NSProcessInfoPowerStateDidChangeNotification,
                           UIApplicationWillResignActiveNotification, UIApplicationDidBecomeActiveNotification]) {
        [nc addObserver:self selector:@selector(powerStateChanged:) name:name object:nil];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)powerStateChanged:(NSNotification *)notification {
    // All observers are created by UIKit on the main thread.
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self powerStateChanged:notification]; });
        return;
    }
    g_thermal_state=(int)NSProcessInfo.processInfo.thermalState;
    g_low_power=NSProcessInfo.processInfo.lowPowerModeEnabled;
    if([notification.name isEqualToString:UIApplicationWillResignActiveNotification]) {
        set_app_active(0); self.paused=YES;   // the game stops with the clock (plat_ticks_us)
    } else if([notification.name isEqualToString:UIApplicationDidBecomeActiveNotification]) {
        set_app_active(1); self.paused=NO; _hasPresented=NO;
    }
    update_power_cap();
    self.preferredFramesPerSecond=plat_frame_cap();
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size { _hasPresented=NO; }

- (void)drawInMTKView:(MTKView *)view {
    update_power_cap();
    int cap=plat_frame_cap();
    if(view.preferredFramesPerSecond!=cap)view.preferredFramesPerSecond=cap;
    uint64_t gpuSerial=0;
    id<MTLTexture> gpuTex = gpu_metal_display_texture(&gpuSerial);
    if(gpuTex && _hasPresented && _lastGPUSerial==gpuSerial)return;
    pthread_mutex_lock(&g_frame_lock);
    if (!gpuTex && g_frame && g_frame_serial != _lastSerial) {
        if (!_texture || (int)_texture.width != g_fw || (int)_texture.height != g_fh) {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          width:g_fw height:g_fh mipmapped:NO];
            _texture = [self.device newTextureWithDescriptor:td];
        }
        [_texture replaceRegion:MTLRegionMake2D(0, 0, g_fw, g_fh) mipmapLevel:0 withBytes:g_frame bytesPerRow:g_fw * 4];
        _lastSerial = g_frame_serial;
    }
    pthread_mutex_unlock(&g_frame_lock);

    MTLRenderPassDescriptor *rp = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!rp || !drawable) return;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    id<MTLTexture> show = gpuTex ? gpuTex : _texture;
    if (show) {
        // Fit the picture at its own aspect (4:3 menus, 16:9 races) inside the area left and
        // right of the Dynamic Island; top/bottom insets (home indicator) are ignored.
        CGSize s = self.bounds.size;
        UIEdgeInsets in = self.safeAreaInsets;
        CGRect safe = CGRectMake(in.left, 0, s.width - in.left - in.right, s.height);
        CGFloat want = (CGFloat)show.width / (CGFloat)show.height, gw, gh;
        if (safe.size.width / safe.size.height > want) { gh = safe.size.height; gw = gh * want; }
        else { gw = safe.size.width; gh = gw / want; }
        CGRect g = CGRectMake(CGRectGetMidX(safe) - gw / 2, CGRectGetMidY(safe) - gh / 2, gw, gh);
        _gameRect = g;
        float rect[4] = { (float)(g.origin.x / s.width * 2 - 1), (float)(1 - g.origin.y / s.height * 2),
                          (float)(gw / s.width * 2), (float)(gh / s.height * 2) };
        [enc setRenderPipelineState:_pipeline];
        [enc setVertexBytes:rect length:sizeof rect atIndex:0];
        [enc setFragmentTexture:show atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
    _lastGPUSerial=gpuSerial; _hasPresented=YES;
}

// a tap on the picture becomes a mouse click at the corresponding game position
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (g_overlay_editing) return;
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    int gw = 0, gh = 0;
    hle_glide_size(&gw, &gh);                  // the game's current Glide resolution
    if (CGRectContainsPoint(_gameRect, p) && gw) {
        int x = (int)((p.x - _gameRect.origin.x) / _gameRect.size.width * gw);
        int y = (int)((p.y - _gameRect.origin.y) / _gameRect.size.height * gh);
        plat_mouse_click_at(x, y);
    }
}
@end

// Overlay look: frosted translucent "glass" with a hairline edge, white SF Symbols and small captions.
static UIImage *symbol(NSString *name, NSString *fallback, CGFloat pt) {
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightSemibold];
    UIImage *img = [UIImage systemImageNamed:name withConfiguration:c];
    if (!img && fallback) img = [UIImage systemImageNamed:fallback withConfiguration:c];   // older iOS
    return img;
}

static void pin_edges(UIView *v, UIView *to) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [v.leadingAnchor constraintEqualToAnchor:to.leadingAnchor], [v.trailingAnchor constraintEqualToAnchor:to.trailingAnchor],
        [v.topAnchor constraintEqualToAnchor:to.topAnchor], [v.bottomAnchor constraintEqualToAnchor:to.bottomAnchor],
    ]];
}

static UIView *glass_in(UIView *parent, CGFloat radius) {
    UIVisualEffectView *v = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    v.userInteractionEnabled = NO;
    v.layer.cornerRadius = radius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.borderWidth = 0.5;
    v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
    v.clipsToBounds = YES;
    [parent insertSubview:v atIndex:0];
    pin_edges(v, parent);
    return v;
}

// Control face, the same as the RVGL port (E:\rvgl-ios\app\TouchControls.m): a thin white ring over a
// dark see-through disc (a capsule when wider than tall). The shadow has a path, so it is not worked out
// from the layer's pixels on every frame over the game.
@interface RoundFace : UIView
@end
@implementation RoundFace
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat r = fmin(self.bounds.size.width, self.bounds.size.height) / 2;
    self.layer.cornerRadius = r;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:r].CGPath;
}
@end
static UIView *face_in(UIView *parent) {
    RoundFace *v = [RoundFace new];
    v.userInteractionEnabled = NO;
    v.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
    v.layer.borderWidth = 2;
    v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.85].CGColor;
    v.layer.shadowColor = UIColor.blackColor.CGColor;
    v.layer.shadowOpacity = 0.3;
    v.layer.shadowRadius = 3;
    v.layer.shadowOffset = CGSizeMake(0, 1);
    [parent insertSubview:v atIndex:0];
    pin_edges(v, parent);
    return v;
}

// a badge on the ring for the gamepad input that does the same thing: face buttons in their usual
// colours, the rest as a dark pill
static UILabel *badge_in(UIView *parent, NSString *text) {
    NSDictionary *face = @{ @"A" : [UIColor colorWithRed:0.30 green:0.76 blue:0.36 alpha:1],
                            @"B" : [UIColor colorWithRed:0.92 green:0.26 blue:0.24 alpha:1],
                            @"X" : [UIColor colorWithRed:0.22 green:0.50 blue:0.98 alpha:1],
                            @"Y" : [UIColor colorWithRed:0.97 green:0.76 blue:0.16 alpha:1] };
    UILabel *l = [UILabel new];
    l.text = text;
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = UIColor.whiteColor;
    l.font = [UIFont systemFontOfSize:text.length > 1 ? 10 : 12 weight:UIFontWeightBold];
    l.backgroundColor = face[text] ?: [UIColor colorWithWhite:0.12 alpha:0.9];
    l.layer.borderWidth = face[text] ? 0 : 1;
    l.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
    l.bounds = CGRectMake(0, 0, text.length > 1 ? 28 : 22, 22);
    l.layer.cornerRadius = 11;
    l.layer.masksToBounds = YES;
    l.userInteractionEnabled = NO;
    [parent addSubview:l];
    return l;
}

// a white icon with an optional name under it, centred in its parent
static void icon_in(UIView *parent, UIImage *img, NSString *caption) {
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.tintColor = UIColor.whiteColor;
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[ iv ]];
    st.axis = UILayoutConstraintAxisVertical;
    st.alignment = UIStackViewAlignmentCenter;
    st.spacing = 2;
    st.userInteractionEnabled = NO;
    if (caption) {
        UILabel *l = [UILabel new];
        l.text = caption;
        l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        l.textColor = [UIColor colorWithWhite:1 alpha:0.95];
        [st addArrangedSubview:l];
    }
    // readable over bright scenery; rasterised once, the icon and its name do not change
    st.layer.shadowColor = UIColor.blackColor.CGColor;
    st.layer.shadowOpacity = 0.5;
    st.layer.shadowRadius = 2;
    st.layer.shadowOffset = CGSizeMake(0, 1);
    st.layer.shouldRasterize = YES;
    st.layer.rasterizationScale = UIScreen.mainScreen.scale;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [parent addSubview:st];
    [st.centerXAnchor constraintEqualToAnchor:parent.centerXAnchor].active = YES;
    [st.centerYAnchor constraintEqualToAnchor:parent.centerYAnchor].active = YES;
}

static UIImpactFeedbackGenerator *tap_haptic(void) {
    static UIImpactFeedbackGenerator *h;
    if (!h) h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    return h;
}

// what the overlay editor changes on every control
@protocol OverlayItem
@property(nonatomic) CGFloat scale;      // applied as a transform, so icons and corners scale too
@property(nonatomic) BOOL haptic;
@property(nonatomic) CGFloat radius;
@end

// on-screen buttons that hold a DirectInput scan code while touched
@interface KeyButton : UIView <OverlayItem>
@property(nonatomic) uint8_t scan;
@property(nonatomic) UIView *glow;
@property(nonatomic) UILabel *badge;
@property(nonatomic, copy) NSString *badgeText;   // the gamepad input shown on the ring (badge_in)
@property(nonatomic) CGFloat slop;       // extra touch margin around the circle (pedals)
@end

static void set_cruise(BOOL on);

@implementation KeyButton
@synthesize scale = _scale, haptic = _haptic, radius = _radius;
- (instancetype)initWithSymbol:(UIImage *)img caption:(NSString *)caption scan:(uint8_t)scan radius:(CGFloat)r {
    self = [super initWithFrame:CGRectZero];
    _scan = scan;
    _scale = 1;
    _haptic = YES;
    _radius = r;
    face_in(self);
    _glow = [RoundFace new];
    _glow.backgroundColor = UIColor.whiteColor;
    _glow.alpha = 0;
    _glow.userInteractionEnabled = NO;
    [self addSubview:_glow];
    pin_edges(_glow, self);
    icon_in(self, img, caption);
    self.multipleTouchEnabled = YES;
    return self;
}
- (void)setBadgeText:(NSString *)text {
    _badgeText = [text copy];
    [_badge removeFromSuperview];
    _badge = text ? badge_in(self, text) : nil;
    [self setNeedsLayout];
}
// round (a pill when the frame is not square); the badge sits on the ring, up and to the right
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    _radius = fmin(s.width, s.height) / 2;
    _badge.center = CGPointMake(s.width / 2 * (1 + M_SQRT1_2), s.height / 2 * (1 - M_SQRT1_2));
}
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e {
    return CGRectContainsPoint(CGRectInset(self.bounds, -_slop, -_slop), p);
}
- (void)press:(BOOL)down {
    if (g_overlay_editing) return;
    key(_scan, down);                                  // the brake only pauses auto-accelerate (update_joy)
    if (down && _haptic) [tap_haptic() impactOccurred];
    CGFloat s = down ? _scale * 0.92 : _scale;
    [UIView animateWithDuration:down ? 0.06 : 0.15 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                         self.transform = CGAffineTransformMakeScale(s, s);
                         self.glow.alpha = down ? 0.28 : 0;
                     } completion:nil];
}
// a thumb can land as two touches: the button lets go only when the last of them lifts
- (BOOL)stillTouched:(UIEvent *)e {
    for (UITouch *t in [e touchesForView:self])
        if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) return YES;
    return NO;
}
- (void)touchesBegan:(NSSet *)t withEvent:(UIEvent *)e { [self press:YES]; }
- (void)touchesEnded:(NSSet *)t withEvent:(UIEvent *)e { if (![self stillTouched:e]) [self press:NO]; }
- (void)touchesCancelled:(NSSet *)t withEvent:(UIEvent *)e { if (![self stillTouched:e]) [self press:NO]; }
@end

// auto-accelerate: a tap turns it on or off; while on it lights up and holds the throttle
@interface CruiseButton : KeyButton
@end
static __weak CruiseButton *g_cruise_button;

static void set_cruise(BOOL on) {
    if (g_cruise == on) return;
    g_cruise = on;
    update_joy();
    cruise_glow();
}

// green while on, dimmer while the brake pauses it
static void cruise_glow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_cruise_button.glow.alpha = !g_cruise ? 0 : g_cruise_paused ? 0.18 : 0.45;
        g_cruise_button.glow.backgroundColor = [UIColor colorWithRed:0.3 green:0.85 blue:0.45 alpha:1];
    });
}

@implementation CruiseButton
- (void)press:(BOOL)down {
    if (g_overlay_editing || !down) return;
    set_cruise(!g_cruise);
    if (self.haptic) [tap_haptic() impactOccurred];
}
@end

// Steering for the left thumb, as in the RVGL port: a ringed capsule with ◀ ▶ at its ends; under the
// finger a ringed knob, and a bar from the centre to it.
@interface SteerPad : UIView <OverlayItem>
@property(nonatomic) UIView *face, *leftHalf, *rightHalf, *knob, *fill, *tick;
@property(nonatomic) UITouch *active;
@property(nonatomic) BOOL atLimit;
@property(nonatomic) float value;
@property(nonatomic) CGFloat knobX;
@end
@implementation SteerPad
@synthesize scale = _scale, haptic = _haptic, radius = _radius;
- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    _scale = 1;
    _haptic = YES;
    self.multipleTouchEnabled = YES;
    _face = face_in(self);
    _face.layer.shadowOpacity = 0;
    _face.clipsToBounds = YES;
    NSString *names[2] = { @"chevron.left", @"chevron.right" };
    for (int i = 0; i < 2; i++) {
        UIView *h = [UIView new];
        h.userInteractionEnabled = NO;
        [_face addSubview:h];
        icon_in(h, symbol(names[i], nil, 26), nil);
        if (i) _rightHalf = h; else _leftHalf = h;
    }
    _tick = [UIView new];
    _tick.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
    _fill = [UIView new];
    _fill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
    _fill.layer.cornerRadius = 3;
    _knob = [UIView new];
    _knob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    _knob.layer.cornerRadius = 26;
    _knob.layer.borderWidth = 2;
    _knob.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
    for (UIView *v in @[ _tick, _fill, _knob ]) { v.userInteractionEnabled = NO; [self addSubview:v]; }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    _radius = fmin(w, h) / 2;
    _leftHalf.frame = CGRectMake(0, 0, w / 2, h);
    _rightHalf.frame = CGRectMake(w / 2, 0, w / 2, h);
    _tick.frame = CGRectMake(w / 2 - 0.75, h * 0.3, 1.5, h * 0.4);
    [self show];
}
// knob, bar and the side's highlight for the current value
- (void)show {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, mid = w / 2;
    _knob.hidden = _fill.hidden = !_active;
    _knob.frame = CGRectMake(_knobX - 26, h / 2 - 26, 52, 52);
    _fill.frame = CGRectMake(fmin(mid, _knobX), h / 2 - 3, fabs(_knobX - mid), 6);
    _leftHalf.backgroundColor = [UIColor colorWithWhite:1 alpha:_value < 0 ? -_value * 0.25 : 0];
    _rightHalf.backgroundColor = [UIColor colorWithWhite:1 alpha:_value > 0 ? _value * 0.25 : 0];
}
// a touch just outside the capsule still steers
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e {
    return CGRectContainsPoint(CGRectInset(self.bounds, -24, -24), p);
}

// Pressing and sliding both steer: the finger's place relative to the pad's centre sets the
// steering, so a press on ◀ or ▶ (a quarter of the width out) is full lock like a button, a press
// nearer the middle steers less, and sliding changes it continuously. The curve is gentle near
// the centre for small corrections. The value goes to the joystick X axis (update_joy).
- (void)steer:(UIEvent *)e {
    if (g_overlay_editing) e = nil;
    NSSet<UITouch *> *touches = [e touchesForView:self];
    if (_active && (![touches containsObject:_active] || _active.phase == UITouchPhaseEnded || _active.phase == UITouchPhaseCancelled))
        _active = nil;
    if (!_active)
        for (UITouch *t in touches)
            if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) {
                _active = t;
                if (_haptic) [tap_haptic() impactOccurred];
                break;
            }
    CGFloat w = self.bounds.size.width, full = w * 0.25, v = 0;
    if (_active) {
        CGFloat dx = [_active locationInView:self].x - w / 2;
        CGFloat d = fmax(-1, fmin(1, dx / full)), a = fabs(d);
        v = a < 0.06 ? 0 : copysign(pow((a - 0.06) / 0.94, 1.4), d);
        _knobX = w / 2 + d * full;
    }
    BOOL limit = fabs(v) > 0.999;
    if (limit && !_atLimit && _haptic) [tap_haptic() impactOccurred];
    _atLimit = limit;
    g_touch_steer = (float)v;
    update_joy();
    _value = (float)v;
    [self show];
}
- (void)touchesBegan:(NSSet *)t withEvent:(UIEvent *)e { [self steer:e]; }
- (void)touchesMoved:(NSSet *)t withEvent:(UIEvent *)e { [self steer:e]; }
- (void)touchesEnded:(NSSet *)t withEvent:(UIEvent *)e { [self steer:e]; }
- (void)touchesCancelled:(NSSet *)t withEvent:(UIEvent *)e { [self steer:e]; }
- (void)releaseAll { [self steer:nil]; }
@end

// container for the buttons that lets touches on empty space fall through to the game view
@interface PassthroughView : UIView
@end
@implementation PassthroughView
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    return v == self ? nil : v;
}
@end

// NFS4 default key table verified at guest VA 0x005BCA14 in nfs4.exe: arrows, Space handbrake,
// A/Z gear up/down, C camera, B look behind, H horn (cop: siren), L lights, R reset, S spike strip
// (cop), plus the fixed keys Esc pause, Tab map and Enter.
enum {
    K_LEFT = 0xCB, K_RIGHT = 0xCD, K_GAS = 0xC8, K_BRAKE = 0xD0, K_HAND = 0x39, K_UP = 0x1E, K_DOWN = 0x2C,
    K_CAM = 0x2E, K_BACK = 0x30, K_HORN = 0x23, K_LIGHTS = 0x26, K_RESET = 0x13, K_SPIKE = 0x1F,
    K_ESC = 0x01, K_MAP = 0x0F, K_ENTER = 0x1C,
};

static NSString *const kImportAddress = @"wifiImportAddress";   // last PC address for "PC에서 받기"
// Per-control overrides from the overlay editor: id -> {x, y: centre as a fraction of the screen,
// s: scale, h: haptics}. Controls without an entry sit at their default place.
static NSString *const kOverlayLayout = @"overlay3";   // "overlay": places for the earlier glass layout
static NSString *const kOverlayAlpha = @"overlayAlpha";
static NSString *const kImportMarker = @".pcimport-incomplete";  // in <data root>/game while a transfer is unfinished

// a "PC에서 받기" transfer that has not finished: its marker, or a leftover *.part file
static BOOL import_incomplete(void) {
    NSString *game = [port_data_root() stringByAppendingPathComponent:@"game"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:[game stringByAppendingPathComponent:kImportMarker]]) return YES;
    // Every transfer since the marker exists keeps it until it finishes, so a leftover *.part without it can only
    // come from an older build: the game folder is walked once, not on every launch (README section 9).
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d boolForKey:@"partScanDone"]) return NO;
    for (NSString *rel in [fm enumeratorAtPath:game])
        if ([rel.pathExtension isEqualToString:@"part"]) return YES;
    [d setBool:YES forKey:@"partScanDone"];
    return NO;
}

// "건너뛰고 게임 시작" after a stopped update: the marker and the unfinished pieces go, the game files already
// replaced are whole (each is moved into place only once it is complete)
static void drop_unfinished_import(void) {
    NSString *game = [port_data_root() stringByAppendingPathComponent:@"game"];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:[game stringByAppendingPathComponent:kImportMarker] error:nil];
    for (NSString *rel in [fm enumeratorAtPath:game])
        if ([rel.pathExtension isEqualToString:@"part"]) [fm removeItemAtPath:[game stringByAppendingPathComponent:rel] error:nil];
}

// ---- save sharing between devices (README section 4, port_save_sync.m)
// Everything the game writes lands in <data root>/save, laid out like the game folder (the save overlay, hle.c),
// so the server keeps them as saves\NFS4\save\<path in the game folder>. The host's logs and debug notes stay here.
static void configure_save_sync(void) {
    port_sync_configure(@"NFS4", port_data_root(), @[ @"save" ], @[ @"log", @"txt", @"part" ]);
}
static NSString *sync_state_text(void) {
    NSString *folder = port_sync_folder_name();
    BOOL pc = port_sync_pc();
    if (folder && pc) return [folder stringByAppendingString:@" + PC"];
    if (folder) return folder;
    return pc ? @"PC" : @"꺼짐";
}

// ---- the PC: the address the game was received from, then the known ones (README section 9)
static BOOL probe_address(NSURLSession *s, NSString *address, NSString *app);
static NSData *fetch_data(NSURLSession *s, NSURL *url, NSInteger *status, NSError **err);
static NSURL *address_url(NSString *address);
static NSArray<NSString *> *known_pc_hosts(void) {
    NSMutableArray<NSString *> *hosts = [NSMutableArray array];
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kImportAddress] ?: @"";
    for (NSString *a in @[ saved, @"192.168.0.2:8765", @"100.99.113.123:8765" ]) {
        NSString *h = [a stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([h hasPrefix:@"http://"]) h = [h substringFromIndex:7];
        while ([h hasSuffix:@"/"]) h = [h substringToIndex:h.length - 1];
        if (h.length && ![h containsString:@":"]) h = [h stringByAppendingString:@":8765"];
        if (h.length && ![hosts containsObject:h]) [hosts addObject:h];
    }
    return hosts;
}

// ---- diagnostics (README section 10): the host logs and the last crash, as one text
static NSString *const kCrashLog = @"nfs4crash-last.log";   // in save: the log of a run that crashed, until sent
static NSString *const kDiagPending = @"diagPending";       // a crash not yet sent to the PC

static NSString *diag_text(void) {
    NSString *save = [port_data_root() stringByAppendingPathComponent:@"save"];
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSMutableString *out = [NSMutableString stringWithFormat:@"NFS4 v%@ (b%@)  %@ iOS %@  %@\n", info[@"CFBundleShortVersionString"] ?: @"?",
                            info[@"CFBundleVersion"] ?: @"?", UIDevice.currentDevice.model, UIDevice.currentDevice.systemVersion, [NSDate date]];
    [out appendFormat:@"thermal %ld, low power %d, save sharing %@\n", (long)NSProcessInfo.processInfo.thermalState,
                      NSProcessInfo.processInfo.lowPowerModeEnabled, sync_state_text()];
    const NSUInteger tail = 400000;                       // characters kept from the end of each log
    BOOL any = NO;
    for (NSString *name in @[ kCrashLog, @"nfs4host.log", @"nfs4host.prev.log", @"nfs4host.segment.log", @"missing_seeds.txt" ]) {
        NSData *d = [NSData dataWithContentsOfFile:[save stringByAppendingPathComponent:name]];
        if (!d) continue;
        NSString *t = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
                      ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding] ?: @"";
        if (t.length > tail) t = [@"…\n" stringByAppendingString:[t substringFromIndex:t.length - tail]];
        [out appendFormat:@"\n===== %@ (%lu bytes) =====\n%@\n", name, (unsigned long)d.length, t];
        any = YES;
    }
    if (!any) [out appendString:@"\n(기록이 아직 없습니다.)\n"];
    return out;
}

// POST /api/diag/NFS4/<name> to the first host that takes it (blocking, off the main thread); the host or nil
static NSString *post_diag(NSData *body, NSString *name, NSTimeInterval timeout) {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = timeout;
    config.connectionProxyDictionary = @{};   // straight to the PC, past any VPN/proxy app
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSString *sent = nil;
    for (NSString *host in known_pc_hosts()) {
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/api/diag/NFS4/%@", host, name]];
        if (!url) continue;
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        [req setValue:@"text/plain; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
        __block NSInteger code = 0;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [[session uploadTaskWithRequest:req fromData:body completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            if (!e && [r isKindOfClass:NSHTTPURLResponse.class]) code = ((NSHTTPURLResponse *)r).statusCode;
            dispatch_semaphore_signal(done);
        }] resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (code == 200) { sent = host; break; }
    }
    [session finishTasksAndInvalidate];
    return sent;
}

// the Files app's name for this device's own folder ("나의 iPad" on an iPad)
static NSString *files_device_name(void) {
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? @"나의 iPad" : @"나의 iPhone";
}

static NSString *diag_name(NSString *kind) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    return [NSString stringWithFormat:@"%@-%@.txt", kind, [f stringFromDate:[NSDate date]]];
}

// The previous run's log (just renamed to nfs4host.prev.log) ended in a crash: keep it apart, so a later
// launch still has it, and send it to the PC when one answers (quietly, short waits).
static void handle_last_crash(void) {
    NSString *save = [port_data_root() stringByAppendingPathComponent:@"save"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *prev = [save stringByAppendingPathComponent:@"nfs4host.prev.log"];
    NSData *data = [NSData dataWithContentsOfFile:prev];
    const char *crash = "\nCRASH:", *fatal = "\nFATAL:";
    if (data && ([data rangeOfData:[NSData dataWithBytes:crash length:strlen(crash)] options:0 range:NSMakeRange(0, data.length)].length ||
                 [data rangeOfData:[NSData dataWithBytes:fatal length:strlen(fatal)] options:0 range:NSMakeRange(0, data.length)].length)) {
        NSString *keep = [save stringByAppendingPathComponent:kCrashLog];
        [fm removeItemAtPath:keep error:nil];
        [fm copyItemAtPath:prev toPath:keep error:nil];
        [d setBool:YES forKey:kDiagPending];
        plat_log("diag: the last run crashed; its log is kept as %s", kCrashLog.UTF8String);
    }
    if (![d boolForKey:kDiagPending]) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *host = post_diag([diag_text() dataUsingEncoding:NSUTF8StringEncoding], diag_name(@"crash"), 2);
        if (!host) { plat_log("diag: crash record not sent (no PC)"); return; }
        [d setBool:NO forKey:kDiagPending];
        plat_log("diag: crash record sent to %s", host.UTF8String);
    });
}

// ---- update check before the game starts (README section 9, as renpy-ios-player offerUpdate): only the last
// PC and the known addresses, about 1.5 s at most when no PC is there. How many files the PC has that are missing
// here or differ in size (bytes: their total); 0 when none or no PC.
static NSUInteger pending_update_files(long long *bytes) {
    *bytes = 0;
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 1.2;
    config.connectionProxyDictionary = @{};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSString *app = NSBundle.mainBundle.infoDictionary[@"PortDataFolder"] ?: @"NFS4";
    __block NSString *found = nil;
    NSObject *lock = [NSObject new];
    dispatch_group_t group = dispatch_group_create();
    for (NSString *a in known_pc_hosts())
        dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (probe_address(session, a, app))
                @synchronized (lock) { if (!found) found = a; }
        });
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)));
    NSString *address;
    @synchronized (lock) { address = found; }
    NSUInteger count = 0;
    if (address) {
        NSInteger code = 0;
        NSData *data = fetch_data(session, [[address_url(address) URLByAppendingPathComponent:@"api/manifest"] URLByAppendingPathComponent:app], &code, NULL);
        NSDictionary *manifest = code == 200 && data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *dest = [port_data_root() stringByAppendingPathComponent:@"game"];
        NSFileManager *fm = NSFileManager.defaultManager;
        if ([manifest isKindOfClass:NSDictionary.class])
            for (NSDictionary *f in manifest[@"files"]) {
                long long want = [f[@"s"] longLongValue];
                NSNumber *size = [fm attributesOfItemAtPath:[dest stringByAppendingPathComponent:f[@"p"]] error:nil][NSFileSize];
                if (!size || size.longLongValue != want) { count++; *bytes += want; }
            }
        plat_log("update check: %s has %lu new/changed files (%lld bytes)", address.UTF8String, (unsigned long)count, *bytes);
    }
    [session finishTasksAndInvalidate];
    return count;
}

@interface GameViewController : UIViewController <UIDocumentPickerDelegate, UIGestureRecognizerDelegate, UITextFieldDelegate>
@property(nonatomic) GameView *gameView;
@property(nonatomic) UIView *controls;
@property(nonatomic) NSMutableDictionary<NSString *, UIView<OverlayItem> *> *items;
@property(nonatomic) NSMutableDictionary *layout;
@property(nonatomic) NSMutableArray<UIGestureRecognizer *> *editGestures;
@property(nonatomic) SteerPad *steerPad;
@property(nonatomic) NSMutableArray<KeyButton *> *menuButtons;
@property(nonatomic) BOOL menuMode, padConnected;
@property(nonatomic) UIButton *gear, *kbd;
@property(nonatomic) UIView *editPanel;
@property(nonatomic) UILabel *editTitle;
@property(nonatomic) UISlider *sizeSlider, *alphaSlider;
@property(nonatomic) UISwitch *hapticSwitch;
@property(nonatomic) NSString *selected;
@property(nonatomic) UIStackView *setup;
@property(nonatomic) UILabel *info, *pcStatus;
@property(nonatomic) UIButton *importButton, *pcButton, *closeButton, *skipButton;
@property(nonatomic) UITextField *pcField;
@property(nonatomic) UIProgressView *pcBar;
@property(nonatomic) BOOL syncing;       // a save sync from 설정 is running: the game stays paused
@property(nonatomic) BOOL pickingSync;   // the folder picker is for the save sharing folder
@property(nonatomic) BOOL gameFound;     // nfs4.exe is here (a stopped update can be skipped)
@end

@implementation GameViewController

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
// The pedals sit at the screen's edges: without this, a thumb that moves a little near the bottom
// starts iOS's home gesture, which cancels the touch and lets go of the throttle mid-race.
// Deferred, the first swipe only shows the home indicator and a second one leaves the game.
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    CGSize nb = UIScreen.mainScreen.nativeBounds.size;
    g_screen_height_px = (int)MIN(nb.width, nb.height);
    [[NSNotificationCenter defaultCenter] addObserverForName:@"NFS4Fatal" object:nil queue:nil
                                                  usingBlock:^(NSNotification *n) { [self showMessage:n.object import:NO]; }];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{ @"wide" : @YES, @"msaa" : @YES }];
    configure_save_sync();
}

// started here rather than in viewDidLoad: the safe area (Dynamic Island) is known by now
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL started;
    if (!started) { started = YES; [self startOrAsk]; }
}

- (void)applySettings {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    CGSize s = self.view.bounds.size;
    UIEdgeInsets in = self.view.safeAreaInsets;
    CGFloat w = MAX(s.width, s.height) - in.left - in.right, h = MIN(s.width, s.height);
    g_wide_aspect = [d boolForKey:@"wide"] && h > 0 ? (float)(w / h) : 0;
    g_screen_width_px = (int)(w * UIScreen.mainScreen.nativeScale);
    g_msaa_samples = [d boolForKey:@"msaa"] ? 4 : 1;
    g_fps_setting = [d boolForKey:@"fps30"] ? 30 : 60;
    update_power_cap();
    plat_log("display: %.0fx%.0f pt, usable aspect %.3f, wide %s, MSAA %dx, %d fps", s.width, s.height, w / h,
             g_wide_aspect > 0 ? "on" : "off", g_msaa_samples, g_fps_setting);
}

- (void)showSettings {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    // order as in README section 10: title, save sharing, other apps' sound, screen, pad, diagnostics, help, close
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"NFS4 v%@", app_version()]
        message:@"설정 창이 열려 있는 동안 게임은 멈춥니다." preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:[@"세이브 공유 · " stringByAppendingString:sync_state_text()]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self showSaveSharing]; }]];
    BOOL mix = mix_audio_on();
    [a addAction:[UIAlertAction actionWithTitle:mix ? @"다른 앱 소리와 함께 · 켬" : @"다른 앱 소리와 함께 · 끔"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [d setBool:!mix forKey:kMixAudio];
            apply_audio_mix();                 // at once
        }]];
    BOOL wide = [d boolForKey:@"wide"], msaa = [d boolForKey:@"msaa"];
    [a addAction:[UIAlertAction actionWithTitle:wide ? @"화면비 · 와이드 (다음 실행부터)" : @"화면비 · 원본 4:3 (다음 실행부터)"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [d setBool:!wide forKey:@"wide"]; }]];
    [a addAction:[UIAlertAction actionWithTitle:msaa ? @"안티에일리어싱 · 4x (다음 실행부터)" : @"안티에일리어싱 · 끔 (다음 실행부터)"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [d setBool:!msaa forKey:@"msaa"]; }]];
    BOOL fps30 = [d boolForKey:@"fps30"];
    [a addAction:[UIAlertAction actionWithTitle:fps30 ? @"프레임 · 절전 30fps" : @"프레임 · 60fps"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [d setBool:!fps30 forKey:@"fps30"];
            g_fps_setting = fps30 ? 60 : 30;
            update_power_cap();
        }]];
    [a addAction:[UIAlertAction actionWithTitle:@"패드 배치 · 위치·크기·진동" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *x) { [self startEditing]; }]];
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"패드 투명도 · %.0f%%", [self overlayAlpha] * 100]
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self askOverlayAlpha]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"키보드 입력 · 이름·코드" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *x) { [self askText]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"PC에서 받기 · 게임 파일 업데이트" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *x) { [self showPCUpdate]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"PC로 진단 보내기" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *x) { [self sendDiagnostics:NO]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"도움말" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *x) { [self showHelp]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"닫기" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 40, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

// "1.0.0 (빌드 31)" from Info.plist, which CI fills from APP_VERSION and the run number
static NSString *app_version(void) {
    NSDictionary *i = NSBundle.mainBundle.infoDictionary;
    return [NSString stringWithFormat:@"%@ (빌드 %@)", i[@"CFBundleShortVersionString"] ?: @"?", i[@"CFBundleVersion"] ?: @"?"];
}

// quick opacity presets for the touch buttons (the editor has a slider for finer steps)
- (void)askOverlayAlpha {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"버튼 투명도"
        message:@"낮을수록 화면이 잘 보입니다. 세밀한 조절은 '터치 버튼 편집'의 투명도 슬라이더로." preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *v in @[ @1.0, @0.75, @0.6, @0.45, @0.3, @0.15 ]) {
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%.0f%%", v.doubleValue * 100]
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                [[NSUserDefaults standardUserDefaults] setDouble:v.doubleValue forKey:kOverlayAlpha];
                self.controls.alpha = v.doubleValue;
            }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"닫기" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 40, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

// ---- game pause (README section 10): any window over the game pauses it at once; the 0.25 s timer in
// buildControls lets it go once nothing is over it any more (an alert has no "did close" of its own)
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    if (g_game_running) set_ui_pause(1);
    [super presentViewController:vc animated:animated completion:completion];
}

- (BOOL)wantsPause {
    return self.presentedViewController || g_overlay_editing || _syncing || (_setup && !_setup.hidden);
}

- (void)updatePause {
    if (g_game_running) set_ui_pause([self wantsPause]);
}

// ---- hardware keyboard (README section 10): the keys go to the game as they are, by their place on the
// keyboard (HID usage -> DirectInput scan code), so the game's own key table applies: arrows steer and
// accelerate/brake, Space handbrake, A/Z gears, C camera, B look behind, H horn, R reset, Esc, Tab, Enter.
static uint8_t hid_scan(long usage) {
    static const uint8_t letters[26] = { 0x1E, 0x30, 0x2E, 0x20, 0x12, 0x21, 0x22, 0x23, 0x17, 0x24, 0x25, 0x26, 0x32,
                                         0x31, 0x18, 0x19, 0x10, 0x13, 0x1F, 0x14, 0x16, 0x2F, 0x11, 0x2D, 0x15, 0x2C };   // A..Z
    if (usage >= 0x04 && usage <= 0x1D) return letters[usage - 0x04];
    if (usage >= 0x1E && usage <= 0x27) return (uint8_t)(0x02 + (usage - 0x1E));   // 1..9, 0
    if (usage >= 0x3A && usage <= 0x43) return (uint8_t)(0x3B + (usage - 0x3A));   // F1..F10
    switch (usage) {
        case 0x28: return 0x1C;   // Enter
        case 0x29: return 0x01;   // Esc
        case 0x2A: return 0x0E;   // Backspace
        case 0x2B: return 0x0F;   // Tab
        case 0x2C: return 0x39;   // Space
        case 0x2D: return 0x0C;   // -
        case 0x36: return 0x33;   // ,
        case 0x37: return 0x34;   // .
        case 0x4F: return 0xCD;   // right
        case 0x50: return 0xCB;   // left
        case 0x51: return 0xD0;   // down
        case 0x52: return 0xC8;   // up
        case 0xE0: return 0x1D;   // left Ctrl
        case 0xE1: return 0x2A;   // left Shift
        case 0xE2: return 0x38;   // left Alt
        case 0xE5: return 0x36;   // right Shift
        default: return 0;
    }
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)keyPresses:(NSSet<UIPress *> *)presses down:(BOOL)down {
    BOOL used = NO;
    for (UIPress *p in presses) {
        uint8_t sc = p.key ? hid_scan((long)p.key.keyCode) : 0;
        if (!sc || !g_game_running) continue;
        // a window is open: it has the keyboard; a key already held is still let go
        if (down && [self wantsPause]) continue;
        key(sc, down);
        used = YES;
    }
    return used;
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (![self keyPresses:presses down:YES]) [super pressesBegan:presses withEvent:event];
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (![self keyPresses:presses down:NO]) [super pressesEnded:presses withEvent:event];
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (![self keyPresses:presses down:NO]) [super pressesCancelled:presses withEvent:event];
}

- (void)showHelp {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"도움말"
        message:@"• 화면비 와이드: 레이스 최대 16:9, 메뉴는 4:3. 화면비·안티에일리어싱은 다음 실행부터 적용됩니다.\n"
                "• 발열·저전력 모드에서는 프레임을 자동으로 낮추고, 식은 뒤 고른 설정으로 돌아갑니다.\n"
                "• 설정·창·버튼 편집이 열려 있거나 앱을 벗어나 있는 동안 게임은 멈춥니다.\n"
                "• 세이브 공유: 파일 앱 폴더(iCloud Drive 등)나 PC로 다른 기기와 세이브를 맞춥니다. 게임 시작 전과 앱을 벗어날 때 맞춥니다.\n"
                "• 키보드(아이패드): 방향키 조향·가속·브레이크, Space 핸드브레이크, A/Z 기어, C 시점, B 후방, H 경적, R 리셋, Esc, Tab 지도, Enter.\n"
                "• 문제가 생기면 'PC로 진단 보내기'를 누르세요. 튕긴 다음 실행에서 PC가 보이면 기록을 자동으로 보냅니다.\n"
                "• 기록 위치: 파일 앱 › LiveContainer › Games › NFS4 › save 의 nfs4host.log"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"닫기" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// a short note at the bottom of the screen that fades by itself
- (void)showToast:(NSString *)text {
    UILabel *l = [UILabel new];
    l.text = [NSString stringWithFormat:@"  %@  ", text];
    l.font = [UIFont boldSystemFontOfSize:14];
    l.textColor = UIColor.whiteColor;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
    l.layer.cornerRadius = 8;
    l.clipsToBounds = YES;
    [l sizeToFit];
    l.bounds = CGRectMake(0, 0, l.bounds.size.width, l.bounds.size.height + 12);
    l.center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height - 40);
    l.userInteractionEnabled = NO;
    [self.view addSubview:l];
    [UIView animateWithDuration:0.4 delay:2.5 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL f) { [l removeFromSuperview]; }];
}

- (void)showNote:(NSString *)title text:(NSString *)text {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"확인" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// ---- save sharing (README section 4)

- (void)showSaveSharing {
    NSString *folder = port_sync_folder_name();
    BOOL pc = port_sync_pc();
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[@"세이브 공유 · " stringByAppendingString:sync_state_text()]
        message:@"파일 앱 폴더(iCloud Drive 등)나 PC(PC에서-받기-서버)로 다른 기기와 세이브를 맞춥니다. 게임 시작 전에 맞추고, 앱을 벗어날 때는 올리기만 합니다."
        preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"지금 맞추기" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self syncNow:0]; }]];
    [a addAction:[UIAlertAction actionWithTitle:folder ? [@"공유 폴더 · " stringByAppendingString:folder] : @"공유 폴더 · 고르기"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            self.pickingSync = YES;
            [self pickFolder];
        }]];
    if (folder)
        [a addAction:[UIAlertAction actionWithTitle:@"공유 폴더 끄기" style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *x) { port_sync_set_folder(nil); }]];
    [a addAction:[UIAlertAction actionWithTitle:pc ? @"PC와 공유 · 켬" : @"PC와 공유 · 끔" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *x) {
            port_sync_set_pc(!pc);
            if (!pc) [self syncNow:0];
        }]];
    [a addAction:[UIAlertAction actionWithTitle:@"닫기" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    a.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 40, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}

// Where a save changed on both sides the player says which is kept (the other is not lost: the PC keeps what it
// replaces under saves\NFS4\.history, this device under save-backup).
- (void)askSyncConflict:(void (^)(int resolve))answer {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"세이브가 양쪽에서 바뀌었습니다"
        message:@"이 기기와 다른 기기(공유 폴더·PC)에서 같은 세이브가 각각 바뀌었습니다. 어느 쪽을 쓸까요?"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"이 기기 세이브" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { answer(1); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"다른 기기 세이브" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { answer(-1); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"나중에" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { answer(0); }]];
    [self presentViewController:a animated:YES completion:nil];
}

// before the game reads its saves; then on to the game
- (void)syncAtStart:(int)resolve then:(void (^)(void))next {
    port_sync_run_start(resolve, ^(NSString *summary, BOOL conflict, BOOL changed) {
        plat_log("save sync (start): %s", summary.UTF8String);
        if ([summary containsString:@"PC 세이브는 확인 못 함"]) [self showToast:@"PC 세이브는 확인 못 함"];
        if (!conflict) { next(); return; }
        [self askSyncConflict:^(int r) {
            if (r) [self syncAtStart:r then:next];
            else next();
        }];
    });
}

// from 설정: the game stays paused while it runs. A save that came down is read by the game the next time it
// loads it; reopening the app is the sure way.
- (void)syncNow:(int)resolve {
    if (!port_sync_configured()) { [self showNote:@"세이브 공유" text:@"공유 폴더를 고르거나 'PC와 공유'를 켜세요."]; return; }
    _syncing = YES;
    [self updatePause];
    [self showToast:@"세이브 맞추는 중…"];
    port_sync_run(resolve, NO, ^(NSString *summary, BOOL conflict, BOOL changed) {
        plat_log("save sync: %s", summary.UTF8String);
        if (conflict) {
            [self askSyncConflict:^(int r) {
                if (r) [self syncNow:r];
                else { self.syncing = NO; [self updatePause]; }
            }];
            return;
        }
        self.syncing = NO;
        NSString *text = changed && g_game_running ? [summary stringByAppendingString:@"\n받은 세이브는 앱을 완전히 종료했다가 다시 열면 확실히 반영됩니다."] : summary;
        [self showNote:@"세이브 공유" text:text];
    });
}

// ---- diagnostics to the PC (README section 10)
- (void)sendDiagnostics:(BOOL)quiet {
    if (!quiet) [self showToast:@"PC로 보내는 중…"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *body = [diag_text() dataUsingEncoding:NSUTF8StringEncoding];
        NSString *host = post_diag(body, diag_name(@"diag"), 6);
        if (host) [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kDiagPending];   // the crash went with it
        plat_log("diag: %s", host ? [@"sent to " stringByAppendingString:host].UTF8String : "no PC answered");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (quiet) return;
            if (host) [self showNote:@"PC로 진단 보내기" text:[NSString stringWithFormat:@"%@(으)로 보냈습니다 (%lu KB).", host, (unsigned long)(body.length + 1023) / 1024]];
            else [self showNote:@"PC로 진단 보내기" text:@"PC를 찾지 못했습니다. PC에서 받기 서버가 켜져 있고 같은 와이파이인지 확인해 주세요."];
        });
    });
}

// ---- update check before the game starts: the PC has new or changed game files (e.g. a car pack added to its
// overlay folder) -> ask; "받기" fetches only those, "건너뛰고 게임 시작" goes on with the game as it is
- (void)offerUpdateThen:(void (^)(void))next {
    [self showMessage:@"PC에 업데이트가 있는지 확인하는 중…" import:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        long long bytes = 0;
        NSUInteger count = pending_update_files(&bytes);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!count) { next(); return; }
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"PC에 새 파일이 있습니다"
                message:[NSString stringWithFormat:@"새 파일·바뀐 파일 %lu개 (%.1f MB)를 받을까요?", (unsigned long)count, bytes / 1e6]
                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"건너뛰고 게임 시작" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { next(); }]];
            [a addAction:[UIAlertAction actionWithTitle:@"받기" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
                self.pcStatus.text = @"";
                [self showMessage:@"PC에서 받기\n\nPC와 다른 파일만 받습니다. 다 받으면 게임이 시작됩니다." import:YES];
                [self startPCImport];
            }]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

// DirectInput scan codes of the characters the game's text fields take
static uint8_t char_scan(unichar ch) {
    static const char *rows[] = { "1234567890-", "qwertyuiop", "asdfghjkl", "zxcvbnm" };
    static const uint8_t first[] = { 0x02, 0x10, 0x1E, 0x2C };
    ch = (unichar)tolower(ch);
    for (int r = 0; r < 4; r++) {
        const char *p = strchr(rows[r], ch);
        if (ch && p) return (uint8_t)(first[r] + (p - rows[r]));
    }
    if (ch == ' ') return 0x39;
    if (ch == '.') return 0x34;
    return 0;
}

// types text into the game as key presses (player names, codes typed in the menus)
- (void)askText {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"키보드 입력"
        message:@"입력한 글자를 게임에 키보드로 보냅니다.\n이름 바꾸기: 메인 메뉴의 'Player 1 Name'을 눌러 이름 창을 연 뒤 여기서 새 이름을 넣고 '지우고 보내고 Enter'를 누르세요."
                 preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.keyboardType = UIKeyboardTypeASCIICapable;
    }];
    __weak UIAlertController *weak = a;
    void (^send)(BOOL, BOOL) = ^(BOOL clear, BOOL enter) {
        NSString *text = weak.textFields.firstObject.text ?: @"";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            // the game is paused while this window closes: type only once it runs again, or presses go unseen
            for (int i = 0; i < 40 && !game_running_now(); i++) usleep(50000);
            usleep(100000);
            // a name box opens full with the old name (up to 10 letters): Backspace it away first
            if (clear) for (int i = 0; i < 16; i++) { key(0x0E, 1); usleep(30000); key(0x0E, 0); usleep(30000); }
            for (NSUInteger i = 0; i < text.length; i++) {
                unichar ch = [text characterAtIndex:i];
                uint8_t sc = char_scan(ch);
                if (!sc) continue;
                BOOL upper = ch >= 'A' && ch <= 'Z';
                if (upper) key(0x2A, 1);
                key(sc, 1); usleep(40000); key(sc, 0); usleep(40000);
                if (upper) key(0x2A, 0);
            }
            if (enter) { key(K_ENTER, 1); usleep(40000); key(K_ENTER, 0); }
        });
    };
    [a addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"지우고 보내고 Enter (이름 바꾸기)" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { send(YES, YES); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"보내기" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { send(NO, NO); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"보내고 Enter" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { send(NO, YES); }]];
    [self presentViewController:a animated:YES completion:nil];
}

// The setup screen: a message and, when the game is missing, the two ways to bring it in:
// "PC에서 받기" over Wi-Fi (E:\ios-ports\README.md section 9) or copying a folder from Files.
- (void)showMessage:(NSString *)text import:(BOOL)import {
    if (!_setup) {
        _info = [UILabel new];
        _info.numberOfLines = 0;
        _info.textColor = UIColor.whiteColor;
        _info.font = [UIFont systemFontOfSize:14];

        _pcField = [UITextField new];
        _pcField.placeholder = @"PC 주소 (비워 두면 자동으로 찾습니다)";
        _pcField.text = [[NSUserDefaults standardUserDefaults] stringForKey:kImportAddress];
        _pcField.borderStyle = UITextBorderStyleRoundedRect;
        _pcField.keyboardType = UIKeyboardTypeURL;
        _pcField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _pcField.autocorrectionType = UITextAutocorrectionTypeNo;
        _pcField.returnKeyType = UIReturnKeyGo;
        _pcField.delegate = self;
        [_pcField.widthAnchor constraintEqualToConstant:260].active = YES;
        _pcButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_pcButton setTitle:@"PC에서 받기" forState:UIControlStateNormal];
        _pcButton.titleLabel.font = [UIFont boldSystemFontOfSize:17];
        [_pcButton addTarget:self action:@selector(startPCImport) forControlEvents:UIControlEventTouchUpInside];
        UIStackView *pcRow = [[UIStackView alloc] initWithArrangedSubviews:@[ _pcField, _pcButton ]];
        pcRow.spacing = 12;
        pcRow.alignment = UIStackViewAlignmentCenter;

        _pcBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _pcBar.hidden = YES;
        [_pcBar.widthAnchor constraintEqualToConstant:380].active = YES;
        _pcStatus = [UILabel new];
        _pcStatus.numberOfLines = 0;
        _pcStatus.textAlignment = NSTextAlignmentCenter;
        _pcStatus.textColor = [UIColor colorWithWhite:1 alpha:0.7];
        _pcStatus.font = [UIFont systemFontOfSize:13];

        _importButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_importButton setTitle:@"파일 앱에서 게임 폴더 가져오기" forState:UIControlStateNormal];
        _importButton.titleLabel.font = [UIFont systemFontOfSize:15];
        [_importButton addTarget:self action:@selector(pickFolder) forControlEvents:UIControlEventTouchUpInside];

        _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];   // when opened from ⚙︎ during a game
        [_closeButton setTitle:@"닫기" forState:UIControlStateNormal];
        _closeButton.titleLabel.font = [UIFont systemFontOfSize:15];
        [_closeButton addTarget:self action:@selector(closeSetup) forControlEvents:UIControlEventTouchUpInside];

        _skipButton = [UIButton buttonWithType:UIButtonTypeSystem];   // a stopped update, the game itself is here
        [_skipButton setTitle:@"건너뛰고 게임 시작" forState:UIControlStateNormal];
        _skipButton.titleLabel.font = [UIFont systemFontOfSize:15];
        [_skipButton addTarget:self action:@selector(skipUpdate) forControlEvents:UIControlEventTouchUpInside];

        _setup = [[UIStackView alloc] initWithArrangedSubviews:@[ _info, pcRow, _pcBar, _pcStatus, _skipButton, _importButton, _closeButton ]];
        _setup.axis = UILayoutConstraintAxisVertical;
        _setup.alignment = UIStackViewAlignmentCenter;
        _setup.spacing = 12;
        [_setup setCustomSpacing:20 afterView:_info];
        _setup.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:_setup];
        [NSLayoutConstraint activateConstraints:@[
            [_setup.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [_setup.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
            [_setup.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor multiplier:0.85],
        ]];
    }
    [self.view bringSubviewToFront:_setup];
    _setup.hidden = NO;
    _info.text = text;
    for (UIView *v in _setup.arrangedSubviews)
        if (v != _info) v.hidden = !import;
    _pcBar.hidden = YES;
    _pcStatus.hidden = !import || !_pcStatus.text.length;
    _importButton.hidden = !import || g_game_running;     // a folder copy replaces the game; only before it runs
    _closeButton.hidden = !import || !g_game_running;
    _skipButton.hidden = !import || g_game_running || !_gameFound;
    _setup.backgroundColor = g_game_running ? [UIColor colorWithWhite:0 alpha:0.85] : UIColor.clearColor;
    [self updatePause];                        // the transfer screen over a running game pauses it
}

- (void)closeSetup {
    [_pcField resignFirstResponder];
    _setup.hidden = YES;
    [self updatePause];
}

// a stopped update: its marker and unfinished pieces go, then the game starts with the files it has
- (void)skipUpdate {
    _skipButton.enabled = _pcButton.enabled = NO;
    [self showMessage:@"게임을 시작하는 중…" import:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        drop_unfinished_import();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.skipButton.enabled = self.pcButton.enabled = YES;
            [self startOrAsk];
        });
    });
}

// ⚙︎ › PC에서 받기 while the game is installed: only files that differ from the PC's are fetched
// (e.g. the high-resolution cars the PC server adds from its overlay folder)
- (void)showPCUpdate {
    _pcStatus.text = @"";
    [self showMessage:@"PC에서 받기\n\nPC에서 'PC에서-받기-서버'를 켜고 버튼을 누르세요 (PC는 자동으로 찾습니다). PC와 다른 파일만 받습니다 "
                      "(고해상도 차량 등). 다 받은 뒤 앱을 완전히 종료했다가 다시 열면 적용됩니다."
               import:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [self startPCImport];
    return YES;
}

- (void)pcStatus:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.pcStatus.text = text;
        self.pcStatus.hidden = NO;
    });
}

// ---- finding the PC without an address (E:\ios-ports\README.md section 9)

static NSData *fetch_data(NSURLSession *s, NSURL *url, NSInteger *status, NSError **err);

static NSURL *address_url(NSString *address) {
    NSURL *url = [NSURL URLWithString:[address containsString:@"://"] ? address : [@"http://" stringByAppendingString:address]];
    return url.host ? url : nil;
}

// serve-games answers "/" with {"apps": [...]}: true if it offers this app
static BOOL probe_address(NSURLSession *s, NSString *address, NSString *app) {
    NSURL *url = address_url(address);
    if (!url) return NO;
    NSInteger code = 0;
    NSData *data = fetch_data(s, url, &code, NULL);
    if (code != 200 || !data) return NO;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:NSDictionary.class] && [json[@"apps"] isKindOfClass:NSArray.class] && [json[@"apps"] containsObject:app];
}

// "a.b.c.d:port" for every other host on the Wi-Fi (en*) IPv4 subnet; a subnet larger than /22
// is cut to the phone's /24
static NSArray<NSString *> *subnet_hosts(int port) {
    NSMutableArray *hosts = [NSMutableArray array];
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return hosts;
    for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || !ifa->ifa_netmask || ifa->ifa_addr->sa_family != AF_INET || strncmp(ifa->ifa_name, "en", 2) != 0)
            continue;
        uint32_t ip = ntohl(((struct sockaddr_in *)ifa->ifa_addr)->sin_addr.s_addr);
        uint32_t mask = ntohl(((struct sockaddr_in *)ifa->ifa_netmask)->sin_addr.s_addr);
        if (__builtin_popcount(mask) < 22) mask = 0xFFFFFF00;
        if (~mask < 2) continue;
        uint32_t net = ip & mask;
        for (uint32_t i = 1; i < ~mask; i++) {
            uint32_t h = net | i;
            if (h != ip) [hosts addObject:[NSString stringWithFormat:@"%u.%u.%u.%u:%d", h >> 24, (h >> 16) & 255, (h >> 8) & 255, h & 255, port]];
        }
    }
    freeifaddrs(list);
    return hosts;
}

// blocking: the given addresses, the PC this was set up with (LAN, Tailscale), then every host
// on the Wi-Fi subnet, 64 at a time; nil when no PC answers
static NSString *discover_pc(NSArray<NSString *> *preferred, NSString *app) {
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 1.5;
    config.connectionProxyDictionary = @{};   // the PC is on the LAN: never through a VPN/proxy app
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSMutableOrderedSet<NSString *> *first = [NSMutableOrderedSet orderedSet];
    for (NSString *a in [preferred arrayByAddingObjectsFromArray:@[ @"192.168.0.2:8765" ]])
        if (a.length) [first addObject:a];
    for (NSString *a in first)
        if (probe_address(session, a, app)) { [session finishTasksAndInvalidate]; return a; }
    NSArray<NSString *> *hosts = subnet_hosts(8765);
    __block NSString *found = nil;
    NSObject *lock = [NSObject new];
    for (NSUInteger start = 0; start < hosts.count && !found; start += 64) {
        dispatch_group_t group = dispatch_group_create();
        for (NSUInteger i = start; i < MIN(start + 64, hosts.count); i++) {
            NSString *host = hosts[i];
            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @synchronized (lock) { if (found) return; }
                if (probe_address(session, host, app))
                    @synchronized (lock) { if (!found) found = host; }
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    }
    [session finishTasksAndInvalidate];
    return found;
}

- (void)startPCImport {
    NSString *typed = [_pcField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kImportAddress] ?: @"";
    NSString *app = NSBundle.mainBundle.infoDictionary[@"PortDataFolder"] ?: @"NFS4";
    [_pcField resignFirstResponder];
    _pcButton.enabled = _importButton.enabled = _skipButton.enabled = NO;
    _pcBar.hidden = NO;
    _pcBar.progress = 0;
    [self pcStatus:@"같은 와이파이에서 PC를 찾는 중…"];
    UIApplication.sharedApplication.idleTimerDisabled = YES;       // no auto-lock mid-transfer (the app keeps it off)
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *address = discover_pc(@[ typed, saved ], app);
        NSString *error;
        if (!address) {
            error = @"PC를 찾지 못했습니다. '로컬 네트워크' 허용 창이 떴다면 허용한 뒤 다시 누르세요.\n"
                    "그래도 안 되면 확인해 주세요:\n"
                    "① PC에서 'PC에서-받기-서버.cmd'가 켜져 있나요?\n"
                    "② 휴대폰이 PC와 같은 와이파이에 있나요? (셀룰러·VPN 끄기)\n"
                    "③ 설정 › 개인정보 보호 및 보안 › 로컬 네트워크에서 LiveContainer(또는 NFS IV)가 켜져 있나요?";
        } else {
            [[NSUserDefaults standardUserDefaults] setObject:address forKey:kImportAddress];
            dispatch_async(dispatch_get_main_queue(), ^{ self.pcField.text = address; });
            [self pcStatus:[address stringByAppendingString:@"에 연결했습니다."]];
            error = [self runPCImportFrom:address_url(address)];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            // left off: the game that starts from here is often played on a gamepad, which does not keep the
            // screen awake, and the app turns auto-lock off for good at launch anyway (AppDelegate)
            self.pcButton.enabled = self.importButton.enabled = self.skipButton.enabled = YES;
            if (error) [self pcStatus:[error stringByAppendingString:@"\n다시 누르면 받은 데까지 건너뛰고 이어서 받습니다."]];
            else if (g_game_running) [self pcStatus:@"다 받았습니다. 앱을 완전히 종료했다가 다시 열면 적용됩니다."];
            else { [self pcStatus:@"다 받았습니다."]; [self startOrAsk]; }
        });
    });
}

// blocking request for the worker threads
static NSData *fetch_data(NSURLSession *s, NSURL *url, NSInteger *status, NSError **err) {
    __block NSData *out = nil;
    __block NSError *error = nil;
    __block NSInteger code = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[s dataTaskWithURL:url completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        out = d; code = [(NSHTTPURLResponse *)r statusCode]; error = e;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    *status = code;
    if (err) *err = error;
    return out;
}

// appends a downloaded piece to a .part file
static BOOL append_file(NSString *from, NSString *to) {
    NSFileHandle *in = [NSFileHandle fileHandleForReadingAtPath:from], *out = [NSFileHandle fileHandleForWritingAtPath:to];
    if (!in || !out) return NO;
    [out seekToEndOfFile];
    for (;;) {
        @autoreleasepool {
            NSData *d = [in readDataOfLength:1 << 20];
            if (!d.length) break;
            [out writeData:d];
        }
    }
    [in closeFile];
    [out closeFile];
    return YES;
}

// GET /api/manifest/NFS4, then every file not already here at its size, 4 at a time, into
// <data root>/game. Big files go through <name>.part and resume with Range. nil = success.
- (NSString *)runPCImportFrom:(NSURL *)base {
    NSString *app = NSBundle.mainBundle.infoDictionary[@"PortDataFolder"] ?: @"NFS4";
    NSString *dest = [port_data_root() stringByAppendingPathComponent:@"game"];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.defaultSessionConfiguration;
    config.timeoutIntervalForRequest = 30;
    config.HTTPMaximumConnectionsPerHost = 4;
    config.connectionProxyDictionary = @{};   // straight to the PC, past any VPN/proxy app
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSFileManager *fm = NSFileManager.defaultManager;

    NSInteger code = 0;
    NSError *err = nil;
    NSData *data = fetch_data(session, [[base URLByAppendingPathComponent:@"api/manifest"] URLByAppendingPathComponent:app], &code, &err);
    if (!data || code != 200)
        return err ? [NSString stringWithFormat:@"PC에 연결하지 못했습니다: %@", err.localizedDescription]
                   : [NSString stringWithFormat:@"PC가 %ld 오류를 보냈습니다. 서버의 games.json에 %@가 있는지 확인하세요.", (long)code, app];
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray<NSDictionary *> *files = manifest[@"files"];
    long long total = [manifest[@"total"] longLongValue];
    if (!files.count) return @"PC가 보낸 파일 목록이 비어 있습니다.";

    // until every file is here the game must not start on half-copied data (see import_incomplete)
    [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *marker = [dest stringByAppendingPathComponent:kImportMarker];
    [fm createFileAtPath:marker contents:[NSData data] attributes:nil];

    NSMutableArray<NSDictionary *> *todo = [NSMutableArray array];
    long long have = 0;
    for (NSDictionary *f in files) {
        NSNumber *size = [fm attributesOfItemAtPath:[dest stringByAppendingPathComponent:f[@"p"]] error:nil][NSFileSize];
        if (size && size.longLongValue == [f[@"s"] longLongValue]) have += size.longLongValue;
        else [todo addObject:f];
    }

    __block long long done = have;
    __block NSString *failure = nil;
    NSObject *lock = [NSObject new];
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 4;
    void (^report)(void) = ^{
        long long d;
        @synchronized (lock) { d = done; }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.pcBar.progress = total > 0 ? (float)((double)d / (double)total) : 0;
            self.pcStatus.text = [NSString stringWithFormat:@"받는 중 %.0f / %.0f MB", d / 1e6, total / 1e6];
            self.pcStatus.hidden = NO;
        });
    };
    report();

    for (NSDictionary *f in todo) {
        [queue addOperationWithBlock:^{
            @synchronized (lock) { if (failure) return; }
            NSString *rel = f[@"p"];
            long long want = [f[@"s"] longLongValue];
            NSURL *url = [[base URLByAppendingPathComponent:@"api/file"] URLByAppendingPathComponent:app];
            for (NSString *part in [rel componentsSeparatedByString:@"/"]) url = [url URLByAppendingPathComponent:part];
            NSString *target = [dest stringByAppendingPathComponent:rel], *part = [target stringByAppendingString:@".part"];
            [fm createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            long long partial = [[fm attributesOfItemAtPath:part error:nil][NSFileSize] longLongValue];
            if (partial >= want) { [fm removeItemAtPath:part error:nil]; partial = 0; }
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
            if (partial > 0) [req setValue:[NSString stringWithFormat:@"bytes=%lld-", partial] forHTTPHeaderField:@"Range"];

            __block NSString *problem = nil;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [[session downloadTaskWithRequest:req completionHandler:^(NSURL *tmp, NSURLResponse *r, NSError *e) {
                NSInteger status = [(NSHTTPURLResponse *)r statusCode];
                if (e || (status != 200 && status != 206)) {
                    problem = e ? e.localizedDescription : [NSString stringWithFormat:@"%ld 오류 (%@)", (long)status, rel];
                } else if (status == 206 && partial > 0) {          // the rest of a .part
                    if (!append_file(tmp.path, part)) problem = [NSString stringWithFormat:@"저장 실패 (%@)", rel];
                } else {                                            // the whole file: the temp file goes away after this
                    [fm removeItemAtPath:part error:nil];
                    NSError *moveErr = nil;
                    if (![fm moveItemAtURL:tmp toURL:[NSURL fileURLWithPath:part] error:&moveErr]) problem = moveErr.localizedDescription;
                }
                dispatch_semaphore_signal(sem);
            }] resume];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            if (!problem) {
                long long got = [[fm attributesOfItemAtPath:part error:nil][NSFileSize] longLongValue];
                if (got != want) problem = [NSString stringWithFormat:@"크기가 다릅니다 (%@)", rel];
                else {
                    [fm removeItemAtPath:target error:nil];
                    if (![fm moveItemAtPath:part toPath:target error:nil]) problem = [NSString stringWithFormat:@"저장 실패 (%@)", rel];
                }
            }
            @synchronized (lock) {
                if (problem) { if (!failure) failure = problem; return; }
                done += want;
            }
            report();
        }];
    }
    [queue waitUntilAllOperationsAreFinished];
    [session finishTasksAndInvalidate];
    if (!failure) [fm removeItemAtPath:marker error:nil];
    return failure;
}

// once per launch, before anything is logged: the save folder (moved from the old layout), the log (the last
// run's kept as nfs4host.prev.log) and, if that run crashed, its record for the PC
- (void)openSaveAndLog {
    static BOOL done;
    if (done) return;
    done = YES;
    NSString *root = port_data_root();
    NSString *save = [root stringByAppendingPathComponent:@"save"];
    NSString *oldSave = [root stringByAppendingPathComponent:@"NFS4-save"];   // builds before the shared layout
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:save] && [fm fileExistsAtPath:oldSave]) [fm moveItemAtPath:oldSave toPath:save error:nil];
    snprintf(g_save, sizeof g_save, "%s", save.fileSystemRepresentation);
    mkdir(g_save, 0755);
    char logp[1200], prevp[1200];
    snprintf(logp, sizeof logp, "%s/nfs4host.log", g_save);
    snprintf(prevp, sizeof prevp, "%s/nfs4host.prev.log", g_save);
    rename(logp, prevp);                       // keep the last session's log, e.g. after a crash
    snprintf(g_log.current,sizeof g_log.current,"%s",logp);
    snprintf(g_log.segment,sizeof g_log.segment,"%s/nfs4host.segment.log",g_save);
    g_log.file=fopen(logp,"w");g_log.bytes=0;
    g_console_logging=getenv("NFS4_CONSOLE_LOG")!=NULL;
#if DEBUG
    g_console_logging=1;
#endif
    install_crash_handlers();
    plat_log("NFS4 %s", app_version().UTF8String);
    handle_last_crash();
}

- (void)startOrAsk {
    if (!g_game_running && import_incomplete()) {
        // an interrupted "PC에서 받기": half-copied data would hang or crash the game
        _gameFound = locate_game_dir() != nil;   // a stopped update: "건너뛰고 게임 시작" is offered
        _pcStatus.text = @"";
        [self showMessage:[@"PC에서 받기가 끝나지 않았습니다.\n\nPC에서 'PC에서-받기-서버'를 켜고 아래 버튼을 누르면 "
                           "받은 파일은 건너뛰고 이어서 받습니다. 다 받으면 게임이 시작됩니다.\n\nNFS4 " stringByAppendingString:app_version()]
                   import:YES];
        return;
    }
    NSString *dir = locate_game_dir();
    if (!dir) {
        [self showMessage:[NSString stringWithFormat:@"NFS High Stakes PC판 게임 폴더(Modern Patch판 nfs4.exe)가 필요합니다.\n\n"
                           "• PC에서 받기: PC에서 'PC에서-받기-서버'를 켜고, 같은 와이파이에서 아래 버튼을 누르세요 (PC는 자동으로 찾습니다).\n"
                           "• 또는 nfs4.exe가 든 폴더 전체를 파일 앱의 game 폴더에 복사한 뒤 다시 실행하세요.\n"
                           "   단독 설치: %@ › NFS IV › game\n"
                           "   LiveContainer: LiveContainer › Games › NFS4 › game\n\nNFS4 %@", files_device_name(), app_version()]
                   import:YES];
        return;
    }
    _gameFound = YES;
    [self openSaveAndLog];
    if (g_game_running) { _setup.hidden = YES; [self updatePause]; return; }
    // the PC may have new game files (README section 9): a quick look before the game, once per launch
    static BOOL updateChecked;
    if (!updateChecked) {
        updateChecked = YES;
        [self offerUpdateThen:^{ [self startOrAsk]; }];
        return;
    }
    // saves shared with the player's other devices: brought in step before the game reads them (README section 4)
    static BOOL synced;
    if (!synced) {
        synced = YES;
        if (port_sync_configured()) {
            [self showMessage:@"세이브를 다른 기기와 맞추는 중…" import:NO];
            [self syncAtStart:0 then:^{ [self startOrAsk]; }];
            return;
        }
    }
    _setup.hidden = YES;
    NSString *root = port_data_root();
    snprintf(g_game, sizeof g_game, "%s", dir.fileSystemRepresentation);
    // replacement game files (high-resolution textures etc.), laid out like the game folder
    snprintf(g_mods, sizeof g_mods, "%s", [root stringByAppendingPathComponent:@"mods"].fileSystemRepresentation);
    mkdir(g_mods, 0755);
    plat_log("game folder: %s", g_game);
    [self applySettings];
    plat_log("power: initial %d fps, thermal %d, low power %d, active %d",plat_frame_cap(),g_thermal_state,g_low_power,g_app_active);

    _gameView = [[GameView alloc] initWithFrame:self.view.bounds];
    _gameView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view insertSubview:_gameView atIndex:0];
    [self buildControls];
    [self setupGamepads];
    start_audio();
    start_thermal_log();
    [self becomeFirstResponder];               // a hardware keyboard's keys come here (pressesBegan)
    if (!g_game_running) plat_thread_start(game_main, NULL);
    // leaving the app: new saves go up (nothing is written here while the game runs)
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
                                                       queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        if (!port_sync_configured()) return;
        UIApplication *app = UIApplication.sharedApplication;
        __block UIBackgroundTaskIdentifier task = [app beginBackgroundTaskWithExpirationHandler:^{
            [app endBackgroundTask:task];
            task = UIBackgroundTaskInvalid;
        }];
        port_sync_run(0, YES, ^(NSString *summary, BOOL conflict, BOOL changed) {
            plat_log("save sync (background): %s", summary.UTF8String);
            if (task != UIBackgroundTaskInvalid) { [app endBackgroundTask:task]; task = UIBackgroundTaskInvalid; }
        });
    }];
}

// ---------------------------------------------------------------- touch overlay


static NSString *item_name(NSString *ident) {
    NSDictionary *n = @{ @"steer" : @"조향", @"back" : @"후방", @"gas" : @"가속", @"brake" : @"브레이크",
                         @"spike" : @"스파이크", @"horn" : @"경적·사이렌", @"pause" : @"일시정지", @"map" : @"지도",
                         @"cam" : @"시점", @"enter" : @"확인", @"reset" : @"리셋", @"cruise" : @"오토 가속" };
    return n[ident] ?: ident;
}

- (void)addItem:(UIView<OverlayItem> *)v ident:(NSString *)ident {
    v.accessibilityIdentifier = ident;
    [_controls addSubview:v];
    _items[ident] = v;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(editPan:)];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(editPinch:)];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(editTap:)];
    for (UIGestureRecognizer *g in @[ pan, pinch, tap ]) {
        g.enabled = NO;                        // only while the editor is open
        g.delegate = self;
        [v addGestureRecognizer:g];
        [_editGestures addObject:g];
    }
}

- (KeyButton *)button:(NSString *)ident symbol:(NSString *)sym or:(NSString *)fallback caption:(NSString *)caption
                 scan:(uint8_t)sc icon:(CGFloat)pt radius:(CGFloat)r {
    KeyButton *b = [[KeyButton alloc] initWithSymbol:symbol(sym, fallback, pt) caption:caption scan:sc radius:r];
    [self addItem:b ident:ident];
    return b;
}

// Default places inside the safe area, as in the RVGL port (itself after a GTA-style mobile layout):
// the left thumb steers on a capsule with look-behind above its right end; the right thumb has the
// pedals at the bottom corner (accelerator largest) and two columns of race buttons above them
// (auto-accelerate and reset over the accelerator, horn/siren and spike strip over the brake); small
// pause, map and camera buttons in a column at the top left, Enter at the top right
// (handbrake, gears and lights are on the gamepad only).
static CGRect disc(CGFloat cx, CGFloat cy, CGFloat d) { return CGRectMake(cx - d / 2, cy - d / 2, d, d); }
static NSValue *val(CGRect r) { return [NSValue valueWithCGRect:r]; }
- (NSDictionary<NSString *, NSValue *> *)defaultFrames {
    CGRect g = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    const CGFloat m = 14, s = 10;
    CGFloat L = CGRectGetMinX(g) + m, R = CGRectGetMaxX(g) - m, T = CGRectGetMinY(g) + m, B = CGRectGetMaxY(g) - m;
    // circles by importance: accelerator, brake, race buttons, Enter, the small top-left ones
    const CGFloat dGas = 100, dBrake = 88, dRace = 66, dEnter = 58, dSmall = 52;
    CGRect steer = CGRectMake(L, B - 104, 232, 104);
    CGRect gas = CGRectMake(R - dGas, B - dGas, dGas, dGas);
    CGRect brake = CGRectMake(gas.origin.x - s - dBrake, B - dBrake, dBrake, dBrake);
    CGFloat gx = CGRectGetMidX(gas), bx = CGRectGetMidX(brake);
    CGFloat c1 = gas.origin.y - s - dRace / 2, b1 = brake.origin.y - s - dRace / 2;
    return @{
        @"steer" : val(steer),
        @"back" : val(disc(CGRectGetMaxX(steer) - dRace / 2, steer.origin.y - s - dRace / 2, dRace)),
        @"gas" : val(gas),
        @"brake" : val(brake),
        @"cruise" : val(disc(gx, c1, dRace)),
        @"reset" : val(disc(gx, c1 - s - dRace, dRace)),
        @"horn" : val(disc(bx, b1, dRace)),
        @"spike" : val(disc(bx, b1 - s - dRace, dRace)),
        @"pause" : val(disc(L + dSmall / 2, T + dSmall / 2, dSmall)),
        @"map" : val(disc(L + dSmall / 2, T + dSmall * 1.5 + s, dSmall)),
        @"cam" : val(disc(L + dSmall / 2, T + dSmall * 2.5 + 2 * s, dSmall)),
        @"enter" : val(disc(R - dEnter / 2, T + dEnter / 2, dEnter)),
    };
}

- (CGFloat)overlayAlpha {
    NSNumber *a = [[NSUserDefaults standardUserDefaults] objectForKey:kOverlayAlpha];
    return a ? a.doubleValue : 1;        // the discs are see-through themselves
}

- (void)layoutOverlay {
    if (!_items) return;
    CGSize sz = self.view.bounds.size;
    NSDictionary *def = [self defaultFrames];
    for (NSString *ident in _items) {
        UIView<OverlayItem> *v = _items[ident];
        CGRect d = [def[ident] CGRectValue];
        NSDictionary *o = _layout[ident];
        v.transform = CGAffineTransformIdentity;
        v.bounds = CGRectMake(0, 0, d.size.width, d.size.height);
        v.center = o[@"x"] ? CGPointMake([o[@"x"] doubleValue] * sz.width, [o[@"y"] doubleValue] * sz.height)
                           : CGPointMake(CGRectGetMidX(d), CGRectGetMidY(d));
        v.scale = o[@"s"] ? [o[@"s"] doubleValue] : 1;
        v.haptic = o[@"h"] ? [o[@"h"] boolValue] : YES;
        v.transform = CGAffineTransformMakeScale(v.scale, v.scale);
    }
    _controls.alpha = [self overlayAlpha];
    [self layoutMenuControls];
}

// Menu screens are 4:3 with black bars beside them (the Dynamic Island side too): their buttons
// go in the bars, ▲▼◀▶ on the left and Enter/Esc on the right, so nothing covers the menu.
- (void)layoutMenuControls {
    CGSize sz = self.view.bounds.size;
    UIEdgeInsets in = self.view.safeAreaInsets;
    CGFloat availW = sz.width - in.left - in.right, picH = sz.height, picW = picH * 4 / 3;
    if (picW > availW) { picW = availW; picH = picW * 3 / 4; }
    CGFloat picX = in.left + (availW - picW) / 2;
    CGFloat leftW = picX - in.left, rightW = sz.width - in.right - (picX + picW);
    CGFloat cxL = in.left + leftW / 2, cxR = picX + picW + rightW / 2, cy = sz.height / 2;
    CGFloat k = MIN(1, MIN(leftW, rightW) / 124);       // narrower bars (iPad): smaller buttons
    if (k < 0.5) k = 0.5;
    // a 4:3 iPad has no bars at all: the buttons then reach over the picture's edge instead of half off the screen
    cxL = MAX(cxL, in.left + (32 + 26) * k + 4);
    cxR = MIN(cxR, sz.width - in.right - 38 * k - 4);
    NSDictionary *place = @{
        @"m_up" : @[ @(cxL), @(cy - 58 * k), @52, @52 ], @"m_down" : @[ @(cxL), @(cy + 58 * k), @52, @52 ],
        @"m_left" : @[ @(cxL - 32 * k), @(cy), @52, @52 ], @"m_right" : @[ @(cxL + 32 * k), @(cy), @52, @52 ],
        @"m_enter" : @[ @(cxR), @(cy - 38 * k), @76, @64 ], @"m_esc" : @[ @(cxR), @(cy + 38 * k), @76, @64 ],
    };
    for (KeyButton *b in _menuButtons) {
        NSArray *p = place[b.accessibilityIdentifier];
        b.transform = CGAffineTransformIdentity;
        b.bounds = CGRectMake(0, 0, [p[2] doubleValue], [p[3] doubleValue]);
        b.center = CGPointMake([p[0] doubleValue], [p[1] doubleValue]);
        b.scale = k;
        b.transform = CGAffineTransformMakeScale(k, k);
    }
    // ⚙︎: top of the right bar on menu screens; in a race at the top of the side bar the picture is not
    // drawn in (the Dynamic Island side), or top centre without one
    const CGFloat dGear = 42;
    CGPoint race = in.left >= 40 ? CGPointMake(in.left / 2, MAX(in.top, 4) + dGear / 2 + 2)
                                 : CGPointMake(sz.width / 2, in.top + dGear / 2 + 8);
    _gear.bounds = CGRectMake(0, 0, dGear, dGear);
    _gear.center = _menuMode ? CGPointMake(cxR, in.top + dGear / 2 + 4) : race;
    _kbd.bounds = CGRectMake(0, 0, dGear, dGear);
    _kbd.center = CGPointMake(cxR, sz.height - in.bottom - dGear / 2 - 4);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutOverlay];
}

- (void)buildControls {
    _controls = [[PassthroughView alloc] initWithFrame:self.view.bounds];
    _controls.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _controls.multipleTouchEnabled = YES;
    _controls.backgroundColor = UIColor.clearColor;
    [self.view addSubview:_controls];
    _items = [NSMutableDictionary dictionary];
    _editGestures = [NSMutableArray array];
    _layout = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:kOverlayLayout] mutableCopy] ?: [NSMutableDictionary dictionary];

    _steerPad = [SteerPad new];
    [self addItem:_steerPad ident:@"steer"];
    // an icon with its name (the small top-left ones: icon only), and a badge for the gamepad input
    // that does the same (the gamepad timer below; "R←" etc. are the right stick pushed that way)
    [self button:@"back" symbol:@"arrow.uturn.backward" or:nil caption:@"후방" scan:K_BACK icon:22 radius:33].badgeText = @"R↓";
    KeyButton *gas = [self button:@"gas" symbol:@"pedal.accelerator.fill" or:@"arrowtriangle.up.fill" caption:@"가속" scan:K_GAS icon:30 radius:50];
    gas.slop = 10;
    gas.badgeText = @"RT";
    KeyButton *brake = [self button:@"brake" symbol:@"pedal.brake.fill" or:@"arrowtriangle.down.fill" caption:@"브레이크" scan:K_BRAKE icon:26 radius:44];
    brake.slop = 8;
    brake.badgeText = @"LT";
    [self button:@"spike" symbol:@"exclamationmark.triangle.fill" or:nil caption:@"스파이크" scan:K_SPIKE icon:22 radius:33].badgeText = @"R3";
    [self button:@"horn" symbol:@"megaphone.fill" or:nil caption:@"경적" scan:K_HORN icon:22 radius:33].badgeText = @"L3";
    CruiseButton *cruise = [[CruiseButton alloc] initWithSymbol:symbol(@"speedometer", @"gauge", 22) caption:@"오토 가속"
                                                           scan:K_GAS radius:33];
    [self addItem:cruise ident:@"cruise"];
    g_cruise_button = cruise;
    [self button:@"pause" symbol:@"pause.fill" or:nil caption:nil scan:K_ESC icon:20 radius:26].badgeText = @"B";
    [self button:@"map" symbol:@"map.fill" or:nil caption:nil scan:K_MAP icon:20 radius:26].badgeText = @"R←";
    [self button:@"cam" symbol:@"video.fill" or:nil caption:nil scan:K_CAM icon:20 radius:26].badgeText = @"Y";
    [self button:@"enter" symbol:@"return" or:nil caption:@"확인" scan:K_ENTER icon:18 radius:29].badgeText = @"A";
    [self button:@"reset" symbol:@"arrow.counterclockwise" or:nil caption:@"리셋" scan:K_RESET icon:22 radius:33].badgeText = @"R→";

    // menu screens: arrows and Enter/Esc in the black bars (not editable: they follow the picture)
    _menuButtons = [NSMutableArray array];
    struct { NSString *ident, *sym, *caption; uint8_t scan; CGFloat icon; } menu[] = {
        { @"m_up", @"chevron.up", nil, K_GAS, 20 }, { @"m_down", @"chevron.down", nil, K_BRAKE, 20 },
        { @"m_left", @"chevron.left", nil, K_LEFT, 20 }, { @"m_right", @"chevron.right", nil, K_RIGHT, 20 },
        { @"m_enter", @"return", @"확인", K_ENTER, 18 }, { @"m_esc", @"arrow.uturn.backward", @"뒤로", K_ESC, 18 },
    };
    for (size_t i = 0; i < sizeof menu / sizeof menu[0]; i++) {
        KeyButton *b = [[KeyButton alloc] initWithSymbol:symbol(menu[i].sym, nil, menu[i].icon) caption:menu[i].caption
                                                    scan:menu[i].scan radius:16];
        b.accessibilityIdentifier = menu[i].ident;
        b.hidden = YES;
        [_controls addSubview:b];
        [_menuButtons addObject:b];
    }

    // the settings button is always there so the editor can be reached; the icon is an image view
    // over the face (a UIButton's own image ended up under the background and the button showed blank)
    _gear = [self roundButton:@"gearshape.fill" action:@selector(showSettings)];
    // menu screens: keyboard (player name, codes) at the bottom of the right bar
    _kbd = [self roundButton:@"keyboard" action:@selector(askText)];
    _kbd.hidden = YES;
    [self layoutOverlay];

    // menu or race: the game's Glide window tells (hle_glide_in_menu)
    // also lets the game go on once no window is over it any more (updatePause)
    [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        [self updatePause];
        // a closed window may leave nobody with the keyboard: take it back for the hardware keys
        if (![self wantsPause] && !self.isFirstResponder && !self.pcField.isFirstResponder) [self becomeFirstResponder];
        BOOL m = hle_glide_in_menu() != 0;
        if (m == self.menuMode) return;
        self.menuMode = m;
        [self releaseOverlayKeys];
        [self applyOverlayVisibility];
        [self layoutMenuControls];
    }];
}

- (UIButton *)roundButton:(NSString *)sym action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    face_in(b);
    icon_in(b, symbol(sym, nil, 17), nil);
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [_controls addSubview:b];
    return b;
}

- (void)releaseOverlayKeys {
    set_cruise(NO);                            // menu screen, gamepad or editor: no throttle left on
    [_steerPad releaseAll];
    for (UIView *v in [_items.allValues arrayByAddingObjectsFromArray:_menuButtons])
        if ([v isKindOfClass:KeyButton.class]) { key(((KeyButton *)v).scan, 0); ((KeyButton *)v).glow.alpha = 0; }
}

// race controls in a race, menu buttons on menu screens, neither with a gamepad (⚙︎ always);
// the editor shows the race controls
- (void)applyOverlayVisibility {
    BOOL race = g_overlay_editing || (!_padConnected && !_menuMode);
    BOOL menu = !g_overlay_editing && !_padConnected && _menuMode;
    for (UIView *v in _items.allValues) v.hidden = !race;
    for (UIView *v in _menuButtons) v.hidden = !menu;
    _gear.hidden = g_overlay_editing;
    _kbd.hidden = g_overlay_editing || !_menuMode;
}

// the touch controls are hidden while a gamepad is connected (taps on the picture and ⚙︎ stay)
- (void)updateOverlay {
    if (g_overlay_editing) return;
    BOOL pad = NO;
    for (GCController *c in GCController.controllers)
        if (c.extendedGamepad) pad = YES;
    _padConnected = pad;
    [self releaseOverlayKeys];                 // nothing stays held when a button disappears or a pad leaves
    [self applyOverlayVisibility];
    plat_log("gamepad %s, touch controls %s", pad ? "connected" : "none", pad ? "hidden" : "shown");
}

// ---------------------------------------------------------------- overlay editor

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;                                // move and pinch at the same time
}

- (void)storeItem:(UIView<OverlayItem> *)v persist:(BOOL)persist {
    CGSize sz = self.view.bounds.size;
    _layout[v.accessibilityIdentifier] = @{ @"x" : @(v.center.x / sz.width), @"y" : @(v.center.y / sz.height),
                                            @"s" : @(v.scale), @"h" : @(v.haptic) };
    if (persist) [[NSUserDefaults standardUserDefaults] setObject:_layout forKey:kOverlayLayout];
}

- (void)selectItem:(UIView<OverlayItem> *)v {
    for (UIView *o in _items.allValues) o.layer.borderWidth = 0;
    _selected = v.accessibilityIdentifier;
    v.layer.cornerRadius = v.radius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.borderWidth = 2;
    v.layer.borderColor = UIColor.systemYellowColor.CGColor;
    _editTitle.text = [NSString stringWithFormat:@"선택: %@", item_name(_selected)];
    _sizeSlider.enabled = _hapticSwitch.enabled = YES;
    _sizeSlider.value = v.scale;
    _hapticSwitch.on = v.haptic;
}

- (void)setScale:(CGFloat)s of:(UIView<OverlayItem> *)v {
    v.scale = MIN(MAX(s, 0.5), 2.0);
    v.transform = CGAffineTransformMakeScale(v.scale, v.scale);
    if ([v.accessibilityIdentifier isEqualToString:_selected]) _sizeSlider.value = v.scale;
}

- (void)editTap:(UITapGestureRecognizer *)g { [self selectItem:(UIView<OverlayItem> *)g.view]; }

- (void)editPan:(UIPanGestureRecognizer *)g {
    UIView<OverlayItem> *v = (UIView<OverlayItem> *)g.view;
    if (g.state == UIGestureRecognizerStateBegan) [self selectItem:v];
    CGPoint t = [g translationInView:self.view];
    CGSize sz = self.view.bounds.size;
    v.center = CGPointMake(MIN(MAX(v.center.x + t.x, 0), sz.width), MIN(MAX(v.center.y + t.y, 0), sz.height));
    [g setTranslation:CGPointZero inView:self.view];
    [self storeItem:v persist:g.state == UIGestureRecognizerStateEnded];
}

- (void)editPinch:(UIPinchGestureRecognizer *)g {
    UIView<OverlayItem> *v = (UIView<OverlayItem> *)g.view;
    if (g.state == UIGestureRecognizerStateBegan) [self selectItem:v];
    [self setScale:v.scale * g.scale of:v];
    g.scale = 1;
    [self storeItem:v persist:g.state == UIGestureRecognizerStateEnded];
}

- (void)sizeChanged:(UISlider *)s {
    UIView<OverlayItem> *v = _items[_selected];
    if (!v) return;
    [self setScale:s.value of:v];
    [self storeItem:v persist:YES];
}

- (void)hapticChanged:(UISwitch *)w {
    UIView<OverlayItem> *v = _items[_selected];
    if (!v) return;
    v.haptic = w.on;
    [self storeItem:v persist:YES];
    if (w.on) [tap_haptic() impactOccurred];
}

- (void)alphaChanged:(UISlider *)s {
    [[NSUserDefaults standardUserDefaults] setDouble:s.value forKey:kOverlayAlpha];
    _controls.alpha = s.value;
}

- (void)resetLayout {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"기본값으로 되돌리기"
        message:@"모든 버튼의 위치·크기·진동과 투명도를 처음 상태로 되돌립니다." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"취소" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"되돌리기" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [self.layout removeAllObjects];
        [d removeObjectForKey:kOverlayLayout];
        [d removeObjectForKey:kOverlayAlpha];
        self.alphaSlider.value = [self overlayAlpha];
        [self layoutOverlay];
        UIView<OverlayItem> *v = self.items[self.selected];
        if (v) [self selectItem:v];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (UIView *)editRow:(NSString *)title control:(UIView *)c {
    UILabel *l = [UILabel new];
    l.text = title;
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    l.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    [l.widthAnchor constraintEqualToConstant:52].active = YES;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[ l, c ]];
    row.spacing = 10;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (UIView *)buildEditPanel {
    UIView *p = [UIView new];
    glass_in(p, 20);
    _editTitle = [UILabel new];
    _editTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    _editTitle.textColor = UIColor.whiteColor;
    _sizeSlider = [UISlider new];
    _sizeSlider.minimumValue = 0.5;
    _sizeSlider.maximumValue = 2.0;
    [_sizeSlider addTarget:self action:@selector(sizeChanged:) forControlEvents:UIControlEventValueChanged];
    _hapticSwitch = [UISwitch new];
    [_hapticSwitch addTarget:self action:@selector(hapticChanged:) forControlEvents:UIControlEventValueChanged];
    _alphaSlider = [UISlider new];
    _alphaSlider.minimumValue = 0.1;
    _alphaSlider.maximumValue = 1.0;
    [_alphaSlider addTarget:self action:@selector(alphaChanged:) forControlEvents:UIControlEventValueChanged];
    UILabel *hint = [UILabel new];
    hint.text = @"버튼을 끌어서 옮기고, 두 손가락으로 벌리거나 좁혀 크기를 바꿉니다. 이 창도 끌어서 옮길 수 있습니다.";
    hint.numberOfLines = 0;
    hint.font = [UIFont systemFontOfSize:11];
    hint.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    [reset setTitle:@"기본값" forState:UIControlStateNormal];
    reset.tintColor = UIColor.systemRedColor;
    [reset addTarget:self action:@selector(resetLayout) forControlEvents:UIControlEventTouchUpInside];
    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:@"완료" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    [done addTarget:self action:@selector(finishEditing) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[ reset, done ]];
    buttons.distribution = UIStackViewDistributionFillEqually;
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[
        _editTitle, [self editRow:@"크기" control:_sizeSlider], [self editRow:@"진동" control:_hapticSwitch],
        [self editRow:@"투명도" control:_alphaSlider], hint, buttons ]];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 10;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [p addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.leadingAnchor constraintEqualToAnchor:p.leadingAnchor constant:16],
        [st.trailingAnchor constraintEqualToAnchor:p.trailingAnchor constant:-16],
        [st.topAnchor constraintEqualToAnchor:p.topAnchor constant:14],
        [st.bottomAnchor constraintEqualToAnchor:p.bottomAnchor constant:-12],
    ]];
    CGSize fit = [p systemLayoutSizeFittingSize:CGSizeMake(300, 0) withHorizontalFittingPriority:UILayoutPriorityRequired
                          verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    p.frame = CGRectMake(0, 0, 300, fit.height);
    [p addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panelPan:)]];
    return p;
}

- (void)panelPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    g.view.center = CGPointMake(g.view.center.x + t.x, g.view.center.y + t.y);
    [g setTranslation:CGPointZero inView:self.view];
}

- (void)startEditing {
    if (g_overlay_editing) return;
    [self releaseOverlayKeys];
    g_overlay_editing = YES;
    [self updatePause];                        // the game waits while the buttons are moved
    [self applyOverlayVisibility];             // race controls, also when a gamepad or a menu hid them
    for (UIGestureRecognizer *g in _editGestures) g.enabled = YES;
    if (!_editPanel) _editPanel = [self buildEditPanel];
    [self.view addSubview:_editPanel];
    _editPanel.center = CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2);
    _editTitle.text = @"편집할 버튼을 누르세요";
    _selected = nil;
    _sizeSlider.enabled = _hapticSwitch.enabled = NO;
    _alphaSlider.value = [self overlayAlpha];
    [self layoutOverlay];
}

- (void)finishEditing {
    for (UIGestureRecognizer *g in _editGestures) g.enabled = NO;
    for (UIView *v in _items.allValues) v.layer.borderWidth = 0;
    _selected = nil;
    [_editPanel removeFromSuperview];
    _gear.hidden = NO;
    [[NSUserDefaults standardUserDefaults] setObject:_layout forKey:kOverlayLayout];
    g_overlay_editing = NO;
    [self updatePause];
    [self updateOverlay];
}

// A ⏎, B/Menu Esc, X handbrake, Y camera, R2/L2 gas/brake, R1/L1 gear up/down, L3 horn/siren,
// R3 spike strip, right stick: down look behind, up lights, left map, right reset; Options map
- (void)setupGamepads {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (NSNotificationName n in @[ GCControllerDidConnectNotification, GCControllerDidDisconnectNotification ])
        [nc addObserverForName:n object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *x) { [self updateOverlay]; }];
    [self updateOverlay];
    [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *t) {
        GCExtendedGamepad *p = GCController.current.extendedGamepad;
        if (!p) {
            if (g_pad_steer || g_pad_throttle) { g_pad_steer = g_pad_throttle = 0; update_joy(); }
            return;
        }
        float x = p.leftThumbstick.xAxis.value;
        float rx = p.rightThumbstick.xAxis.value, ry = p.rightThumbstick.yAxis.value;
        float rt = p.rightTrigger.value, lt = p.leftTrigger.value;
        // menus: the stick and triggers act as arrow keys; races: analog steering and throttle
        BOOL menu = hle_glide_in_menu() != 0;
        key(K_LEFT, (menu && x < -0.5f) || p.dpad.left.isPressed);
        key(K_RIGHT, (menu && x > 0.5f) || p.dpad.right.isPressed);
        key(K_GAS, (menu && rt > 0.2f) || p.dpad.up.isPressed);
        key(K_BRAKE, (menu && lt > 0.2f) || p.dpad.down.isPressed);
        g_pad_steer = menu || fabsf(x) < 0.08f ? 0 : x;
        g_pad_throttle = menu ? 0 : lt - rt;
        update_joy();                          // L2 / D-pad down pause auto-accelerate while held
        key(K_ENTER, p.buttonA.isPressed);
        key(K_ESC, p.buttonB.isPressed || p.buttonMenu.isPressed);
        key(K_HAND, p.buttonX.isPressed);
        key(K_CAM, p.buttonY.isPressed);
        key(K_UP, p.rightShoulder.isPressed);
        key(K_DOWN, p.leftShoulder.isPressed);
        key(K_HORN, p.leftThumbstickButton.isPressed);
        key(K_SPIKE, p.rightThumbstickButton.isPressed);
        key(K_BACK, ry < -0.6f);
        key(K_LIGHTS, ry > 0.6f);
        key(K_MAP, rx < -0.6f || p.buttonOptions.isPressed);
        key(K_RESET, rx > 0.8f);
    }];
}

// ---------------------------------------------------------------- import

- (void)pickFolder {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ]];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)c { _pickingSync = NO; }

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *src = urls.firstObject;
    if (_pickingSync) {                        // the save sharing folder, not a game folder
        _pickingSync = NO;
        if (!src) return;
        if (!port_sync_set_folder(src)) { [self showNote:@"세이브 공유" text:@"그 폴더는 쓸 수 없습니다."]; return; }
        [self syncNow:0];
        return;
    }
    if (!src) return;
    [self showMessage:@"복사 중… (수백 MB라 몇 분 걸릴 수 있습니다)" import:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [src startAccessingSecurityScopedResource];
        NSString *game = [port_data_root() stringByAppendingPathComponent:@"game"];
        NSString *dst = [game stringByAppendingPathComponent:@"NFS4"];
        // Copied beside it first and moved into place only once whole: a copy cut short (the app closed, the
        // disk full) leaves no half game for locate_game_dir to start, and the game already here stays usable
        // until then, also when the folder picked is that very copy (나의 iPhone › NFS IV › game › NFS4).
        NSString *tmp = [game stringByAppendingPathComponent:@".NFS4-copying"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:tmp error:nil];   // a copy an earlier launch did not finish
        NSError *err = nil;
        BOOL ok = [fm copyItemAtURL:src toURL:[NSURL fileURLWithPath:tmp] error:&err];
        if (scoped) [src stopAccessingSecurityScopedResource];
        // the scan-bypass video in some releases is huge and unused
        if (ok)
            for (NSString *rel in [fm enumeratorAtPath:tmp])
                if ([rel.pathExtension caseInsensitiveCompare:@"mp4"] == NSOrderedSame)
                    [fm removeItemAtPath:[tmp stringByAppendingPathComponent:rel] error:nil];
        if (ok) {
            [fm removeItemAtPath:dst error:nil];
            ok = [fm moveItemAtPath:tmp toPath:dst error:&err];
        }
        if (!ok) [fm removeItemAtPath:tmp error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok) [self showMessage:[NSString stringWithFormat:@"복사 실패: %@", err.localizedDescription] import:YES];
            else [self startOrAsk];
        });
    });
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    _window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _window.rootViewController = [GameViewController new];
    [_window makeKeyAndVisible];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    return YES;
}
// on record before iOS ends the app for memory: how much was left at each warning (README section 10 diagnostics)
- (void)applicationDidReceiveMemoryWarning:(UIApplication *)app {
    plat_log("MEMORY warning: %llu MB still available to the app", (unsigned long long)(os_proc_available_memory() >> 20));
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
