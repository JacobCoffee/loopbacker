#pragma once

#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>

/// Loopback ring indexed by device sample time, shared by every client of one device.
///
/// The HAL hands each client its own IO cycle: WriteMix runs once per writing client and
/// ReadInput once per reading client, each with that client's sample time. So writers mix
/// into the frames at their output sample time, and readers copy the frames at their input
/// sample time without consuming anything. Any number of writers and readers, at any buffer
/// size, see the same continuous signal.
///
/// Each slot packs the sample's float bits with a tag naming which lap of the ring wrote it
/// (`sampleTime >> log2(capacity)`). A writer whose tag differs overwrites the slot, one
/// whose tag matches adds to it; a reader treats a mismatched tag as silence, so a stopped
/// writer leaves silence instead of looping stale audio. Slots are updated by CAS, so writers
/// on different IO threads mix without locks. No allocation after construction.
class RingBuffer {
    static_assert(std::atomic<uint64_t>::is_always_lock_free, "IO path needs lock-free 64-bit atomics");

public:
    /// `capacityFrames` must be a power of two.
    RingBuffer(uint32_t capacityFrames, uint32_t channels)
        : mMask(capacityFrames - 1)
        , mLapShift(static_cast<uint32_t>(__builtin_ctz(capacityFrames)))
        , mChannels(channels)
        , mSlots(new std::atomic<uint64_t>[static_cast<size_t>(capacityFrames) * channels]())
    {
    }

    /// Mixes `frames` interleaved frames into the ring, starting at device sample time
    /// `sampleTime`. Frames before sample time 0 are dropped.
    void mix(int64_t sampleTime, const float* data, uint32_t frames)
    {
        for (uint32_t f = 0; f < frames; ++f) {
            const int64_t t = sampleTime + f;
            if (t < 0) continue;
            const uint32_t tag = lapTag(t);
            std::atomic<uint64_t>* frame = frameSlots(t);
            for (uint32_t c = 0; c < mChannels; ++c) {
                const float sample = data[static_cast<size_t>(f) * mChannels + c];
                uint64_t old = frame[c].load(std::memory_order_relaxed);
                uint64_t next;
                do {
                    const float base = (tagOf(old) == tag) ? floatOf(old) : 0.0f;
                    next = pack(tag, base + sample);
                } while (!frame[c].compare_exchange_weak(old, next, std::memory_order_release,
                                                         std::memory_order_relaxed));
            }
        }
    }

    /// Copies `frames` interleaved frames starting at device sample time `sampleTime` into
    /// `out`, scaled by `gain`. Frames no writer produced for that sample time read as silence.
    void read(int64_t sampleTime, float* out, uint32_t frames, float gain) const
    {
        for (uint32_t f = 0; f < frames; ++f) {
            const int64_t t = sampleTime + f;
            float* dst = out + static_cast<size_t>(f) * mChannels;
            if (t < 0) {
                std::memset(dst, 0, mChannels * sizeof(float));
                continue;
            }
            const uint32_t tag = lapTag(t);
            const std::atomic<uint64_t>* frame = frameSlots(t);
            for (uint32_t c = 0; c < mChannels; ++c) {
                const uint64_t v = frame[c].load(std::memory_order_acquire);
                dst[c] = (tagOf(v) == tag) ? floatOf(v) * gain : 0.0f;
            }
        }
    }

    /// Clears every slot. Only call while no IO is running on the device.
    void reset()
    {
        const size_t count = static_cast<size_t>(mMask + 1) * mChannels;
        for (size_t i = 0; i < count; ++i) mSlots[i].store(0, std::memory_order_relaxed);
    }

private:
    uint32_t lapTag(int64_t t) const { return static_cast<uint32_t>(static_cast<uint64_t>(t) >> mLapShift); }

    std::atomic<uint64_t>* frameSlots(int64_t t) const
    {
        return &mSlots[static_cast<size_t>(static_cast<uint64_t>(t) & mMask) * mChannels];
    }

    static uint64_t pack(uint32_t tag, float value)
    {
        uint32_t bits;
        std::memcpy(&bits, &value, sizeof bits);
        return (static_cast<uint64_t>(tag) << 32) | bits;
    }
    static uint32_t tagOf(uint64_t v) { return static_cast<uint32_t>(v >> 32); }
    static float floatOf(uint64_t v)
    {
        const uint32_t bits = static_cast<uint32_t>(v);
        float value;
        std::memcpy(&value, &bits, sizeof value);
        return value;
    }

    const uint32_t mMask;
    const uint32_t mLapShift;
    const uint32_t mChannels;
    const std::unique_ptr<std::atomic<uint64_t>[]> mSlots;
};
