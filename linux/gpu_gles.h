#pragma once

/* Window/context creation and destruction stay on the SDL main thread. */
void gpu_gles_prepare(void);
void gpu_gles_release(void);
void gpu_gles_cleanup(void);
int gpu_gles_self_test(void);
