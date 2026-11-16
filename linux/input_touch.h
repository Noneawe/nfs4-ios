#pragma once
#include <SDL.h>
#include <stdint.h>

void touch_event(const SDL_Event *event);          /* SDL_FINGER* events */
void touch_keys(uint8_t next[256], int menu);      /* ORs scancodes held by on-screen buttons */
int touch_click(void);                             /* menu tap: 1 while the left button should be down */
void touch_draw(SDL_Renderer *renderer, int menu); /* race overlay, window coordinates */
void touch_joy(float *x, float *y, uint32_t *buttons); /* dodatek do osi i przycisków joysticka */
