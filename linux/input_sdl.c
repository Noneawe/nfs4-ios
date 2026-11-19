#include "input_sdl.h"
#include "input_touch.h"
#include "plat.h"
#include <SDL.h>
#include <stdlib.h>
#include <string.h>

void hle_key_event(uint8_t code, int down);
void plat_toggle_fps(void);   /* plat_linux.c: licznik klatek (NFS4_SHOW_FPS, F3, L3+R3) */
static SDL_GameController *controller;
static uint8_t keyboard[256], gamepad[256];
static int deadzone = 8000, analog_steering;
static uint64_t last_poll;
static float mouse_x, mouse_y;
static int mouse_button;

static void update_key(unsigned code) {
    uint8_t value = keyboard[code] || gamepad[code] ? 0x80 : 0;
    if (plat_keys[code] != value) {
        plat_keys[code] = value;
        hle_key_event((uint8_t)code, value != 0);
    }
}
void linux_input_key(uint8_t code, int down) {
    keyboard[code] = down != 0;
    update_key(code);
}
void linux_input_mouse(int down) { mouse_button = down != 0; plat_mouse_buttons = down ? 0x80 : 0; }
void linux_input_reset(void) {
    memset(keyboard, 0, sizeof keyboard);
    memset(gamepad, 0, sizeof gamepad);
    for (unsigned code = 0; code < 256; ++code) update_key(code);
    plat_joy_x = plat_joy_y = 0;
    plat_joy_buttons = 0;
    plat_mouse_buttons = 0;
    mouse_button = 0;
}
void linux_input_init(void) {
    const char *setting = getenv("NFS4_DEADZONE");
    if (setting) {
        char *end;
        long value = strtol(setting, &end, 10);
        if (!*setting || *end || value < 0 || value > 30000)
            plat_fatal("NFS4_DEADZONE: oczekiwano liczby 0..30000");
        deadzone = (int)value;
    }
    analog_steering = getenv("NFS4_ANALOG_STEERING") != NULL;
    if (SDL_InitSubSystem(SDL_INIT_GAMECONTROLLER) < 0)
        plat_log("SDL kontroler niedostępny: %s", SDL_GetError());
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
}
static float axis(SDL_GameControllerAxis index) {
    int raw = SDL_GameControllerGetAxis(controller, index);
    if (abs(raw) <= deadzone) return 0;
    return raw < 0 ? (raw + deadzone) / (float)(32768 - deadzone)
                   : (raw - deadzone) / (float)(32767 - deadzone);
}
static int button(SDL_GameControllerButton index) {
    return SDL_GameControllerGetButton(controller, index) != 0;
}
int linux_input_poll(int menu) {
    uint8_t next[256] = {0};
    int pad_mouse = 0;
    uint64_t now = plat_ticks_us();
    float elapsed = last_poll ? (float)(now - last_poll) / 1000000 : 0;
    if (elapsed > 0.05f) elapsed = 0.05f;
    last_poll = now;
    if (controller && !SDL_GameControllerGetAttached(controller)) {
        SDL_GameControllerClose(controller);
        controller = NULL;
    }
    if (!controller) {
        for (int i = 0; i < SDL_NumJoysticks(); ++i) {
            if (!SDL_IsGameController(i)) continue;
            controller = SDL_GameControllerOpen(i);
            if (controller) {
                plat_log("SDL kontroler: %s", SDL_GameControllerName(controller));
                break;
            }
        }
    }
    plat_joy_x = plat_joy_y = 0;
    plat_joy_buttons = 0;
    if (controller) {
        SDL_GameControllerUpdate();
        float x = axis(SDL_CONTROLLER_AXIS_LEFTX), y = axis(SDL_CONTROLLER_AXIS_LEFTY);
        /* wyścig czyta joystick "Touch Wheel": oś Y ujemna = gaz, dodatnia = hamulec; tylko RT/LT, pionowy wychył gałki jest ignorowany */
        const float gas = axis(SDL_CONTROLLER_AXIS_TRIGGERRIGHT), brake = axis(SDL_CONTROLLER_AXIS_TRIGGERLEFT);
        plat_joy_x = x; plat_joy_y = menu ? y : brake - gas;
        if (plat_joy_y < -1) plat_joy_y = -1; else if (plat_joy_y > 1) plat_joy_y = 1;
        next[0xcb] = button(SDL_CONTROLLER_BUTTON_DPAD_LEFT) || (x < 0 && (menu || !analog_steering));
        next[0xcd] = button(SDL_CONTROLLER_BUTTON_DPAD_RIGHT) || (x > 0 && (menu || !analog_steering));
        next[0xc8] = button(SDL_CONTROLLER_BUTTON_DPAD_UP) || (menu && y < 0);
        next[0xd0] = button(SDL_CONTROLLER_BUTTON_DPAD_DOWN) || (menu && y > 0);
        if (menu) {
            next[0x1c] = button(SDL_CONTROLLER_BUTTON_A) || button(SDL_CONTROLLER_BUTTON_START);
            next[0x01] = button(SDL_CONTROLLER_BUTTON_B) || button(SDL_CONTROLLER_BUTTON_BACK);
            mouse_x += axis(SDL_CONTROLLER_AXIS_RIGHTX) * elapsed * 600;
            mouse_y += axis(SDL_CONTROLLER_AXIS_RIGHTY) * elapsed * 600;
            int dx = (int)mouse_x, dy = (int)mouse_y;
            plat_mouse_dx += dx; plat_mouse_dy += dy;
            mouse_x -= dx; mouse_y -= dy;
            pad_mouse = button(SDL_CONTROLLER_BUTTON_X);
        } else {
            /* układ jak w nowych grach wyścigowych: RT gaz, LT hamulec/wsteczny, lewa gałka kierownica,
             * A hamulec ręczny, Y kamera, LB/RB biegi w dół/w górę, Start pauza */
            next[0xc8] |= axis(SDL_CONTROLLER_AXIS_TRIGGERRIGHT) > 0;
            next[0xd0] |= axis(SDL_CONTROLLER_AXIS_TRIGGERLEFT) > 0;
            next[0x39] = button(SDL_CONTROLLER_BUTTON_A);
            next[0x2e] = button(SDL_CONTROLLER_BUTTON_Y);
            next[0x1e] = button(SDL_CONTROLLER_BUTTON_LEFTSHOULDER);
            next[0x2c] = button(SDL_CONTROLLER_BUTTON_RIGHTSHOULDER);
            next[0x01] = button(SDL_CONTROLLER_BUTTON_START);
            next[0x0f] = button(SDL_CONTROLLER_BUTTON_BACK);
        }
        /* przyciski joysticka 0..7: A (hamulec ręczny), Y (kamera), LB, RB, X, B, Start, Back */
        static const SDL_GameControllerButton buttons[8] = {
            SDL_CONTROLLER_BUTTON_A, SDL_CONTROLLER_BUTTON_Y, SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
            SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, SDL_CONTROLLER_BUTTON_X,
            SDL_CONTROLLER_BUTTON_B, SDL_CONTROLLER_BUTTON_START, SDL_CONTROLLER_BUTTON_BACK
        };
        static int fps_chord;   /* L3 + R3 przełącza licznik klatek */
        const int chord = button(SDL_CONTROLLER_BUTTON_LEFTSTICK) && button(SDL_CONTROLLER_BUTTON_RIGHTSTICK);
        if (chord && !fps_chord) plat_toggle_fps();
        fps_chord = chord;
        for (unsigned i = 0; i < 8; ++i) if (button(buttons[i])) plat_joy_buttons |= 1u << i;
    }
    touch_keys(next, menu);
    for (unsigned code = 0; code < 256; ++code) {
        gamepad[code] = next[code];
        update_key(code);
    }
    plat_mouse_buttons = mouse_button || pad_mouse || touch_click() ? 0x80 : 0;
    return !controller || !(button(SDL_CONTROLLER_BUTTON_START) && button(SDL_CONTROLLER_BUTTON_BACK));
}
void linux_input_cleanup(void) {
    if (controller) SDL_GameControllerClose(controller);
    controller = NULL;
    linux_input_reset();
}

