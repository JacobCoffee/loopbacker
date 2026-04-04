#pragma once

#include <atomic>
#include <cstdint>
#include <cstring>
#include <vector>

/// Lock-free single-producer single-consumer ring buffer for audio frames.
/// Size must be a power of two for efficient bitwise masking.
class RingBuffer {
public:
    explicit RingBuffer(uint32_t capacityFrames, uint32_t bytesPerFrame)
        : mMask(capacityFrames - 1)
        , mBytesPerFrame(bytesPerFrame)
        , mBuffer(static_cast<size_t>(capacityFrames) * bytesPerFrame, 0.0f)
        , mWritePos(0)
        , mReadPos(0)
    {
        // capacityFrames must be power of 2
    }

    /// Write frames into the ring buffer. Returns number of frames actually written.
    uint32_t write(const float* data, uint32_t frames)
    {
        uint32_t wr = mWritePos.load(std::memory_order_relaxed);
        uint32_t rd = mReadPos.load(std::memory_order_acquire);

        uint32_t available = capacity() - (wr - rd);
        uint32_t toWrite = (frames < available) ? frames : available;
        if (toWrite == 0) return 0;

        const uint32_t samplesPerFrame = mBytesPerFrame / sizeof(float);
        uint32_t startIdx = wr & mMask;
        uint32_t firstChunk = capacity() - startIdx;
        if (firstChunk > toWrite) firstChunk = toWrite;
        uint32_t secondChunk = toWrite - firstChunk;

        std::memcpy(&mBuffer[startIdx * samplesPerFrame],
                    data,
                    firstChunk * mBytesPerFrame);
        if (secondChunk > 0) {
            std::memcpy(&mBuffer[0],
                        &data[firstChunk * samplesPerFrame],
                        secondChunk * mBytesPerFrame);
        }

        mWritePos.store(wr + toWrite, std::memory_order_release);
        return toWrite;
    }

    /// Read frames from the ring buffer. Returns number of frames actually read.
    uint32_t read(float* data, uint32_t frames)
    {
        uint32_t rd = mReadPos.load(std::memory_order_relaxed);
        uint32_t wr = mWritePos.load(std::memory_order_acquire);

        uint32_t available = wr - rd;
        uint32_t toRead = (frames < available) ? frames : available;
        if (toRead == 0) return 0;

        const uint32_t samplesPerFrame = mBytesPerFrame / sizeof(float);
        uint32_t startIdx = rd & mMask;
        uint32_t firstChunk = capacity() - startIdx;
        if (firstChunk > toRead) firstChunk = toRead;
        uint32_t secondChunk = toRead - firstChunk;

        std::memcpy(data,
                    &mBuffer[startIdx * samplesPerFrame],
                    firstChunk * mBytesPerFrame);
        if (secondChunk > 0) {
            std::memcpy(&data[firstChunk * samplesPerFrame],
                        &mBuffer[0],
                        secondChunk * mBytesPerFrame);
        }

        mReadPos.store(rd + toRead, std::memory_order_release);
        return toRead;
    }

    uint32_t capacity() const { return mMask + 1; }

    void reset()
    {
        mWritePos.store(0, std::memory_order_relaxed);
        mReadPos.store(0, std::memory_order_relaxed);
    }

private:
    const uint32_t mMask;
    const uint32_t mBytesPerFrame;
    std::vector<float> mBuffer;
    std::atomic<uint32_t> mWritePos;
    std::atomic<uint32_t> mReadPos;
};
