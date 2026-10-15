#pragma once
#include <stdint.h>
#include <stddef.h>
#include <CoreAudio/CoreAudioTypes.h>
typedef struct HNRing HNRing;
HNRing *hn_ring_create(uint32_t capacity);
void hn_ring_destroy(HNRing *ring);
// One producer and one consumer per ring. Float32 audio, downmixed to mono.
void hn_ring_push(HNRing *ring, const AudioBufferList *buffers, uint32_t frames);
uint32_t hn_ring_read(HNRing *ring, float *destination, uint32_t capacity);
uint64_t hn_ring_dropped(HNRing *ring);
uint64_t hn_ring_received(HNRing *ring);
