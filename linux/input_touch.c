/* Dotyk: tylko w menu, jako touchpad (przesunięcie = kursor, tap = klik). Wyścig nie ma nakładki. */
#include "input_touch.h"
#include "plat.h"
#include <stdlib.h>

#define MAX_FINGERS 10
typedef struct { int active; SDL_FingerID id; float x, y, x0, y0; uint64_t t0; int moved; } Finger;
static Finger fingers[MAX_FINGERS];
static uint64_t click_until;
static float menu_rx, menu_ry;

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
        SDL_Window *window = SDL_GetKeyboardFocus(); /* SDL 2.0.10 nie ma windowID */
        if (!window) window = SDL_GetMouseFocus();
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

void touch_keys(uint8_t next[256], int menu) {
    (void)next;
    if (!menu) { menu_rx = menu_ry = 0; return; }   /* w wyścigu dotyk nic nie robi: sterowanie z pada lub klawiatury */
    int dx = (int)menu_rx, dy = (int)menu_ry;
    plat_mouse_dx += dx; plat_mouse_dy += dy;
    menu_rx -= dx; menu_ry -= dy;
}
