// Interposes malloc/calloc/realloc/free/posix_memalign/malloc_zone_malloc to count heap
// allocations on any thread while counting is enabled. Used by model-bench.swift to verify
// the BNNS Graph execute path makes zero heap allocations once warmed up.
//
// Built into a dylib and inserted via DYLD_INSERT_LIBRARIES (see model-bench.sh).
#include <malloc/malloc.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <stdbool.h>

static _Atomic long count;
static _Atomic bool enabled;

void lb_count_enable(bool on) { atomic_store(&enabled, on); }
long lb_count_get(void) { return atomic_load(&count); }

static void *my_malloc(size_t n) { if (atomic_load(&enabled)) atomic_fetch_add(&count, 1); return malloc(n); }
static void *my_calloc(size_t a, size_t b) { if (atomic_load(&enabled)) atomic_fetch_add(&count, 1); return calloc(a, b); }
static void *my_realloc(void *p, size_t n) { if (atomic_load(&enabled)) atomic_fetch_add(&count, 1); return realloc(p, n); }
static void my_free(void *p) { if (p && atomic_load(&enabled)) atomic_fetch_add(&count, 1); free(p); }
static int my_posix_memalign(void **p, size_t a, size_t n) { if (atomic_load(&enabled)) atomic_fetch_add(&count, 1); return posix_memalign(p, a, n); }
static void *my_zone_malloc(malloc_zone_t *z, size_t n) { if (atomic_load(&enabled)) atomic_fetch_add(&count, 1); return malloc_zone_malloc(z, n); }

#define I(r, o) __attribute__((used)) static struct { const void *a, *b; } _i_##o \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)r, (const void *)o };
I(my_malloc, malloc) I(my_calloc, calloc) I(my_realloc, realloc) I(my_free, free)
I(my_posix_memalign, posix_memalign) I(my_zone_malloc, malloc_zone_malloc)
