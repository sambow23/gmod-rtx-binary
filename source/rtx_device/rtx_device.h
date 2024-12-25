#pragma once
#include <d3d9.h>
#include "../public/include/remix/remix.h"
#include "../public/include/remix/remix_c.h"
#include <memory>
#include <vector>
#include <mutex>
#include <chrono>

class RTXDeviceManager {
public:
    static RTXDeviceManager& Instance();
    
    bool Initialize(IDirect3DDevice9Ex* sourceDevice);
    bool HandleDeviceLost();
    IDirect3DDevice9Ex* GetDevice() const { return m_sourceDevice; }
    bool IsInitialized() const { return m_isInitialized; }
    void Shutdown();
    
    // Resource management
    bool AddResource(remixapi_LightHandle handle);
    void RemoveResource(remixapi_LightHandle handle);
    void CleanupResources();
    size_t GetResourceCount() const;

    // Performance monitoring
    float GetAverageUpdateTime() const;
    void UpdatePerformanceMetrics(float updateTime);

    // Debug utilities
    void DumpDeviceStatus();
    void LogResourceUsage();
    static void LogMessage(const char* format, ...);  // Make static

    // Direct access to Remix interface
    remix::Interface* GetRemix() const { return m_remix; }

private:
    RTXDeviceManager() = default;
    ~RTXDeviceManager();

    bool InitializeRemix();
    void ShutdownRemix();

    IDirect3DDevice9Ex* m_sourceDevice = nullptr;
    remix::Interface* m_remix = nullptr;
    bool m_isInitialized = false;
    HMODULE m_remixModule = nullptr;

    struct RTXResource {
        remixapi_LightHandle handle;
        float lastUpdateTime;
        float creationTime;
        size_t updateCount;
        bool needsUpdate;
    };

    struct PerformanceMetrics {
        std::vector<float> updateTimes;
        float averageUpdateTime = 0.0f;
        size_t maxSamples = 100;
        std::chrono::high_resolution_clock::time_point lastUpdate;
    };

    std::vector<RTXResource> m_resources;
    mutable std::mutex m_resourceMutex;
    PerformanceMetrics m_metrics;

    static constexpr size_t MAX_RESOURCES = 1000;
    static constexpr float RESOURCE_TIMEOUT = 5.0f;
    static constexpr size_t UPDATE_BATCH_SIZE = 10;
};