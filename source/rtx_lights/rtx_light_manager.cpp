#include "rtx_light_manager.h"
#include <tier0/dbg.h>
#include <algorithm>

RTXLightManager& RTXLightManager::Instance() {
    static RTXLightManager instance;
    return instance;
}

RTXLightManager::RTXLightManager() 
    : m_remix(nullptr)
    , m_initialized(false)
    , m_isFrameActive(false) {
    InitializeCriticalSection(&m_lightCS);
    InitializeCriticalSection(&m_updateCS);
}

RTXLightManager::~RTXLightManager() {
    Shutdown();
    DeleteCriticalSection(&m_lightCS);
    DeleteCriticalSection(&m_updateCS);
}

void RTXLightManager::BeginFrame() {
    EnterCriticalSection(&m_updateCS);
    m_isFrameActive = true;
    ProcessPendingUpdates();
    LeaveCriticalSection(&m_updateCS);
}

void RTXLightManager::EndFrame() {
    EnterCriticalSection(&m_updateCS);
    m_isFrameActive = false;
    ProcessPendingUpdates();
    LeaveCriticalSection(&m_updateCS);
}

void RTXLightManager::ProcessPendingUpdates() {
    if (!m_initialized || !m_remix) return;

    EnterCriticalSection(&m_lightCS);
    
    try {
        int processedUpdates = 0;
        while (!m_pendingUpdates.empty()) {
            auto& update = m_pendingUpdates.front();
            
            if (update.needsUpdate) {
                // Log processing
                LogMessage("Processing update for light %p\n", update.handle);

                auto sphereLight = CreateSphereLight(update.properties);
                auto lightInfo = CreateLightInfo(sphereLight);
                
                auto result = m_remix->CreateLight(lightInfo);
                if (result) {
                    // Find and update existing light
                    auto it = std::find_if(m_lights.begin(), m_lights.end(),
                        [handle = update.handle](const ManagedLight& light) { 
                            return light.handle == handle; 
                    });

                    if (it != m_lights.end()) {
                        // Destroy old light
                        if (it->handle) {
                            m_remix->DestroyLight(it->handle);
                        }
                        
                        // Update with new handle and properties
                        it->handle = result.value();
                        it->properties = update.properties;
                        it->lastUpdateTime = GetTickCount64() / 1000.0f;
                        it->needsUpdate = false;
                        processedUpdates++;

                        LogMessage("Successfully updated light %p\n", it->handle);
                    }
                }
            }
            
            m_pendingUpdates.pop();
        }

        if (processedUpdates > 0) {
            LogMessage("Processed %d light updates\n", processedUpdates);
        }
    }
    catch (...) {
        LogMessage("Exception in ProcessPendingUpdates\n");
    }
    
    LeaveCriticalSection(&m_lightCS);
}

void RTXLightManager::Initialize(remix::Interface* remixInterface) {
    EnterCriticalSection(&m_lightCS);
    m_remix = remixInterface;
    m_initialized = true;
    m_lights.reserve(100);  // Pre-allocate space for lights
    LeaveCriticalSection(&m_lightCS);
    LogMessage("RTX Light Manager initialized\n");
}

void RTXLightManager::Shutdown() {
    EnterCriticalSection(&m_lightCS);
    for (const auto& light : m_lights) {
        if (m_remix && light.handle) {
            m_remix->DestroyLight(light.handle);
        }
    }
    m_lights.clear();
    m_initialized = false;
    m_remix = nullptr;
    LeaveCriticalSection(&m_lightCS);
}

remixapi_LightHandle RTXLightManager::CreateLight(const LightProperties& props) {
    if (!m_initialized || !m_remix) {
        LogMessage("Cannot create light: Manager not initialized\n");
        return nullptr;
    }

    EnterCriticalSection(&m_lightCS);
    
    try {
        LogMessage("Creating light at (%f, %f, %f) with size %f\n", 
            props.x, props.y, props.z, props.size);

        auto sphereLight = remixapi_LightInfoSphereEXT{};
        sphereLight.sType = REMIXAPI_STRUCT_TYPE_LIGHT_INFO_SPHERE_EXT;
        sphereLight.position = {props.x, props.y, props.z};
        sphereLight.radius = props.size;
        sphereLight.shaping_hasvalue = false;
        memset(&sphereLight.shaping_value, 0, sizeof(sphereLight.shaping_value));

        auto lightInfo = remixapi_LightInfo{};
        lightInfo.sType = REMIXAPI_STRUCT_TYPE_LIGHT_INFO;
        lightInfo.pNext = &sphereLight;
        lightInfo.hash = GenerateLightHash();  // Ensure unique hash for each light
        lightInfo.radiance = {
            props.r * props.brightness,
            props.g * props.brightness,
            props.b * props.brightness
        };

        auto result = m_remix->CreateLight(lightInfo);
        if (!result) {
            LogMessage("Remix CreateLight failed\n");
            LeaveCriticalSection(&m_lightCS);
            return nullptr;
        }

        ManagedLight managedLight{};
        managedLight.handle = result.value();
        managedLight.properties = props;
        managedLight.lastUpdateTime = GetTickCount64() / 1000.0f;
        managedLight.needsUpdate = false;

        // Add to lights vector
        m_lights.push_back(managedLight);
        
        LogMessage("Successfully created light handle: %p (Total lights: %d)\n", 
            managedLight.handle, m_lights.size());

        LeaveCriticalSection(&m_lightCS);
        return managedLight.handle;
    }
    catch (...) {
        LogMessage("Exception in CreateLight\n");
        LeaveCriticalSection(&m_lightCS);
        return nullptr;
    }
}

