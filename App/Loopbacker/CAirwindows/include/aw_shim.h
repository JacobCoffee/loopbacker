// C ABI over AirwinRegistry/AirwinConsolidatedBase so Swift can host any of
// the vendored Airwindows effects without seeing C++. Every call here except
// aw_process and aw_get_param/aw_set_param is expected off the audio IO
// thread (scanning the registry, building parameter specs, (de)serializing
// state). aw_process, aw_get_param and aw_set_param are IO-thread safe: they
// touch only the already-constructed C++ object's plain-old-data members and
// never allocate.
#ifndef AIRWINCONSOLIDATED_AW_SHIM_H
#define AIRWINCONSOLIDATED_AW_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/// Number of effects in the registry. Stable for the process's lifetime.
int aw_effect_count(void);

/// Registry name, e.g. "Pressure5". Identifies the effect across relaunches.
const char *aw_effect_name(int index);
/// Browser grouping, e.g. "Dynamics".
const char *aw_effect_category(int index);
/// One or two sentence summary.
const char *aw_effect_what_text(int index);
/// Parameter count for the effect at `index`, without constructing it.
int aw_effect_param_count(int index);
/// Index of `name` in the registry, or -1 if not found.
int aw_effect_index_for_name(const char *name);

/// Long-form documentation text, or an empty string if none is embedded.
/// Caller must free the returned pointer with aw_free_string.
char *aw_effect_doc_text(int index);
void aw_free_string(char *s);

typedef struct AWInstance AWInstance;

/// Constructs effect `index` at `sampleRate`. Returns NULL for an invalid
/// index. Allocates; call off the IO thread.
AWInstance *aw_create(int index, double sampleRate);
/// Destroys an instance. Deallocates; call off the IO thread.
void aw_destroy(AWInstance *instance);

int aw_param_count(const AWInstance *instance);
/// Copies the parameter's name into `buffer` (NUL-terminated, truncated to
/// fit `bufferSize`).
void aw_param_name(const AWInstance *instance, int paramIndex, char *buffer, int bufferSize);
/// Copies the display text for the parameter's *current* value into `buffer`.
void aw_param_display(const AWInstance *instance, int paramIndex, char *buffer, int bufferSize);
/// 0...1 normalized, as Airwindows parameters always are. IO-thread safe.
float aw_get_param(const AWInstance *instance, int paramIndex);
/// IO-thread safe.
void aw_set_param(AWInstance *instance, int paramIndex, float value);

/// Processes `frames` (<= 4096) of planar stereo float audio. `in`/`out`
/// pointers must not alias. IO-thread safe: no allocation.
void aw_process(AWInstance *instance, const float *inL, const float *inR, float *outL,
                 float *outR, int frames);

#ifdef __cplusplus
}
#endif

#endif
