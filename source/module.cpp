#include "GarrysMod/Lua/Interface.h"
#include <remix/remix.h>
#include <remix/remix_c.h>
#include "cdll_client_int.h"
#include "materialsystem/imaterialsystem.h"
#include <shaderapi/ishaderapi.h>
#include "e_utils.h"
#include <Windows.h>
#include <d3d9.h>
#include "mwr/mwr.hpp"
#include "rtx_lights/rtx_light_manager.h"
#include "math/math.hpp"
#include "entity_manager/entity_manager.hpp"
#include "shader_fixes/shader_hooks.h"
#include "prop_fixes.h" 


#ifdef GMOD_MAIN
extern IMaterialSystem* materials = NULL;
#endif

// extern IShaderAPI* g_pShaderAPI = NULL;
remix::Interface* g_remix = nullptr;
IDirect3DDevice9Ex* g_d3dDevice = nullptr;

using namespace GarrysMod::Lua;

// typedef HRESULT (WINAPI* Present_t)(IDirect3DDevice9* device, CONST RECT* pSourceRect, CONST RECT* pDestRect, HWND hDestWindowOverride, CONST RGNDATA* pDirtyRegion);
// Present_t Present_Original = nullptr;

// HRESULT WINAPI Present_Hook(IDirect3DDevice9* device, CONST RECT* pSourceRect, CONST RECT* pDestRect, HWND hDestWindowOverride, CONST RGNDATA* pDirtyRegion) {
//     if (g_remix && RTXLightManager::Instance().HasActiveLights()) {
//         RTXLightManager::Instance().DrawLights();
//     }
    
//     return Present_Original(device, pSourceRect, pDestRect, hDestWindowOverride, pDirtyRegion);
// }

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

void ClearRemixResources() {
    if (!g_remix) return;

    // Force a new present cycle
    remixapi_PresentInfo presentInfo = {};
    g_remix->Present(&presentInfo);
    
    // Wait for GPU to finish
    if (g_d3dDevice) {
        g_d3dDevice->EvictManagedResources();
    }
}

LUA_FUNCTION(ClearRTXResources_Native) {
    try {
        Msg("[RTX] Clearing RTX resources...\n");

        if (g_remix) {
            // Force cleanup through config
            g_remix->SetConfigVariable("rtx.resourceLimits.forceCleanup", "1");
            
            // Force a new present cycle
            remixapi_PresentInfo presentInfo = {};
            g_remix->Present(&presentInfo);
            
            // Reset to normal cleanup behavior
            g_remix->SetConfigVariable("rtx.resourceLimits.forceCleanup", "0");
        }
        
        if (g_d3dDevice) {
            g_d3dDevice->EvictManagedResources();
        }

        LUA->PushBool(true);
        return 1;
    } catch (...) {
        Error("[RTX] Exception in ClearRTXResources\n");
        LUA->PushBool(false);
        return 1;
    }
}

LUA_FUNCTION(GetRemixUIState) {
    try {
        if (!g_remix) {
            LUA->PushNumber(0); // None (UI not visible)
            return 1;
        }

        auto result = g_remix->GetUIState();
        if (!result) {
            LUA->PushNumber(0); // None (UI not visible)
            return 1;
        }

        // Convert to a Lua number (matching the enum values)
        int state = static_cast<int>(result.value());
        LUA->PushNumber(state);
        return 1;
    }
    catch (...) {
        Error("[RTX] Exception in GetRemixUIState\n");
        LUA->PushNumber(0);
        return 1;
    }
}

LUA_FUNCTION(SetRemixUIState) {
    try {
        if (!g_remix) {
            LUA->PushBool(false);
            return 1;
        }

        if (!LUA->IsType(1, Type::NUMBER)) {
            LUA->ThrowError("Expected number argument for UI state");
            return 0;
        }

        int stateNum = static_cast<int>(LUA->GetNumber(1));
        remix::UIState state = static_cast<remix::UIState>(stateNum);
        
        auto result = g_remix->SetUIState(state);
        LUA->PushBool(result);
        return 1;
    }
    catch (...) {
        Error("[RTX] Exception in SetRemixUIState\n");
        LUA->PushBool(false);
        return 1;
    }
}

