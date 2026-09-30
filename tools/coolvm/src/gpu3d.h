#ifndef COOLVM_GPU3D_H
#define COOLVM_GPU3D_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define GPU3D_SHM_BASE 0x400000000ULL
#define GPU3D_SHM_SIZE (256ULL << 20)
#define GPU3D_REPLY_MAX 4096
/* VIRTIO_GPU_F_VIRGL, F_RESOURCE_BLOB, F_CONTEXT_INIT. */
#define GPU3D_FEATURES ((1u<<0)|(1u<<3)|(1u<<4))
#ifdef COOLVM_VENUS
bool gpu3d_init(void);
bool gpu3d_direct_supported(void);
void *gpu3d_display_texture(uint32_t *width,uint32_t *height);
void gpu3d_reset(void);
void gpu3d_cleanup(void);
bool gpu3d_resource(uint32_t id);
bool gpu3d_snapshot(uint8_t **pixels,uint32_t *width,uint32_t *height);
void gpu3d_scanout_disable(void);
bool gpu3d_command(const uint8_t *p,size_t len,uint8_t *out,size_t cap,size_t *n);
bool gpu3d_mmio(uint64_t off,bool wr,uint32_t *val);
#else
static inline bool gpu3d_direct_supported(void) {return false;}
static inline void *gpu3d_display_texture(uint32_t *w,uint32_t *h) {(void)w;(void)h;return NULL;}
static inline bool gpu3d_init(void) { return false; }
static inline void gpu3d_reset(void) {}
static inline void gpu3d_cleanup(void) {}
static inline bool gpu3d_snapshot(uint8_t **pixels,uint32_t *width,uint32_t *height)
{ (void)pixels;(void)width;(void)height;return false; }
static inline void gpu3d_scanout_disable(void) {}
static inline bool gpu3d_resource(uint32_t id) { (void)id; return false; }
static inline bool gpu3d_command(const uint8_t *p,size_t len,uint8_t *out,size_t cap,size_t *n)
{ (void)p;(void)len;(void)out;(void)cap;(void)n;return false; }
static inline bool gpu3d_mmio(uint64_t off,bool wr,uint32_t *val)
{ (void)off;(void)wr;(void)val;return false; }
#endif
#endif
