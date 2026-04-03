#include "LoopbackerDriver.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreAudio/AudioServerPlugIn.h>

/// The CFPlugIn factory function. Called by coreaudiod when loading the driver bundle.
/// The UUID must match the factory UUID in Info.plist.
extern "C" void* Loopbacker_Create(CFAllocatorRef /*allocator*/, CFUUIDRef requestedTypeUUID)
{
    // Verify this is the AudioServerPlugIn type UUID
    CFUUIDRef audioPlugInTypeUUID = CFUUIDGetConstantUUIDWithBytes(
        nullptr,
        0x44, 0x3A, 0xBA, 0xB8,
        0xE7, 0xB3,
        0x49, 0x1A,
        0xB9, 0x85,
        0xBE, 0xB9, 0x18, 0x70, 0x30, 0xDB);

    if (!CFEqual(requestedTypeUUID, audioPlugInTypeUUID)) {
        return nullptr;
    }

    // Return the singleton driver instance (AddRef already called in constructor)
    LoopbackerDriver* driver = LoopbackerDriver_GetInstance();
    return driver;
}
