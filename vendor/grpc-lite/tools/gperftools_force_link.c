#include <stddef.h>

extern int ProfilerStart(const char *path);
extern void HeapProfilerStart(const char *prefix);
extern void *tc_malloc(size_t size);

char *strdup(const char *source) {
    size_t length = 0;
    while (source[length] != '\0') length++;

    char *copy = tc_malloc(length + 1);
    if (copy == NULL) return NULL;
    for (size_t i = 0; i <= length; i++) copy[i] = source[i];
    return copy;
}

__attribute__((used, retain)) static const void *grpc_lite_gperftools_symbols[] = {
    (const void *)&ProfilerStart,
    (const void *)&HeapProfilerStart,
};
