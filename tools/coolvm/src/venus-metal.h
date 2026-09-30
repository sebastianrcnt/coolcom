/* Optional host image presentation, no cell/atlas rendering lives here. */
#pragma once
#include <stdbool.h>
#include <stdint.h>
#ifdef COOLVM_VENUS
void *venus_metal_retain(void *texture);
void venus_metal_release(void *texture);
bool venus_metal_size(void *texture, uint32_t width, uint32_t height);
bool venus_metal_snapshot(void *texture, uint8_t **pixels, uint32_t width, uint32_t height);
bool venus_metal_present(void *texture, void *layer, uint32_t width, uint32_t height);
void venus_metal_hide(void);
#endif
