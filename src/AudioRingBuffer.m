// AudioRingBuffer.m
// Thread-safe circular buffer for audio data

#include "AudioRingBuffer.h"
#include <string.h>

void audio_ring_buffer_init(AudioRingBuffer* rb) {
    rb->read_pos = 0;
    rb->write_pos = 0;
    pthread_mutex_init(&rb->mutex, NULL);
}

void audio_ring_buffer_destroy(AudioRingBuffer* rb) {
    pthread_mutex_destroy(&rb->mutex);
}

size_t audio_ring_buffer_available(AudioRingBuffer* rb) {
    size_t w = rb->write_pos;
    size_t r = rb->read_pos;
    if (w >= r) return w - r;
    return AUDIO_BUFFER_SIZE - r + w;
}

size_t audio_ring_buffer_free(AudioRingBuffer* rb) {
    return AUDIO_BUFFER_SIZE - audio_ring_buffer_available(rb) - 1;
}

void audio_ring_buffer_write(AudioRingBuffer* rb, const uint8_t* data, size_t len) {
    pthread_mutex_lock(&rb->mutex);
    size_t free_space = audio_ring_buffer_free(rb);
    if (len > free_space) len = free_space;

    size_t w = rb->write_pos;
    size_t first_chunk = AUDIO_BUFFER_SIZE - w;
    if (first_chunk > len) first_chunk = len;

    memcpy(rb->buffer + w, data, first_chunk);
    if (len > first_chunk) {
        memcpy(rb->buffer, data + first_chunk, len - first_chunk);
    }
    rb->write_pos = (w + len) % AUDIO_BUFFER_SIZE;
    pthread_mutex_unlock(&rb->mutex);
}

size_t audio_ring_buffer_read(AudioRingBuffer* rb, uint8_t* data, size_t len) {
    pthread_mutex_lock(&rb->mutex);
    size_t available = audio_ring_buffer_available(rb);
    if (len > available) len = available;

    size_t r = rb->read_pos;
    size_t first_chunk = AUDIO_BUFFER_SIZE - r;
    if (first_chunk > len) first_chunk = len;

    memcpy(data, rb->buffer + r, first_chunk);
    if (len > first_chunk) {
        memcpy(data + first_chunk, rb->buffer, len - first_chunk);
    }
    rb->read_pos = (r + len) % AUDIO_BUFFER_SIZE;
    pthread_mutex_unlock(&rb->mutex);
    return len;
}

void audio_ring_buffer_clear(AudioRingBuffer* rb) {
    pthread_mutex_lock(&rb->mutex);
    rb->read_pos = 0;
    rb->write_pos = 0;
    pthread_mutex_unlock(&rb->mutex);
}