// Add a method to generate unique hashes
uint64_t RTXLightManager::GenerateLightHash() const {
    static uint64_t counter = 0;
    return (static_cast<uint64_t>(GetCurrentProcessId()) << 32) | (++counter);
}

bool RTXLightManager::UpdateLight(remixapi_LightHandle handle, const LightProperties& props) {
    if (!m_initialized || !m_remix) return false;

    EnterCriticalSection(&m_updateCS);
    
    try {
        // Queue the update
        PendingUpdate update;
        update.handle = handle;
        update.properties = props;
        update.needsUpdate = true;

        // Log update for debugging
        LogMessage("Queueing update for light %p: pos(%f,%f,%f) size:%f brightness:%f color:(%f,%f,%f)\n",
            handle, props.x, props.y, props.z, props.size, props.brightness, props.r, props.g, props.b);

        m_pendingUpdates.push(update);

        // If we're not in an active frame, process immediately
        if (!m_isFrameActive) {
            ProcessPendingUpdates();
        }
    }
    catch (...) {
        LogMessage("Exception in UpdateLight\n");
        LeaveCriticalSection(&m_updateCS);
        return false;
    }

    LeaveCriticalSection(&m_updateCS);
    return true;
}

void RTXLightManager::DestroyLight(remixapi_LightHandle handle) {
    if (!m_initialized || !m_remix) return;

    EnterCriticalSection(&m_lightCS);
    
    try {
        // Find and remove all instances of this handle
        auto it = m_lights.begin();
        while (it != m_lights.end()) {
            if (it->handle == handle) {
                LogMessage("Destroying light handle: %p\n", handle);
                m_remix->DestroyLight(it->handle);
                it = m_lights.erase(it);
            } else {
                ++it;
            }
        }
        LogMessage("Light cleanup complete, remaining lights: %d\n", m_lights.size());
    }
    catch (...) {
        LogMessage("Exception in DestroyLight\n");
    }

    LeaveCriticalSection(&m_lightCS);
}

void RTXLightManager::CleanupInvalidLights() {
    try {
        auto it = m_lights.begin();
        while (it != m_lights.end()) {
            bool isValid = false;
            if (it->handle) {
                // Try to draw the light as a validity check
                auto result = m_remix->DrawLightInstance(it->handle);
                isValid = static_cast<bool>(result); // Use the bool operator
            }

            if (!isValid) {
                LogMessage("Removing invalid light handle: %p\n", it->handle);
                if (it->handle) {
                    m_remix->DestroyLight(it->handle);
                }
                it = m_lights.erase(it);
            } else {
                ++it;
            }
        }
    }
    catch (...) {
        LogMessage("Exception in CleanupInvalidLights\n");
    }
}

void RTXLightManager::DrawLights() {
    if (!m_initialized || !m_remix) return;

    EnterCriticalSection(&m_lightCS);
    
    try {
        // Process any pending updates before drawing
        if (!m_isFrameActive) {
            ProcessPendingUpdates();
        }

        for (const auto& light : m_lights) {
            if (light.handle) {
                auto result = m_remix->DrawLightInstance(light.handle);
                if (!static_cast<bool>(result)) {
                    LogMessage("Failed to draw light handle: %p\n", light.handle);
                }
            }
        }
    }
    catch (...) {
        LogMessage("Exception in DrawLights\n");
    }

    LeaveCriticalSection(&m_lightCS);
}

// Helper functions implementation...
remixapi_LightInfoSphereEXT RTXLightManager::CreateSphereLight(const LightProperties& props) {
    remixapi_LightInfoSphereEXT sphereLight = {};
    sphereLight.sType = REMIXAPI_STRUCT_TYPE_LIGHT_INFO_SPHERE_EXT;
    sphereLight.position = {props.x, props.y, props.z};
    sphereLight.radius = props.size;
    sphereLight.shaping_hasvalue = false;
    return sphereLight;
}

remixapi_LightInfo RTXLightManager::CreateLightInfo(const remixapi_LightInfoSphereEXT& sphereLight) {
    remixapi_LightInfo lightInfo = {};
    lightInfo.sType = REMIXAPI_STRUCT_TYPE_LIGHT_INFO;
    lightInfo.pNext = const_cast<remixapi_LightInfoSphereEXT*>(&sphereLight);  // Fix const cast
    lightInfo.hash = GenerateLightHash();
    lightInfo.radiance = {
        sphereLight.position.x * sphereLight.radius,
        sphereLight.position.y * sphereLight.radius,
        sphereLight.position.z * sphereLight.radius
    };
    return lightInfo;
}

void RTXLightManager::LogMessage(const char* format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    Msg("[RTX Light Manager] %s", buffer);
}