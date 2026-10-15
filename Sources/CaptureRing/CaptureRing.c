#include "CaptureRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>
struct HNRing {
    float *samples;
    uint32_t capacity;
    _Atomic uint64_t writeIndex, readIndex, dropped, received;
};
HNRing *hn_ring_create(uint32_t capacity) {
    if (!capacity) return NULL;
    HNRing *r = calloc(1, sizeof(HNRing));
    if (!r) return NULL;
    r->samples = calloc(capacity, sizeof(float));
    if (!r->samples) { free(r); return NULL; }
    r->capacity = capacity;
    return r;
}
void hn_ring_destroy(HNRing *r) { if (r) { free(r->samples); free(r); } }
void hn_ring_push(HNRing *r, const AudioBufferList *abl, uint32_t frames) {
    if (!r || !abl || !abl->mNumberBuffers) return;
    uint64_t w = atomic_load_explicit(&r->writeIndex, memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&r->readIndex, memory_order_acquire);
    atomic_fetch_add_explicit(&r->received, frames, memory_order_relaxed);
    uint32_t accepted = (uint32_t)fmin(frames, r->capacity - (w-rd));
    for (uint32_t f = 0; f < accepted; f++) {
        float sum = 0; uint32_t channels = 0;
        for (uint32_t b=0; b<abl->mNumberBuffers; b++) {
            const AudioBuffer *buffer = &abl->mBuffers[b];
            uint32_t count = buffer->mNumberChannels;
            if (!buffer->mData || (uint64_t)(f+1)*count*sizeof(float) > buffer->mDataByteSize) continue;
            const float *data = buffer->mData;
            for (uint32_t c=0; c<count; c++) sum += data[f*count+c];
            channels += count;
        }
        float value = channels ? sum/channels : 0;
        r->samples[(w+f)%r->capacity] = isfinite(value) ? value : 0;
    }
    atomic_store_explicit(&r->writeIndex, w+accepted, memory_order_release);
    atomic_fetch_add_explicit(&r->dropped, frames-accepted, memory_order_relaxed);
}
uint32_t hn_ring_read(HNRing *r, float *out, uint32_t count) {
    uint64_t rd = atomic_load_explicit(&r->readIndex, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->writeIndex, memory_order_acquire);
    uint32_t n = (uint32_t)fmin(count, w-rd);
    for (uint32_t i=0; i<n; i++) out[i] = r->samples[(rd+i)%r->capacity];
    atomic_store_explicit(&r->readIndex, rd+n, memory_order_release);
    return n;
}
uint64_t hn_ring_dropped(HNRing *r) { return atomic_load(&r->dropped); }
uint64_t hn_ring_received(HNRing *r) { return atomic_load(&r->received); }
