#include "GarrysMod/Lua/Interface.h"
#include "rtx_device/rtx_device.h"
#include <remix/remix.h>
#include <chrono>
#include <Windows.h>
#include "e_utils.h"
#include <sysinfoapi.h>  // For GetTickCount64

using namespace GarrysMod::Lua;

// Helper function to measure execution time
class ScopedTimer {
public:
    ScopedTimer(float& output) : m_output(output), m_start(std::chrono::high_resolution_clock::now()) {}
    ~ScopedTimer() {
        auto end = std::chrono::high_resolution_clock::now();
        m_output = std::chrono::duration<float>(end - m_start).count();
    }
private:
    float& m_output;
    std::chrono::time_point<std::chrono::high_resolution_clock> m_start;
};

// Find Source's D3D9 device
void* FindD3D9Device() {
    try {
        auto shaderapidx = GetModuleHandle("shaderapidx9.dll");
        if (!shaderapidx) {
            Error("[RTX] Failed to get shaderapidx9.dll module\n");
            return nullptr;
        }

        Msg("[RTX] shaderapidx9.dll module: %p\n", shaderapidx);

        // Use the original working pattern
        static const char sign[] = "BA E1 0D 74 5E 48 89 1D ?? ?? ?? ??";
        Msg("[RTX] Scanning for pattern: %s\n", sign);

        auto ptr = reinterpret_cast<uintptr_t>(ScanSign(shaderapidx, sign, sizeof(sign) - 1));
        if (!ptr) {
            Error("[RTX] Failed to find D3D9Device signature\n");
            return nullptr;
        }

        Msg("[RTX] Found pattern at: %p\n", (void*)ptr);

        // The pattern points to the instruction that references the D3D9 device
        // The offset is stored as a 32-bit relative offset after the instruction
        auto relativeOffset = *reinterpret_cast<int32_t*>(ptr + 8); // Skip the "48 89 1D" part
        Msg("[RTX] Relative offset: 0x%x\n", relativeOffset);

        // Calculate absolute address: RIP (next instruction) + relative offset
        auto nextInstruction = ptr + 12; // Length of the entire instruction
        auto devicePtr = nextInstruction + relativeOffset;
        
        Msg("[RTX] Calculated device pointer location: %p\n", (void*)devicePtr);

        // Read the device pointer
        auto device = *reinterpret_cast<IDirect3DDevice9Ex**>(devicePtr);
        if (!device) {
            Error("[RTX] D3D9Device pointer is null\n");
            return nullptr;
        }

        Msg("[RTX] Device pointer: %p\n", device);

        // Try to verify the device
        HRESULT hr = device->TestCooperativeLevel();
        Msg("[RTX] Device test result: 0x%lx\n", hr);

        return device;
    }
    catch (const std::exception& e) {
        Error("[RTX] Exception while finding D3D9 device: %s\n", e.what());
        return nullptr;
    }
    catch (...) {
        Error("[RTX] Unknown exception while finding D3D9 device\n");
        return nullptr;
    }
}

LUA_FUNCTION(CreateRTXLight) {
    auto& device = RTXDeviceManager::Instance();
    if (!device.IsInitialized()) {
        LUA->ThrowError("[RTX] Device not initialized");
        return 0;
    }

    float x = static_cast<float>(LUA->CheckNumber(1));
    float y = static_cast<float>(LUA->CheckNumber(2));
    float z = static_cast<float>(LUA->CheckNumber(3));
    float size = static_cast<float>(LUA->CheckNumber(4));
    float brightness = static_cast<float>(LUA->CheckNumber(5));
    float r = static_cast<float>(LUA->CheckNumber(6));
    float g = static_cast<float>(LUA->CheckNumber(7));
    float b = static_cast<float>(LUA->CheckNumber(8));

    float executionTime = 0.0f;

    // Add this line to declare the light handle
    remixapi_LightHandle lightHandle = nullptr;

    {
        ScopedTimer timer(executionTime);

        remixapi_LightInfoSphereEXT sphereLight;
        memset(&sphereLight, 0, sizeof(sphereLight));
        sphereLight.sType = REMIXAPI_STRUCT_TYPE_LIGHT_INFO_SPHERE_EXT;
        sphereLight.position.x = x;
        sphereLight.position.y = y;
        sphereLight.position.z = z;
        sphereLight.radius = size;
        sphereLight.shaping_hasvalue = false;

        remixapi_LightInfo lightInfo;
        memset(&lightInfo, 0, sizeof(lightInfo));
        lightInfo.sType = REMIXAPI_STRUCT_TYPE_LIGHT_INFO;
        lightInfo.pNext = &sphereLight;
        lightInfo.hash = static_cast<uint64_t>(static_cast<uint64_t>(GetCurrentProcessId()) + GetTickCount64());
        lightInfo.radiance.x = r * brightness;
        lightInfo.radiance.y = g * brightness;
        lightInfo.radiance.z = b * brightness;

        auto result = device.GetRemix()->CreateLight(lightInfo);
        if (!result) {
            LUA->ThrowError("[RTX] Failed to create light");
            return 0;
        }

        lightHandle = result.value();
    }

    if (!device.AddResource(lightHandle)) {
        device.GetRemix()->DestroyLight(lightHandle);
        LUA->ThrowError("[RTX] Failed to add light to resource manager");
        return 0;
    }

    device.UpdatePerformanceMetrics(executionTime);
    
    LUA->PushUserdata(lightHandle);
    return 1;
}


