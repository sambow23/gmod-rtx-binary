#pragma once
#include <d3d9.h>
#include "../../public/include/remix/remix.h"
#include "../../public/include/remix/remix_c.h"
#include <remix/remix_c.h>
#include <vector>
#include <queue>
#include <Windows.h>

class RTXLightManager {
public:
    struct LightProperties {
        float x, y, z;          
        float size;             
        float brightness;       
        float r, g, b;          
    };

    struct PendingUpdate {
        remixapi_LightHandle handle;
        LightProperties properties;
        bool needsUpdate;
    };

    struct ManagedLight {
        remixapi_LightHandle handle;
        LightProperties properties;
        float lastUpdateTime;
        bool needsUpdate;
    };

    static RTXLightManager& Instance();

    // Light management functions
    remixapi_LightHandle CreateLight(const LightProperties& props);
    bool UpdateLight(remixapi_LightHandle handle, const LightProperties& props);
    void DestroyLight(remixapi_LightHandle handle);
    void DrawLights();

    // Frame synchronization
    void BeginFrame();
    void EndFrame();
    void ProcessPendingUpdates();
    
    // Utility functions
    void Initialize(remix::Interface* remixInterface);
    void Shutdown();
    void CleanupInvalidLights();

private:
    RTXLightManager();
    ~RTXLightManager();

    // Internal helper functions
    remixapi_LightInfoSphereEXT CreateSphereLight(const LightProperties& props);
    remixapi_LightInfo CreateLightInfo(const remixapi_LightInfoSphereEXT& sphereLight);
    uint64_t GenerateLightHash() const;
    void LogMessage(const char* format, ...);

    // Member variables
    remix::Interface* m_remix;
    std::vector<ManagedLight> m_lights;
    std::queue<PendingUpdate> m_pendingUpdates;
    CRITICAL_SECTION m_lightCS;
    CRITICAL_SECTION m_updateCS;
    bool m_initialized;
    bool m_isFrameActive;

    // Delete copy constructor and assignment operator
    RTXLightManager(const RTXLightManager&) = delete;
    RTXLightManager& operator=(const RTXLightManager&) = delete;
};