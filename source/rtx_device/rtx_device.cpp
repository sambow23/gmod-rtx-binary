#include "rtx_device.h"
#include <tier0/dbg.h>
#include <stdarg.h>
#include <algorithm>
#include "e_utils.h"

RTXDeviceManager& RTXDeviceManager::Instance() {
    static RTXDeviceManager instance;
    return instance;
}

RTXDeviceManager::~RTXDeviceManager() {
    Shutdown();
}

void RTXDeviceManager::LogMessage(const char* format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    Msg("[RTX Device] %s", buffer);
}

bool RTXDeviceManager::InitializeRemix() {
    // Try to load Remix DLL
    if (auto interf = remix::lib::loadRemixDllAndInitialize(L"d3d9.dll")) {
        m_remix = new remix::Interface{ *interf };
        
        // Get the window from the source device
        D3DDEVICE_CREATION_PARAMETERS params;
        if (FAILED(m_sourceDevice->GetCreationParameters(&params))) {
            LogMessage("Failed to get device creation parameters\n");
            return false;
        }

        // Initialize Remix with the window
        remixapi_StartupInfo startInfo;
        startInfo.sType = REMIXAPI_STRUCT_TYPE_STARTUP_INFO;
        startInfo.pNext = nullptr;
        startInfo.hwnd = params.hFocusWindow;
        startInfo.disableSrgbConversionForOutput = false;
        startInfo.forceNoVkSwapchain = false;
        startInfo.editorModeEnabled = false;

        if (m_remix->Startup(startInfo) != REMIXAPI_ERROR_CODE_SUCCESS) {
            LogMessage("Failed to start Remix\n");
            return false;
        }

        // Configure Remix settings
        m_remix->SetConfigVariable("rtx.enableAdvancedMode", "1");
        m_remix->SetConfigVariable("rtx.fallbackLightMode", "2");

        LogMessage("Remix initialized successfully\n");
        return true;
    }

    LogMessage("Failed to load Remix DLL\n");
    return false;
}

void RTXDeviceManager::ShutdownRemix() {
    if (m_remix) {
        remix::lib::shutdownAndUnloadRemixDll(*m_remix);
        delete m_remix;
        m_remix = nullptr;
    }
}

bool RTXDeviceManager::Initialize(IDirect3DDevice9Ex* sourceDevice) {
    std::lock_guard<std::mutex> lock(m_resourceMutex);
    
    if (m_isInitialized) return true;
    
    if (!sourceDevice) {
        LogMessage("Invalid source device\n");
        return false;
    }

    m_sourceDevice = sourceDevice;

    // Initialize Remix
    if (!InitializeRemix()) {
        return false;
    }

    // Reserve space for resources
    m_resources.reserve(MAX_RESOURCES);

    // Initialize performance metrics
    m_metrics.lastUpdate = std::chrono::high_resolution_clock::now();
    m_metrics.updateTimes.reserve(m_metrics.maxSamples);

    m_isInitialized = true;
    LogMessage("Device initialized successfully\n");
    return true;
}

bool RTXDeviceManager::HandleDeviceLost() {
    if (!m_isInitialized || !m_sourceDevice) return false;

    HRESULT hr = m_sourceDevice->TestCooperativeLevel();
    if (FAILED(hr)) {
        LogMessage("Source device is in a bad state: 0x%lx\n", hr);
        return false;
    }

    return true;
}

void RTXDeviceManager::Shutdown() {
    std::lock_guard<std::mutex> lock(m_resourceMutex);

    // Clean up all resources
    for (const auto& resource : m_resources) {
        if (m_remix) {
            m_remix->DestroyLight(resource.handle);
        }
    }
    m_resources.clear();

    // Shutdown Remix
    ShutdownRemix();

    m_sourceDevice = nullptr;
    m_isInitialized = false;
    LogMessage("Device shutdown complete\n");
}

bool RTXDeviceManager::AddResource(remixapi_LightHandle handle) {
    std::lock_guard<std::mutex> lock(m_resourceMutex);
    
    if (m_resources.size() >= MAX_RESOURCES) {
        LogMessage("Maximum resource limit reached (%zu)\n", MAX_RESOURCES);
        return false;
    }

    float currentTime = GetCurrentTime();
    m_resources.push_back({
        handle,
        currentTime,
        currentTime,
        0,
        true
    });
    
    return true;
}

void RTXDeviceManager::RemoveResource(remixapi_LightHandle handle) {
    std::lock_guard<std::mutex> lock(m_resourceMutex);
    
    auto it = std::find_if(m_resources.begin(), m_resources.end(),
        [handle](const RTXResource& res) { return res.handle == handle; });
        
    if (it != m_resources.end()) {
        if (m_remix) {
            m_remix->DestroyLight(handle);
        }
        m_resources.erase(it);
    }
}

void RTXDeviceManager::CleanupResources() {
    std::lock_guard<std::mutex> lock(m_resourceMutex);
    
    float currentTime = GetCurrentTime();
    auto it = std::remove_if(m_resources.begin(), m_resources.end(),
        [this, currentTime](const RTXResource& res) {
            if (currentTime - res.lastUpdateTime > RESOURCE_TIMEOUT) {
                if (m_remix) {
                    m_remix->DestroyLight(res.handle);
                }
                return true;
            }
            return false;
        });
    
    m_resources.erase(it, m_resources.end());
}

size_t RTXDeviceManager::GetResourceCount() const {
    std::lock_guard<std::mutex> lock(m_resourceMutex);
    return m_resources.size();
}

float RTXDeviceManager::GetAverageUpdateTime() const {
    return m_metrics.averageUpdateTime;
}

void RTXDeviceManager::UpdatePerformanceMetrics(float updateTime) {
    m_metrics.updateTimes.push_back(updateTime);
    if (m_metrics.updateTimes.size() > m_metrics.maxSamples) {
        m_metrics.updateTimes.erase(m_metrics.updateTimes.begin());
    }

    float sum = 0.0f;
    for (float time : m_metrics.updateTimes) {
        sum += time;
    }
    m_metrics.averageUpdateTime = sum / m_metrics.updateTimes.size();
}

void RTXDeviceManager::DumpDeviceStatus() {
    LogMessage("=== RTX Device Status ===\n");
    LogMessage("Initialized: %s\n", m_isInitialized ? "Yes" : "No");
    LogMessage("Resource count: %zu\n", GetResourceCount());
    LogMessage("Average update time: %.3fms\n", GetAverageUpdateTime() * 1000.0f);
    LogMessage("======================\n");
}

void RTXDeviceManager::LogResourceUsage() {
    std::lock_guard<std::mutex> lock(m_resourceMutex);
    
    LogMessage("=== Resource Usage ===\n");
    LogMessage("Total resources: %zu\n", m_resources.size());
    
    float currentTime = GetCurrentTime();
    for (const auto& res : m_resources) {
        LogMessage("Resource %p: Age=%.2fs, Updates=%zu\n",
            res.handle,
            currentTime - res.creationTime,
            res.updateCount);
    }
    LogMessage("===================\n");
}
