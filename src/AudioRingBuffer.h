// AudioRingBuffer.h
// Thread-safe circular buffer for audio data

#ifndef AUDIO_RING_BUFFER_H
#define AUDIO_RING_BUFFER_H

#include <stdint.h>
#include <stddef.h>
#include <pthread.h>

#define AUDIO_BUFFER_SIZE (48000 * 2 * 4 * 2)  // ~2 seconds at 48kHz stereo float

typedef struct {
    uint8_t buffer[AUDIO_BUFFER_SIZE];
    volatile size_t read_pos;
    volatile size_t write_pos;
    pthread_mutex_t mutex;
} AudioRingBuffer;

void audio_ring_buffer_init(AudioRingBuffer* rb);
void audio_ring_buffer_destroy(AudioRingBuffer* rb);
size_t audio_ring_buffer_available(AudioRingBuffer* rb);
size_t audio_ring_buffer_free(AudioRingBuffer* rb);
void audio_ring_buffer_write(AudioRingBuffer* rb, const uint8_t* data, size_t len);
size_t audio_ring_buffer_read(AudioRingBuffer* rb, uint8_t* data, size_t len);
void audio_ring_buffer_clear(AudioRingBuffer* rb);

#endif // AUDIO_RING_BUFFER_H
