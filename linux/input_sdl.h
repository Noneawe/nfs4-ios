#pragma once
#include <stdint.h>

void linux_input_init(void);
void linux_input_key(uint8_t code, int down);
void linux_input_mouse(int down);
void linux_input_reset(void);
int linux_input_poll(int menu);
void linux_input_cleanup(void);
int linux_input_self_test(void);
