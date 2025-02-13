#include "GarrysMod/Lua/Interface.h"
#include <remix/remix.h>
#include <remix/remix_c.h>
#include "cdll_client_int.h"
#include "materialsystem/imaterialsystem.h"
#include <shaderapi/ishaderapi.h>
#include "e_utils.h"
#include <Windows.h>
#include <d3d9.h>
#include "rtx_lights/rtx_light_manager.h"
#include "shader_fixes/shader_hooks.h"
#include "prop_fixes.h" 

#ifdef GMOD_MAIN
extern IMaterialSystem* materials = NULL;
#endif

// extern IShaderAPI* g_pShaderAPI = NULL;
remix::Interface* g_remix = nullptr;

using namespace GarrysMod::Lua;

typedef HRESULT (WINAPI* Present_t)(IDirect3DDevice9* device, CONST RECT* pSourceRect, CONST RECT* pDestRect, HWND hDestWindowOverride, CONST RGNDATA* pDirtyRegion);
Present_t Present_Original = nullptr;

HRESULT WINAPI Present_Hook(IDirect3DDevice9* device, CONST RECT* pSourceRect, CONST RECT* pDestRect, HWND hDestWindowOverride, CONST RGNDATA* pDirtyRegion) {
    if (g_remix && RTXLightManager::Instance().HasActiveLights()) {
        RTXLightManager::Instance().DrawLights();
    }
    
    return Present_Original(device, pSourceRect, pDestRect, hDestWindowOverride, pDirtyRegion);
}

LUA_FUNCTION(RTXBeginFrame) {
    RTXLightManager::Instance().BeginFrame();
    return 0;
}

LUA_FUNCTION(RTXEndFrame) {
    RTXLightManager::Instance().EndFrame();
    return 0;
}

LUA_FUNCTION(RegisterRTXLightEntityValidator) {
    if (!LUA->IsType(1, GarrysMod::Lua::Type::FUNCTION)) {
        LUA->ThrowError("Expected function as argument 1");
        return 0;
    }

    // Store the function reference
    LUA->Push(1); // Push the function
    int functionRef = LUA->ReferenceCreate();

    // Create the validator function that will call back to Lua
    auto validator = [=](uint64_t entityID) -> bool {
        LUA->ReferencePush(functionRef); // Push the stored function
        LUA->PushNumber(static_cast<double>(entityID)); // Push entity ID
        LUA->Call(1, 1); // Call with 1 arg, expect 1 return

        bool exists = LUA->GetBool(-1);
        LUA->Pop(); // Pop the return value

        return exists;
    };

    // Register the validator with the RTX Light Manager
    RTXLightManager::Instance().RegisterLuaEntityValidator(validator);

    return 0;
}

LUA_FUNCTION(CreateRTXLight) {
    try {
        if (!g_remix) {
            Msg("[RTX Remix Fixes] Remix interface is null\n");
            LUA->ThrowError("[RTX Remix Fixes] - Remix interface is null");
            return 0;
        }

        float x = LUA->CheckNumber(1);
        float y = LUA->CheckNumber(2);
        float z = LUA->CheckNumber(3);
        float size = LUA->CheckNumber(4);
        float brightness = LUA->CheckNumber(5);
        float r = LUA->CheckNumber(6);
        float g = LUA->CheckNumber(7);
        float b = LUA->CheckNumber(8);
        // Get entity ID from Lua, default to 0 if not provided
        uint64_t entityID = LUA->IsType(9, Type::NUMBER) ? static_cast<uint64_t>(LUA->GetNumber(9)) : 0;

        // Debug print received values
        Msg("[RTX Light Module] Received values - Pos: %.2f,%.2f,%.2f, Size: %f, Brightness: %f, Color: %f,%f,%f, EntityID: %llu\n",
            x, y, z, size, brightness, r, g, b, entityID);

        auto props = RTXLightManager::LightProperties();
        props.x = x;
        props.y = y;
        props.z = z;
        props.size = size;
        props.brightness = brightness;
        props.r = r / 255.0f;
        props.g = g / 255.0f;
        props.b = b / 255.0f;

        auto& manager = RTXLightManager::Instance();
        auto handle = manager.CreateLight(props, entityID);  // Pass the entityID
        if (!handle) {
            Msg("[RTX Light Module] Failed to create light!\n");
            LUA->ThrowError("[RTX Remix Fixes] - Failed to create light");
            return 0;
        }

        Msg("[RTX Light Module] Light created successfully with handle %p\n", handle);
        LUA->PushUserdata(handle);
        return 1;
    }
    catch (...) {
        Msg("[RTX Light Module] Exception in CreateRTXLight\n");
        LUA->ThrowError("[RTX Remix Fixes] - Exception in light creation");
        return 0;
    }
}