int linux_input_self_test(void) {
#if SDL_VERSION_ATLEAST(2, 0, 14)
    int device = SDL_JoystickAttachVirtual(SDL_JOYSTICK_TYPE_GAMECONTROLLER, 6, 15, 0);
    if (device < 0) return 1;
    SDL_Joystick *joystick = SDL_JoystickOpen(device);
    if (!joystick) return 1;
    char guid[33], mapping[512];
    SDL_JoystickGetGUIDString(SDL_JoystickGetGUID(joystick), guid, sizeof guid);
    SDL_snprintf(mapping, sizeof mapping,
        "%s,NFS4 test,a:b0,b:b1,x:b2,y:b3,back:b4,guide:b5,start:b6,leftstick:b7,rightstick:b8,"
        "leftshoulder:b9,rightshoulder:b10,dpup:b11,dpdown:b12,dpleft:b13,dpright:b14,"
        "leftx:a0,lefty:a1,rightx:a2,righty:a3,lefttrigger:a4,righttrigger:a5,", guid);
    if (SDL_GameControllerAddMapping(mapping) < 0) return 1;
    linux_input_poll(1);
    SDL_JoystickSetVirtualButton(joystick, 0, 1);
    SDL_JoystickSetVirtualAxis(joystick, 0, -20000);
    SDL_JoystickUpdate(); linux_input_poll(1);
    int ok = plat_keys[0x1c] == 0x80 && plat_keys[0xcb] == 0x80 && plat_joy_x < 0;
    linux_input_key(0x1c, 1);
    SDL_JoystickSetVirtualButton(joystick, 0, 0);
    SDL_JoystickUpdate(); linux_input_poll(1);
    ok &= plat_keys[0x1c] == 0x80;
    linux_input_key(0x1c, 0);
    ok &= plat_keys[0x1c] == 0;
    SDL_JoystickSetVirtualButton(joystick, 0, 1);
    SDL_JoystickUpdate(); linux_input_poll(0);
    ok &= plat_keys[0x39] == 0x80 && (plat_joy_buttons & 1);
    SDL_JoystickSetVirtualAxis(joystick, 1, -20000);  /* lewa gałka do przodu w wyścigu: ani gaz, ani hamulec */
    SDL_JoystickUpdate(); linux_input_poll(0);
    ok &= plat_joy_y == 0 && plat_keys[0xc8] == 0 && plat_keys[0xd0] == 0;
    SDL_JoystickSetVirtualAxis(joystick, 1, 20000);
    SDL_JoystickUpdate(); linux_input_poll(0);
    ok &= plat_joy_y == 0 && plat_keys[0xc8] == 0 && plat_keys[0xd0] == 0;
    SDL_JoystickSetVirtualAxis(joystick, 1, 0);
    SDL_JoystickSetVirtualAxis(joystick, 5, 20000);   /* RT = gaz: klawisz w górę i oś Y ujemna */
    SDL_JoystickUpdate(); linux_input_poll(0);
    ok &= plat_keys[0xc8] == 0x80 && plat_joy_y < 0;
    SDL_JoystickSetVirtualAxis(joystick, 5, 0);
    SDL_JoystickSetVirtualAxis(joystick, 4, 20000);   /* LT = hamulec: klawisz w dół i oś Y dodatnia */
    SDL_JoystickUpdate(); linux_input_poll(0);
    ok &= plat_keys[0xd0] == 0x80 && plat_joy_y > 0;
    SDL_JoystickSetVirtualAxis(joystick, 4, 0);
    SDL_JoystickUpdate(); linux_input_poll(0);
    SDL_JoystickSetVirtualButton(joystick, 4, 1);
    SDL_JoystickSetVirtualButton(joystick, 6, 1);
    SDL_JoystickUpdate();
    ok &= !linux_input_poll(0);
    SDL_JoystickSetVirtualButton(joystick, 4, 0);
    SDL_JoystickSetVirtualButton(joystick, 6, 0);
    SDL_JoystickUpdate();
    ok &= linux_input_poll(0);
    SDL_JoystickClose(joystick);
    SDL_JoystickDetachVirtual(device);
    SDL_GameControllerUpdate(); linux_input_poll(0);
    ok &= plat_keys[0xc8] == 0 && plat_keys[0xcb] == 0 && plat_joy_buttons == 0 && plat_joy_x == 0;
    return ok ? 0 : 1;
#else
    plat_log("Test kontrolera wirtualnego wymaga SDL >= 2.0.14");
    return 77;
#endif
}
