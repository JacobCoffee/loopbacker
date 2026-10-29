// Bridging header for count.c, imported into model-bench.swift via -import-objc-header.
#include <stdbool.h>
void lb_count_enable(bool on);
long lb_count_get(void);
