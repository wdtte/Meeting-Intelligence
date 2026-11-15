#include "RealtimeAudio.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint64_t hostTime;
    uint32_t count, sizes[2], channels[2];
} MISlot;
struct MIRing {
    uint32_t capacity, maxBytes;
    _Atomic uint64_t writeIndex, readIndex, dropped, startTime;
    MISlot *slots;
    unsigned char *storage;
};
MIRing *MIRingCreate(uint32_t capacity, uint32_t maxBytes) {
    if (capacity < 2 || capacity > 1024 || !maxBytes || maxBytes > 1048576) return NULL;
    MIRing *ring = calloc(1, sizeof(MIRing));
    if (!ring) return NULL;
    ring->capacity = capacity; ring->maxBytes = maxBytes;
    atomic_init(&ring->writeIndex, 0); atomic_init(&ring->readIndex, 0); atomic_init(&ring->dropped, 0);
    atomic_init(&ring->startTime, 0);
    if (!atomic_is_lock_free(&ring->writeIndex) || !atomic_is_lock_free(&ring->readIndex) || !atomic_is_lock_free(&ring->dropped) || !atomic_is_lock_free(&ring->startTime)) {
        free(ring); return NULL;
    }
    ring->slots = calloc(capacity, sizeof(MISlot));
    ring->storage = calloc((size_t)capacity * 2, maxBytes);
    if (!ring->slots || !ring->storage) { MIRingDestroy(ring); return NULL; }
    // Touch each page on the setup thread rather than faulting it in the HAL callback.
    volatile unsigned char *pages = ring->storage;
    size_t bytes = (size_t)capacity * 2 * maxBytes;
    for (size_t i = 0; i < bytes; i += 4096) pages[i] = 0;
    return ring;
}
void MIRingDestroy(MIRing *ring) {
    if (!ring) return;
    free(ring->slots); free(ring->storage); free(ring);
}
void MIRingSetStartTime(MIRing *ring, uint64_t hostTime) {
    atomic_store_explicit(&ring->startTime, hostTime, memory_order_release);
}
bool MIRingPush(MIRing *ring, const AudioBufferList *audio, uint64_t hostTime) {
    uint64_t start = atomic_load_explicit(&ring->startTime, memory_order_acquire);
    if (start == UINT64_MAX || (hostTime && hostTime < start)) return true;
    uint64_t write = atomic_load_explicit(&ring->writeIndex, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&ring->readIndex, memory_order_acquire);
    if (!audio || audio->mNumberBuffers == 0) return true;
    if (audio->mNumberBuffers > 2 || write - read >= ring->capacity || !hostTime) goto drop;
    for (uint32_t i = 0; i < audio->mNumberBuffers; i++) {
        if (audio->mBuffers[i].mDataByteSize > ring->maxBytes ||
            (audio->mBuffers[i].mDataByteSize && !audio->mBuffers[i].mData)) goto drop;
    }
    uint32_t index = (uint32_t)(write % ring->capacity);
    MISlot *slot = &ring->slots[index];
    slot->hostTime = hostTime; slot->count = audio->mNumberBuffers;
    for (uint32_t i = 0; i < slot->count; i++) {
        slot->sizes[i] = audio->mBuffers[i].mDataByteSize;
        slot->channels[i] = audio->mBuffers[i].mNumberChannels;
        if (slot->sizes[i]) memcpy(ring->storage + ((size_t)index * 2 + i) * ring->maxBytes,
                                  audio->mBuffers[i].mData, slot->sizes[i]);
    }
    atomic_store_explicit(&ring->writeIndex, write + 1, memory_order_release);
    return true;
drop:
    atomic_fetch_add_explicit(&ring->dropped, 1, memory_order_relaxed);
    return false;
}
bool MIRingPeek(MIRing *ring, MIPacket *packet) {
    uint64_t read = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    if (read == atomic_load_explicit(&ring->writeIndex, memory_order_acquire)) return false;
    uint32_t index = (uint32_t)(read % ring->capacity);
    MISlot *slot = &ring->slots[index];
    packet->hostTime = slot->hostTime; packet->bufferCount = slot->count;
    for (uint32_t i = 0; i < slot->count; i++) {
        packet->byteSizes[i] = slot->sizes[i]; packet->channels[i] = slot->channels[i];
        packet->data[i] = ring->storage + ((size_t)index * 2 + i) * ring->maxBytes;
    }
    return true;
}
void MIRingPop(MIRing *ring) {
    uint64_t read = atomic_load_explicit(&ring->readIndex, memory_order_relaxed);
    atomic_store_explicit(&ring->readIndex, read + 1, memory_order_release);
}
uint64_t MIRingDropped(MIRing *ring) { return atomic_load_explicit(&ring->dropped, memory_order_relaxed); }
OSStatus MIAudioIOProc(AudioObjectID device, const AudioTimeStamp *now,
                      const AudioBufferList *input, const AudioTimeStamp *inputTime,
                      AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)device; (void)now; (void)output; (void)outputTime;
    uint64_t hostTime = inputTime && (inputTime->mFlags & kAudioTimeStampHostTimeValid) ? inputTime->mHostTime : 0;
    MIRingPush(context, input, hostTime);
    return noErr;
}
#include <libproc.h>
int MIProcessPath(int pid, void *buffer, uint32_t size) { return proc_pidpath(pid, buffer, size); }
