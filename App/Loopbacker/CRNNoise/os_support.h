/* Not part of upstream xiph/rnnoise. rnnoise's vec_neon.h and the generic path in vec.h
 * include "os_support.h" expecting libopus's memory-helper header, but only use the
 * OPUS_CLEAR macro from it. Rather than vendor libopus, this is a minimal drop-in that
 * supplies just that macro, mirroring libopus's definition. See README.md.
 */
#ifndef OS_SUPPORT_H
#define OS_SUPPORT_H

#include <string.h>

#define OPUS_CLEAR(dst, n) (memset((dst), 0, (n) * sizeof(*(dst))))

#endif
