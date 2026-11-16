/* Dotyk: w menu touchpad (przesunięcie = kursor, tap = klik), w wyścigu przyciski na ekranie. */
#include "input_touch.h"
#include "plat.h"

#define MAX_FINGERS 10
typedef struct { int active; SDL_FingerID id; float x, y, x0, y0; uint64_t t0; int moved; } Finger;
static Finger fingers[MAX_FINGERS];
static uint64_t click_until;
static float menu_rx, menu_ry;
static int view_w, view_h, frame_w, frame_h;   /* okno i klatka gry (ustawiane przy rysowaniu) */   /* ułamki pikseli gry niezastosowane jeszcze do kursora */

/* Przyciski we współrzędnych klatki gry 0..1 (rysowane i testowane względem obrazu, nie okna): x0, y0, x1, y1, kod skanowania gry, etykieta */
typedef struct { float x0, y0, x1, y1; uint8_t code; const char *label; } Button;
static const Button buttons[] = {
    {0.03f, 0.60f, 0.17f, 0.95f, 0xcb, "<"},     /* skręt w lewo */
    {0.19f, 0.60f, 0.33f, 0.95f, 0xcd, ">"},     /* skręt w prawo */
    {0.68f, 0.72f, 0.80f, 0.95f, 0xd0, "B"},     /* hamulec */
    {0.82f, 0.52f, 0.97f, 0.95f, 0xc8, "GAZ"},   /* gaz */
    {0.55f, 0.82f, 0.65f, 0.95f, 0x39, "HR"},    /* hamulec ręczny */
    {0.45f, 0.02f, 0.55f, 0.13f, 0x01, "II"},    /* pauza / Esc */
    {0.90f, 0.02f, 0.97f, 0.13f, 0x2e, "C"},     /* kamera */
};
#define NBUTTONS ((int)(sizeof buttons / sizeof *buttons))

static Finger *find(SDL_FingerID id) {
    for (int i = 0; i < MAX_FINGERS; ++i) if (fingers[i].active && fingers[i].id == id) return &fingers[i];
    return NULL;
}
void touch_event(const SDL_Event *event) {
    if (event->type != SDL_FINGERDOWN && event->type != SDL_FINGERMOTION && event->type != SDL_FINGERUP) return;
    const SDL_TouchFingerEvent *t = &event->tfinger;
    Finger *f = find(t->fingerId);
    if (event->type == SDL_FINGERDOWN) {
        if (f) return;
        for (int i = 0; i < MAX_FINGERS && !f; ++i) if (!fingers[i].active) f = &fingers[i];
        if (!f) return;
        *f = (Finger){1, t->fingerId, t->x, t->y, t->x, t->y, plat_ticks_us(), 0};
        return;
    }
    if (!f) return;
    if (event->type == SDL_FINGERMOTION) {
        SDL_Window *window = SDL_GetWindowFromID(t->windowID);
        int w = 0, h = 0;
        if (window) SDL_GetWindowSize(window, &w, &h);
        if (w > 0 && h > 0) {
            /* ruch palca w menu przesuwa kursor gry (obraz 640x480 wpasowany w okno) */
            float scale = (float)w / 640 < (float)h / 480 ? (float)w / 640 : (float)h / 480;
            menu_rx += t->dx * w / scale;
            menu_ry += t->dy * h / scale;
            if (SDL_fabsf((t->x - f->x0) * w) > 24 || SDL_fabsf((t->y - f->y0) * h) > 24) f->moved = 1;
        }
        f->x = t->x; f->y = t->y;
        return;
    }
    /* FINGERUP: krótki dotyk bez przesunięcia = klik */
    if (!f->moved && plat_ticks_us() - f->t0 < 300000) click_until = plat_ticks_us() + 300000;
    f->active = 0;
}
int touch_click(void) { return plat_ticks_us() < click_until; }

static int inside(const Button *b, const Finger *f) {
    if (view_w <= 0 || frame_w <= 0) return 0;
    /* palec (ułamek okna) -> ułamek klatki, z uwzględnieniem czarnych pasów */
    float scale = (float)view_w / frame_w < (float)view_h / frame_h ? (float)view_w / frame_w : (float)view_h / frame_h;
    float vw = frame_w * scale, vh = frame_h * scale;
    float fx = (f->x * view_w - (view_w - vw) / 2) / vw, fy = (f->y * view_h - (view_h - vh) / 2) / vh;
    return fx >= b->x0 && fx <= b->x1 && fy >= b->y0 && fy <= b->y1;
}
void touch_keys(uint8_t next[256], int menu) {
    if (menu) {
        int dx = (int)menu_rx, dy = (int)menu_ry;
        plat_mouse_dx += dx; plat_mouse_dy += dy;
        menu_rx -= dx; menu_ry -= dy;
        return;
    }
    menu_rx = menu_ry = 0;
    for (int i = 0; i < MAX_FINGERS; ++i) {
        if (!fingers[i].active) continue;
        for (int b = 0; b < NBUTTONS; ++b) if (inside(&buttons[b], &fingers[i])) next[buttons[b].code] = 1;
    }
}
void touch_draw(SDL_Renderer *renderer, int menu) {
    SDL_GetRendererOutputSize(renderer, &view_w, &view_h);
    SDL_RenderGetLogicalSize(renderer, &frame_w, &frame_h);
    if (menu) return;
    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
    for (int b = 0; b < NBUTTONS; ++b) {
        int held = 0;
        for (int i = 0; i < MAX_FINGERS; ++i) held |= fingers[i].active && inside(&buttons[b], &fingers[i]);
        SDL_Rect r = {(int)(buttons[b].x0 * frame_w), (int)(buttons[b].y0 * frame_h),
                      (int)((buttons[b].x1 - buttons[b].x0) * frame_w), (int)((buttons[b].y1 - buttons[b].y0) * frame_h)};
        SDL_SetRenderDrawColor(renderer, 255, 255, 255, held ? 110 : 40);
        SDL_RenderFillRect(renderer, &r);
        SDL_SetRenderDrawColor(renderer, 255, 255, 255, held ? 230 : 120);
        SDL_RenderDrawRect(renderer, &r);
    }
}
