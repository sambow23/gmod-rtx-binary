#pragma once
#include <d3d9.h>
#include "../../public/include/remix/remix.h"
#include "../../public/include/remix/remix_c.h"
#include <remix/remix_c.h>
#include <vector>
#include <Windows.h>

// Forward declarations
class RTXLightManager {
public:
    struct LightProperties {
        float x, y, z;          // Position
        float size;             // Light radius
        float brightness;       // Light intensity
        float r, g, b;          // Color (0-1 range)
    };

    static RTXLightManager& Instance();

    // Light management functions
    remixapi_LightHandle CreateLight(const LightProperties& props);
    bool UpdateLight(remixapi_LightHandle handle, const LightProperties& props);
    void DestroyLight(remixapi_LightHandle handle);
    void DrawLights();

    // Utility functions
    void Initialize(remix::Interface* remixInterface);
    void Shutdown();
    size_t GetLightCount() const;
    void CleanupInvalidLights();

private:
    RTXLightManager();
    ~RTXLightManager();

    struct ManagedLight {
        remixapi_LightHandle handle;
        LightProperties properties;
        float lastUpdateTime;
        bool needsUpdate;
    };

    remix::Interface* m_remix;
    std::vector<ManagedLight> m_lights;
    CRITICAL_SECTION m_lightCS;
    bool m_initialized;

    // Helper functions
    remixapi_LightInfoSphereEXT CreateSphereLight(const LightProperties& props);
    remixapi_LightInfo CreateLightInfo(const remixapi_LightInfoSphereEXT& sphereLight);
    uint64_t GenerateLightHash() const;
    void LogMessage(const char* format, ...);
};