#ifndef MEETING_REALTIME_AUDIO_H
#define MEETING_REALTIME_AUDIO_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

// Single producer (HAL), single consumer (writer queue). All storage is allocated
// before AudioDeviceStart. The producer never waits, allocates, or performs I/O.
typedef struct MIRing MIRing;
typedef struct {
    uint64_t hostTime;
    uint32_t bufferCount;
    uint32_t byteSizes[2];
    uint32_t channels[2];
    const void * _Nullable data[2];
} MIPacket;
MIRing * _Nullable MIRingCreate(uint32_t capacity, uint32_t maxBytesPerBuffer);
void MIRingDestroy(MIRing * _Nullable ring);
// Set UINT64_MAX before starting hardware to discard warm-up callbacks. Once all
// devices are ready, publish the shared host-time epoch. Never resets queued data.
void MIRingSetStartTime(MIRing * _Nonnull ring, uint64_t hostTime);
bool MIRingPush(MIRing * _Nonnull ring, const AudioBufferList * _Nonnull audio, uint64_t hostTime);
bool MIRingPeek(MIRing * _Nonnull ring, MIPacket * _Nonnull packet);
void MIRingPop(MIRing * _Nonnull ring);
uint64_t MIRingDropped(MIRing * _Nonnull ring);
OSStatus MIAudioIOProc(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                      const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                      AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
#endif