LUA_FUNCTION(UpdateRTXLight) {
    auto& device = RTXDeviceManager::Instance();
    if (!device.IsInitialized()) {
        LUA->ThrowError("[RTX] Device not initialized");
        return 0;
    }

    auto handle = static_cast<remixapi_LightHandle>(LUA->GetUserdata(1));
    float x = static_cast<float>(LUA->CheckNumber(2));
    float y = static_cast<float>(LUA->CheckNumber(3));
    float z = static_cast<float>(LUA->CheckNumber(4));
    float size = static_cast<float>(LUA->CheckNumber(5));
    float brightness = static_cast<float>(LUA->CheckNumber(6));
    float r = static_cast<float>(LUA->CheckNumber(7));
    float g = static_cast<float>(LUA->CheckNumber(8));
    float b = static_cast<float>(LUA->CheckNumber(9));

    float executionTime = 0.0f;
    // Move the declaration here
    remixapi_LightHandle newHandle = nullptr;

    {
        ScopedTimer timer(executionTime);

        // Remove old light
        device.RemoveResource(handle);

        // Create new light
        remixapi_LightInfoSphereEXT sphereLight;
        memset(&sphereLight, 0, sizeof(sphereLight));
        sphereLight.sType = REMIXAPI_STRUCT_TYPE_LIGHT_INFO_SPHERE_EXT;
        sphereLight.position.x = x;
        sphereLight.position.y = y;
        sphereLight.position.z = z;
        sphereLight.radius = size;
        sphereLight.shaping_hasvalue = false;

        remixapi_LightInfo lightInfo;
        memset(&lightInfo, 0, sizeof(lightInfo));
        lightInfo.sType = REMIXAPI_STRUCT_TYPE_LIGHT_INFO;
        lightInfo.pNext = &sphereLight;
        lightInfo.hash = static_cast<uint64_t>(static_cast<uint64_t>(GetCurrentProcessId()) + GetTickCount64());
        lightInfo.radiance.x = r * brightness;
        lightInfo.radiance.y = g * brightness;
        lightInfo.radiance.z = b * brightness;

        auto result = device.GetRemix()->CreateLight(lightInfo);
        if (!result) {
            LUA->ThrowError("[RTX] Failed to update light");
            return 0;
        }

        newHandle = result.value();
    }

    if (!device.AddResource(newHandle)) {
        device.GetRemix()->DestroyLight(newHandle);
        LUA->ThrowError("[RTX] Failed to add updated light to resource manager");
        return 0;
    }

    device.UpdatePerformanceMetrics(executionTime);

    LUA->PushUserdata(newHandle);
    return 1;
}

LUA_FUNCTION(DestroyRTXLight) {
    auto& device = RTXDeviceManager::Instance();
    if (!device.IsInitialized()) return 0;

    auto handle = static_cast<remixapi_LightHandle>(LUA->GetUserdata(1));
    
    float executionTime = 0.0f;
    {
        ScopedTimer timer(executionTime);
        device.RemoveResource(handle);
    }

    device.UpdatePerformanceMetrics(executionTime);
    return 0;
}

LUA_FUNCTION(DrawRTXLights) {
    auto& device = RTXDeviceManager::Instance();
    if (!device.IsInitialized()) return 0;

    device.CleanupResources();

    // Present the frame
    device.GetRemix()->Present(nullptr);
    return 0;
}

LUA_FUNCTION(GetRTXDeviceStatus) {
    auto& device = RTXDeviceManager::Instance();
    
    LUA->CreateTable();
    
    LUA->PushBool(device.IsInitialized());
    LUA->SetField(-2, "initialized");
    
    LUA->PushNumber(device.GetResourceCount());
    LUA->SetField(-2, "resourceCount");
    
    LUA->PushNumber(device.GetAverageUpdateTime() * 1000.0f); // Convert to milliseconds
    LUA->SetField(-2, "averageUpdateTime");
    
    return 1;
}

GMOD_MODULE_OPEN() {
    try {
        Msg("[RTX] Initializing module...\n");

        // Find Source's D3D9 device
        auto sourceDevice = static_cast<IDirect3DDevice9Ex*>(FindD3D9Device());
        if (!sourceDevice) {
            LUA->ThrowError("[RTX] Failed to find D3D9 device");
            return 0;
        }

        // Initialize RTX device
        auto& device = RTXDeviceManager::Instance();
        if (!device.Initialize(sourceDevice)) {
            LUA->ThrowError("[RTX] Failed to initialize device");
            return 0;
        }

        // Register Lua functions
        LUA->PushSpecial(GarrysMod::Lua::SPECIAL_GLOB);
            LUA->PushCFunction(CreateRTXLight);
            LUA->SetField(-2, "CreateRTXLight");
            
            LUA->PushCFunction(UpdateRTXLight);
            LUA->SetField(-2, "UpdateRTXLight");
            
            LUA->PushCFunction(DestroyRTXLight);
            LUA->SetField(-2, "DestroyRTXLight");
            
            LUA->PushCFunction(DrawRTXLights);
            LUA->SetField(-2, "DrawRTXLights");
            
            LUA->PushCFunction(GetRTXDeviceStatus);
            LUA->SetField(-2, "GetRTXDeviceStatus");
        LUA->Pop();

        device.DumpDeviceStatus();
        Msg("[RTX] Module initialized successfully\n");
        return 0;
    }
    catch (const std::exception& e) {
        Error("[RTX] Exception during module initialization: %s\n", e.what());
        return 0;
    }
    catch (...) {
        Error("[RTX] Unknown exception during module initialization\n");
        return 0;
    }
}

GMOD_MODULE_CLOSE() {
    Msg("[RTX] Shutting down module...\n");
    
    auto& device = RTXDeviceManager::Instance();
    device.LogResourceUsage();
    device.Shutdown();

    Msg("[RTX] Module shutdown complete\n");
    return 0;
}