LUA_FUNCTION(PrintRemixUIState) {
    try {
        Msg("[RTX] Checking Remix UI state...\n");
        
        if (!g_remix) {
            Msg("[RTX] Error: g_remix is NULL (Remix API not initialized)\n");
            return 0;
        }
        
        Msg("[RTX] g_remix is valid, checking GetUIState function...\n");
        
        // Check if the function exists in the interface
        if (!g_remix->m_CInterface.GetUIState) {
            Msg("[RTX] Error: GetUIState function is not available in the Remix API\n");
            Msg("[RTX] This may indicate you're using an older version of Remix that doesn't support this feature\n");
            return 0;
        }
        
        Msg("[RTX] GetUIState function exists, calling it...\n");
        
        // Try to call the function directly
        remixapi_UIState rawState = g_remix->m_CInterface.GetUIState();
        Msg("[RTX] Raw UI state value: %d\n", rawState);
        
        // Now try to get it through the wrapper
        auto result = g_remix->GetUIState();
        if (!result) {
            Msg("[RTX] Error: GetUIState wrapper returned failure\n");
            Msg("[RTX] Error code: %d\n", result.status());
            return 0;
        }

        int state = static_cast<int>(result.value());
        const char* stateStr = "Unknown";
        
        switch (state) {
            case 0:
                stateStr = "None (UI not visible)";
                break;
            case 1:
                stateStr = "Basic UI";
                break;
            case 2:
                stateStr = "Advanced UI";
                break;
        }
        
        Msg("[RTX] Current UI state: %d (%s)\n", state, stateStr);
        return 0;
    }
    catch (...) {
        Error("[RTX] Exception in PrintRemixUIState\n");
        return 0;
    }
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

        // Force clean state on startup
        if (g_remix) {
            // Set minimum resource settings
            g_remix->SetConfigVariable("rtx.resourceLimits.maxCacheSize", "256");  // MB
            g_remix->SetConfigVariable("rtx.resourceLimits.maxVRAM", "1024");     // MB
            g_remix->SetConfigVariable("rtx.resourceLimits.forceCleanup", "1");
        }

        // // Setup frame rendering
        // void** vTable = *reinterpret_cast<void***>(sourceDevice);
        // Present_Original = reinterpret_cast<Present_t>(vTable[17]); // Present is at index 17

        // // Setup hook
        // DWORD oldProtect;
        // VirtualProtect(vTable + 17, sizeof(void*), PAGE_EXECUTE_READWRITE, &oldProtect);
        // vTable[17] = reinterpret_cast<void*>(&Present_Hook);
        // VirtualProtect(vTable + 17, sizeof(void*), oldProtect, &oldProtect);

        // // Initialize RTX Light Manager
        // RTXLightManager::Instance().Initialize(g_remix);

        // Configure RTX settings
        if (g_remix) {
            g_remix->SetConfigVariable("rtx.enableAdvancedMode", "1");
            g_remix->SetConfigVariable("rtx.fallbackLightMode", "2");
            Msg("[RTX Remix Fixes] RTX configuration set\n");
        }

        // Register Lua functions
        LUA->PushSpecial(GarrysMod::Lua::SPECIAL_GLOB); 

            LUA->PushCFunction(GetRemixUIState);
            LUA->SetField(-2, "GetRemixUIState");

            LUA->PushCFunction(SetRemixUIState);
            LUA->SetField(-2, "SetRemixUIState");

            LUA->PushCFunction(PrintRemixUIState);
            LUA->SetField(-2, "PrintRemixUIState");

            LUA->PushCFunction(ClearRTXResources_Native);
            LUA->SetField(-2, "ClearRTXResources");

            RTXMath::Initialize(LUA);
            EntityManager::Initialize(LUA);
            MeshRenderer::Initialize(LUA);

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
        
        // RTXLightManager::Instance().Shutdown();

        // // Restore original Present function if needed
        // if (Present_Original) {
        //     auto device = static_cast<IDirect3DDevice9Ex*>(FindD3D9Device());
        //     if (device) {
        //         void** vTable = *reinterpret_cast<void***>(device);
        //         DWORD oldProtect;
        //         VirtualProtect(vTable + 17, sizeof(void*), PAGE_EXECUTE_READWRITE, &oldProtect);
        //         vTable[17] = reinterpret_cast<void*>(Present_Original);
        //         VirtualProtect(vTable + 17, sizeof(void*), oldProtect, &oldProtect);
        //     }
        // }

        if (g_remix) {
            delete g_remix;
            g_remix = nullptr;
        }

        g_d3dDevice = nullptr;

        Msg("[RTX] Module shutdown complete\n");
        return 0;
    }
    catch (...) {
        Error("[RTX] Exception in module shutdown\n");
        return 0;
    }
}