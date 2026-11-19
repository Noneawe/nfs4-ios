#pragma once
#include <SDL.h>
#include <stdint.h>

void touch_event(const SDL_Event *event);          /* SDL_FINGER* events */
void touch_keys(uint8_t next[256], int menu);      /* menu: przesunięcie palca -> kursor gry */
int touch_click(void);                             /* menu tap: 1 while the left button should be down */
