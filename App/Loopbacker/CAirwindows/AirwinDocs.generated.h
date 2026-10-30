// Declares the lookup implemented by the generated AirwinDocs.generated.cpp
// (see Scripts/generate_airwin_docs.py). Internal to this target; not part of
// the public C shim.
#ifndef AIRWINCONSOLIDATED_AIRWINDOCS_GENERATED_H
#define AIRWINCONSOLIDATED_AIRWINDOCS_GENERATED_H

#include <string>

/// Returns the long-form documentation text for an Airwindows effect name
/// (registry name, e.g. "Pressure5"), or an empty string if none is embedded.
std::string airwinDocTextFor(const std::string &name);

#endif