LUA_FUNCTION(UpdateRTXLight) {
    try {
        if (!g_remix) {
            Msg("[RTX Remix Fixes] Remix interface is null\n");
            LUA->PushBool(false);
            return 1;
        }

        // Validate userdata type
        if (!LUA->IsType(1, Type::USERDATA)) {
            Msg("[RTX Remix Fixes] First argument must be userdata\n");
            LUA->PushBool(false);
            return 1;
        }

        auto handle = static_cast<remixapi_LightHandle>(LUA->GetUserdata(1));
        if (!handle) {
            Msg("[RTX Remix Fixes] Invalid light handle (null)\n");
            LUA->PushBool(false);
            return 1;
        }

        // Additional handle validation
        bool isValidHandle = false;
        try {
            auto& manager = RTXLightManager::Instance();
            isValidHandle = manager.IsValidHandle(handle);
        } catch (...) {
            Msg("[RTX Remix Fixes] Exception checking handle validity\n");
            LUA->PushBool(false);
            return 1;
        }

        if (!isValidHandle) {
            Msg("[RTX Remix Fixes] Invalid light handle (not found)\n");
            LUA->PushBool(false);
            return 1;
        }

        float x = LUA->CheckNumber(2);
        float y = LUA->CheckNumber(3);
        float z = LUA->CheckNumber(4);
        float size = LUA->CheckNumber(5);
        float brightness = LUA->CheckNumber(6);
        float r = LUA->CheckNumber(7);
        float g = LUA->CheckNumber(8);
        float b = LUA->CheckNumber(9);

        Msg("[RTX Remix Fixes] Updating light at (%f, %f, %f) with size %f and brightness %f\n", 
            x, y, z, size, brightness);

        auto props = RTXLightManager::LightProperties();
        props.x = x;
        props.y = y;
        props.z = z;
        props.size = size < 1.0f ? 1.0f : size;
        props.brightness = brightness < 0.1f ? 0.1f : brightness;
        props.r = (r / 255.0f) > 1.0f ? 1.0f : (r / 255.0f < 0.0f ? 0.0f : r / 255.0f);
        props.g = (g / 255.0f) > 1.0f ? 1.0f : (g / 255.0f < 0.0f ? 0.0f : g / 255.0f);
        props.b = (b / 255.0f) > 1.0f ? 1.0f : (b / 255.0f < 0.0f ? 0.0f : b / 255.0f);

        auto& manager = RTXLightManager::Instance();
        remixapi_LightHandle newHandle;
        if (!manager.UpdateLight(handle, props, &newHandle)) {
            Msg("[RTX Remix Fixes] Failed to update light\n");
            LUA->PushBool(false);
            return 1;
        }

        LUA->PushBool(true);
        if (newHandle != handle) {
            LUA->PushUserdata(newHandle);
            return 2;
        }
        return 1;
    }
    catch (...) {
        Msg("[RTX Remix Fixes] Exception in UpdateRTXLight\n");
        LUA->PushBool(false);
        return 1;
    }
}

LUA_FUNCTION(DestroyRTXLight) {
    try {
        auto handle = static_cast<remixapi_LightHandle>(LUA->GetUserdata(1));
        RTXLightManager::Instance().DestroyLight(handle);
        return 0;
    }
    catch (...) {
        Msg("[RTX Remix Fixes] Exception in DestroyRTXLight\n");
        return 0;
    }
}

LUA_FUNCTION(DrawRTXLights) { 
    try {
        if (!g_remix) {
            Msg("[RTX Remix Fixes] Cannot draw lights - Remix interface is null\n");
            return 0;
        }

        RTXLightManager::Instance().DrawLights();
        return 0;
    }
    catch (...) {
        Msg("[RTX Remix Fixes] Exception in DrawRTXLights\n");
        return 0;
    }
}

