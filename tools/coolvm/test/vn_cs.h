/* Minimal bounded client stream for the host transport test, using upstream codecs. */
#ifndef COOLVM_VN_CS_H
#define COOLVM_VN_CS_H
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
struct vn_cs_encoder { uint8_t data[65536]; size_t len; };
struct vn_cs_decoder { const uint8_t *data; size_t len, pos; };
static inline void vn_cs_encoder_write(struct vn_cs_encoder *e, size_t n, const void *p, size_t pn)
{ assert(pn<=n && n<=sizeof(e->data)-e->len); memset(e->data+e->len,0,n); memcpy(e->data+e->len,p,pn); e->len+=n; }
static inline void vn_cs_decoder_read(struct vn_cs_decoder *d,size_t n,void *p,size_t pn)
{ assert(pn<=n && n<=d->len-d->pos); memcpy(p,d->data+d->pos,pn); d->pos+=n; }
static inline void vn_cs_decoder_peek(struct vn_cs_decoder *d,size_t n,void *p,size_t pn)
{ size_t pos=d->pos; vn_cs_decoder_read(d,n,p,pn); d->pos=pos; }
static inline void vn_cs_decoder_set_fatal(struct vn_cs_decoder *d) { (void)d; assert(0); }
static inline uint64_t vn_cs_handle_load_id(const void **p,int type)
{ (void)type; return (uintptr_t)*p; }
static inline void vn_cs_handle_store_id(void **p,uint64_t id,int type)
{ (void)type; *p=(void *)(uintptr_t)id; }
/* Spike uses only core 1.1 structs; no extension chains. */
static inline bool vn_cs_renderer_protocol_has_extension(uint32_t ext) { (void)ext; return false; }
static inline bool vn_cs_renderer_protocol_has_api_version(uint32_t ver) { (void)ver; return false; }
#endif
