#include "include/aw_shim.h"

#include "AirwinRegistry.h"
#include "airwin_consolidated_base.h"

#include <cstring>
#include <memory>

struct AWInstance
{
    std::unique_ptr<AirwinConsolidatedBase> fx;
    int paramCount{0};
};

namespace
{
/// Airwindows text accessors write into caller buffers of unspecified size;
/// 256 bytes comfortably covers every name/display string in the suite
/// (upstream's own diagnostic dump uses the same bound).
constexpr int kScratchSize = 256;

void copyTruncated(const char *src, char *buffer, int bufferSize)
{
    if (buffer == nullptr || bufferSize <= 0)
        return;
    std::strncpy(buffer, src, static_cast<size_t>(bufferSize - 1));
    buffer[bufferSize - 1] = '\0';
}

bool indexInRange(int index) { return index >= 0 && index < static_cast<int>(AirwinRegistry::registry.size()); }
} // namespace

int aw_effect_count(void) { return static_cast<int>(AirwinRegistry::registry.size()); }

const char *aw_effect_name(int index)
{
    return indexInRange(index) ? AirwinRegistry::registry[index].name.c_str() : "";
}

const char *aw_effect_category(int index)
{
    return indexInRange(index) ? AirwinRegistry::registry[index].category.c_str() : "";
}

const char *aw_effect_what_text(int index)
{
    return indexInRange(index) ? AirwinRegistry::registry[index].whatText.c_str() : "";
}

int aw_effect_param_count(int index)
{
    return indexInRange(index) ? AirwinRegistry::registry[index].nParams : 0;
}

int aw_effect_index_for_name(const char *name)
{
    if (name == nullptr)
        return -1;
    auto it = AirwinRegistry::nameToIndex.find(name);
    return it == AirwinRegistry::nameToIndex.end() ? -1 : it->second;
}

char *aw_effect_doc_text(int index)
{
    if (!indexInRange(index))
        return strdup("");
    auto text = AirwinRegistry::documentationStringFor(index);
    return strdup(text.c_str());
}

void aw_free_string(char *s) { free(s); }

AWInstance *aw_create(int index, double sampleRate)
{
    if (!indexInRange(index))
        return nullptr;
    const auto &reg = AirwinRegistry::registry[index];
    auto fx = reg.generator();
    if (!fx)
        return nullptr;
    fx->setSampleRate(static_cast<float>(sampleRate));
    auto *instance = new AWInstance();
    instance->fx = std::move(fx);
    instance->paramCount = reg.nParams;
    return instance;
}

void aw_destroy(AWInstance *instance) { delete instance; }

int aw_param_count(const AWInstance *instance) { return instance ? instance->paramCount : 0; }

void aw_param_name(const AWInstance *instance, int paramIndex, char *buffer, int bufferSize)
{
    if (!instance || paramIndex < 0 || paramIndex >= instance->paramCount)
    {
        copyTruncated("", buffer, bufferSize);
        return;
    }
    char scratch[kScratchSize] = {0};
    instance->fx->getParameterName(paramIndex, scratch);
    copyTruncated(scratch, buffer, bufferSize);
}

void aw_param_display(const AWInstance *instance, int paramIndex, char *buffer, int bufferSize)
{
    if (!instance || paramIndex < 0 || paramIndex >= instance->paramCount)
    {
        copyTruncated("", buffer, bufferSize);
        return;
    }
    char scratch[kScratchSize] = {0};
    instance->fx->getParameterDisplay(paramIndex, scratch);
    copyTruncated(scratch, buffer, bufferSize);
}

float aw_get_param(const AWInstance *instance, int paramIndex)
{
    if (!instance || paramIndex < 0 || paramIndex >= instance->paramCount)
        return 0.0f;
    return instance->fx->getParameter(paramIndex);
}

void aw_set_param(AWInstance *instance, int paramIndex, float value)
{
    if (!instance || paramIndex < 0 || paramIndex >= instance->paramCount)
        return;
    instance->fx->setParameter(paramIndex, value);
}

void aw_process(AWInstance *instance, const float *inL, const float *inR, float *outL, float *outR,
                 int frames)
{
    if (!instance || frames <= 0)
        return;
    // AirwinConsolidatedBase::processReplacing takes non-const float**; the
    // effects only read `inputs`, but the VST-era signature predates const.
    float *inputs[2] = {const_cast<float *>(inL), const_cast<float *>(inR)};
    float *outputs[2] = {outL, outR};
    instance->fx->processReplacing(inputs, outputs, frames);
}
