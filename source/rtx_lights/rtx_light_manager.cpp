#include "rtx_light_manager.h"
#include <tier0/dbg.h>
#include <algorithm>

RTXLightManager& RTXLightManager::Instance() {
    static RTXLightManager instance;
    return instance;
}

RTXLightManager::RTXLightManager() 
    : m_remix(nullptr)
    , m_initialized(false) {
    InitializeCriticalSection(&m_lightCS);
}

RTXLightManager::~RTXLightManager() {
    Shutdown();
    DeleteCriticalSection(&m_lightCS);
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

        LogMessage("Created sphere light with radius %f\n", sphereLight.radius);

        auto lightInfo = remixapi_LightInfo{};
        lightInfo.sType = REMIXAPI_STRUCT_TYPE_LIGHT_INFO;
        lightInfo.pNext = &sphereLight;
        lightInfo.hash = 0x3;  // Use the same hash as the working version
        lightInfo.radiance = {
            props.r * props.brightness,
            props.g * props.brightness,
            props.b * props.brightness
        };

        LogMessage("Creating light with radiance (%f, %f, %f)\n",
            lightInfo.radiance.x, lightInfo.radiance.y, lightInfo.radiance.z);

        auto result = m_remix->CreateLight(lightInfo);
        if (!result) {
            LogMessage("Remix CreateLight failed with status: %d\n", result.status());
            LeaveCriticalSection(&m_lightCS);
            return nullptr;
        }

        ManagedLight managedLight{};
        managedLight.handle = result.value();
        managedLight.properties = props;
        managedLight.lastUpdateTime = GetTickCount64() / 1000.0f;
        managedLight.needsUpdate = false;

        m_lights.push_back(managedLight);
        
        LogMessage("Successfully created light handle: %p\n", managedLight.handle);
        LeaveCriticalSection(&m_lightCS);
        return managedLight.handle;
    }
    catch (...) {
        LogMessage("Exception in CreateLight\n");
        LeaveCriticalSection(&m_lightCS);
        return nullptr;
    }
}

bool RTXLightManager::UpdateLight(remixapi_LightHandle handle, const LightProperties& props) {
    if (!m_initialized || !m_remix) return false;

    EnterCriticalSection(&m_lightCS);
    
    try {
        auto it = std::find_if(m_lights.begin(), m_lights.end(),
            [handle](const ManagedLight& light) { return light.handle == handle; });

        if (it != m_lights.end()) {
            // Create new light with updated properties
            auto sphereLight = CreateSphereLight(props);
            auto lightInfo = CreateLightInfo(sphereLight);
            
            auto result = m_remix->CreateLight(lightInfo);
            if (!result) {
                LeaveCriticalSection(&m_lightCS);
                return false;
            }

            // Destroy old light
            m_remix->DestroyLight(it->handle);
            
            // Update managed light
            it->handle = result.value();
            it->properties = props;
            it->lastUpdateTime = GetTickCount64() / 1000.0f;
            it->needsUpdate = false;

            LeaveCriticalSection(&m_lightCS);
            return true;
        }
    }
    catch (...) {
        LogMessage("Exception in UpdateLight\n");
    }

    LeaveCriticalSection(&m_lightCS);
    return false;
}

void RTXLightManager::DestroyLight(remixapi_LightHandle handle) {
    if (!m_initialized || !m_remix) return;

    EnterCriticalSection(&m_lightCS);
    
    auto it = std::find_if(m_lights.begin(), m_lights.end(),
        [handle](const ManagedLight& light) { return light.handle == handle; });

    if (it != m_lights.end()) {
        m_remix->DestroyLight(it->handle);
        m_lights.erase(it);
    }

    LeaveCriticalSection(&m_lightCS);
}

void RTXLightManager::DrawLights() {
    if (!m_initialized || !m_remix) return;

    EnterCriticalSection(&m_lightCS);
    
    try {
        for (const auto& light : m_lights) {
            if (light.handle) {
                m_remix->DrawLightInstance(light.handle);
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

uint64_t RTXLightManager::GenerateLightHash() const {
    static uint64_t counter = 0;
    return (static_cast<uint64_t>(GetCurrentProcessId()) << 32) | (++counter);
}

void RTXLightManager::LogMessage(const char* format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    Msg("[RTX Light Manager] %s", buffer);
}