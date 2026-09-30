/* Host oracle adapter. Encoding itself is unmodified venus-protocol output. */
#ifndef VN_CS_H
#define VN_CS_H
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>
typedef uint64_t vn_object_id;
struct vn_cs_encoder { uint8_t data[65536]; size_t pos; };
struct vn_cs_decoder { const uint8_t *data; size_t pos, size; };
static inline bool vn_cs_renderer_protocol_has_api_version(uint32_t v) { (void)v; return true; }
static inline bool vn_cs_renderer_protocol_has_extension(uint32_t v) { (void)v; return true; }
static inline size_t vn_cs_encoder_get_len(const struct vn_cs_encoder *e) { return e->pos; }
static inline bool vn_cs_encoder_reserve(struct vn_cs_encoder *e, size_t n) { return n <= sizeof(e->data)-e->pos; }
static inline void vn_cs_encoder_write(struct vn_cs_encoder *e, size_t n, const void *p, size_t size) {
    assert(size <= n && n <= sizeof(e->data)-e->pos);
    memset(e->data+e->pos, 0, n); memcpy(e->data+e->pos, p, size); e->pos+=n;
}
static inline void vn_cs_decoder_set_fatal(struct vn_cs_decoder *d) { (void)d; abort(); }
static inline void vn_cs_decoder_read(struct vn_cs_decoder *d, size_t n, void *p, size_t size) {
    assert(size <= n && n <= d->size-d->pos); memcpy(p,d->data+d->pos,size); d->pos+=n;
}
static inline void vn_cs_decoder_peek(struct vn_cs_decoder *d, size_t n, void *p, size_t size) {
    assert(size <= n && n <= d->size-d->pos); memcpy(p,d->data+d->pos,size);
}
/* Treat every test handle as the guest id; no Mesa dispatch pointer wrappers. */
static inline vn_object_id vn_cs_handle_load_id(const void **p, VkObjectType t) {
    uint64_t id; (void)t; memcpy(&id,p,8); return id;
}
static inline void vn_cs_handle_store_id(void **p, vn_object_id id, VkObjectType t) { (void)t; memcpy(p,&id,8); }
#endif