void* FindD3D9Device() {
    auto shaderapidx = GetModuleHandle("shaderapidx9.dll");
    if (!shaderapidx) {
        Error("[RTX] Failed to get shaderapidx9.dll module\n");
        return nullptr;
    }

    Msg("[RTX] shaderapidx9.dll module: %p\n", shaderapidx);

    static const char sign[] = "BA E1 0D 74 5E 48 89 1D ?? ?? ?? ??";
    auto ptr = ScanSign(shaderapidx, sign, sizeof(sign) - 1);
    if (!ptr) { 
        Error("[RTX] Failed to find D3D9Device signature\n");
        return nullptr;
    }

    auto offset = ((uint32_t*)ptr)[2];
    auto device = *(IDirect3DDevice9Ex**)((char*)ptr + offset + 12);
    if (!device) {
        Error("[RTX] D3D9Device pointer is null\n");
        return nullptr;
    }

    return device;
}

GMOD_MODULE_OPEN() { 
    try {
        Msg("[RTX Remix Fixes 2] - Module loaded!\n"); 

        // Find Source's D3D9 device
        auto sourceDevice = static_cast<IDirect3DDevice9Ex*>(FindD3D9Device());
        if (!sourceDevice) {
            LUA->ThrowError("[RTX] Failed to find D3D9 device");
            return 0;
        }

        // Initialize Remix
        if (auto interf = remix::lib::loadRemixDllAndInitialize(L"d3d9.dll")) {
            g_remix = new remix::Interface{ *interf };
        }
        else {
            LUA->ThrowError("[RTX Remix Fixes 2] - remix::loadRemixDllAndInitialize() failed"); 
        }

        g_remix->dxvk_RegisterD3D9Device(sourceDevice);

        // Setup frame rendering
        void** vTable = *reinterpret_cast<void***>(sourceDevice);
        Present_Original = reinterpret_cast<Present_t>(vTable[17]); // Present is at index 17

        // Setup hook
        DWORD oldProtect;
        VirtualProtect(vTable + 17, sizeof(void*), PAGE_EXECUTE_READWRITE, &oldProtect);
        vTable[17] = reinterpret_cast<void*>(&Present_Hook);
        VirtualProtect(vTable + 17, sizeof(void*), oldProtect, &oldProtect);

        // Initialize RTX Light Manager
        RTXLightManager::Instance().Initialize(g_remix);

        // Configure RTX settings
        if (g_remix) {
            g_remix->SetConfigVariable("rtx.enableAdvancedMode", "1");
            g_remix->SetConfigVariable("rtx.fallbackLightMode", "2");
            Msg("[RTX Remix Fixes] RTX configuration set\n");
        }

        // Register Lua functions
        LUA->PushSpecial(GarrysMod::Lua::SPECIAL_GLOB); 
            LUA->PushCFunction(RTXBeginFrame);
            LUA->SetField(-2, "RTXBeginFrame");
            
            LUA->PushCFunction(RTXEndFrame);
            LUA->SetField(-2, "RTXEndFrame");

            LUA->PushCFunction(RegisterRTXLightEntityValidator);
            LUA->SetField(-2, "RegisterRTXLightEntityValidator");

            LUA->PushCFunction(CreateRTXLight);
            LUA->SetField(-2, "CreateRTXLight");
            
            LUA->PushCFunction(UpdateRTXLight);
            LUA->SetField(-2, "UpdateRTXLight");
            
            LUA->PushCFunction(DestroyRTXLight);
            LUA->SetField(-2, "DestroyRTXLight");
            
            LUA->PushCFunction(DrawRTXLights);
            LUA->SetField(-2, "DrawRTXLights");
        LUA->Pop();

        return 0;
    }
    catch (...) {
        Error("[RTX] Exception in module initialization\n");
        return 0;
    }
}

GMOD_MODULE_CLOSE() {
    try {
        Msg("[RTX] Shutting down module...\n");
        
        RTXLightManager::Instance().Shutdown();

        // Restore original Present function if needed
        if (Present_Original) {
            auto device = static_cast<IDirect3DDevice9Ex*>(FindD3D9Device());
            if (device) {
                void** vTable = *reinterpret_cast<void***>(device);
                DWORD oldProtect;
                VirtualProtect(vTable + 17, sizeof(void*), PAGE_EXECUTE_READWRITE, &oldProtect);
                vTable[17] = reinterpret_cast<void*>(Present_Original);
                VirtualProtect(vTable + 17, sizeof(void*), oldProtect, &oldProtect);
            }
        }

        if (g_remix) {
            delete g_remix;
            g_remix = nullptr;
        }

        Msg("[RTX] Module shutdown complete\n");
        return 0;
    }
    catch (...) {
        Error("[RTX] Exception in module shutdown\n");
        return 0;
    }
}