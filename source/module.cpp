#include "GarrysMod/Lua/Interface.h"
#include <remix/remix.h>
#include <remix/remix_c.h>
#include "cdll_client_int.h"
#include "materialsystem/imaterialsystem.h"
#include <shaderapi/ishaderapi.h>
#include "e_utils.h"
#include <Windows.h>
#include <d3d9.h>
#include "rtx_light_manager/rtx_light_manager.hpp"
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

typedef HRESULT (WINAPI* Present_t)(IDirect3DDevice9* device, CONST RECT* pSourceRect, CONST RECT* pDestRect, HWND hDestWindowOverride, CONST RGNDATA* pDirtyRegion);
Present_t Present_Original = nullptr;

HRESULT WINAPI Present_Hook(IDirect3DDevice9* device, CONST RECT* pSourceRect, CONST RECT* pDestRect, HWND hDestWindowOverride, CONST RGNDATA* pDirtyRegion) {
    if (g_remix && RTXLightManager::Instance().HasActiveLights()) {
        RTXLightManager::Instance().DrawLights();
    }
    
    return Present_Original(device, pSourceRect, pDestRect, hDestWindowOverride, pDirtyRegion);
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

GMOD_MODULE_OPEN() { 
    try {
        Msg("[RTX Remix Fixes 2] - Module loaded!\n"); 

        // Initialize Remix properly
        if (auto interf = remix::lib::loadRemixDllAndInitialize(L"d3d9.dll")) {
            g_remix = new remix::Interface{ *interf };

            // Initialize with proper startup info
            remixapi_StartupInfo startupInfo = {};
            startupInfo.sType = REMIXAPI_STRUCT_TYPE_STARTUP_INFO;
            startupInfo.hwnd = NULL; // We'll use the game's window
            startupInfo.disableSrgbConversionForOutput = false;
            startupInfo.forceNoVkSwapchain = false;
            
            if (auto result = g_remix->Startup(startupInfo)) {
                // Find and register Source's D3D9 device
                auto sourceDevice = static_cast<IDirect3DDevice9Ex*>(FindD3D9Device());
                if (!sourceDevice) {
                    LUA->ThrowError("[RTX] Failed to find D3D9 device");
                    return 0;
                }

                g_remix->dxvk_RegisterD3D9Device(sourceDevice);

                // Configure RTX settings
                g_remix->SetConfigVariable("rtx.enableAdvancedMode", "1");
                g_remix->SetConfigVariable("rtx.fallbackLightMode", "2");

                // Initialize RTX Light Manager
                if (!RTXLightManager::Instance().Initialize()) {
                    LUA->ThrowError("[RTX] Failed to initialize RTX Light Manager");
                    return 0;
                }

                RTXLightManager::RegisterLuaFunctions(LUA);
            } else {
                LUA->ThrowError("[RTX] Failed to start Remix Runtime");
            }
        } else {
            LUA->ThrowError("[RTX] Failed to initialize Remix API");
        }

        // Register other Lua functions
        LUA->PushSpecial(GarrysMod::Lua::SPECIAL_GLOB); 
        LUA->PushCFunction(ClearRTXResources_Native);
        LUA->SetField(-2, "ClearRTXResources");
        RTXMath::Initialize(LUA);
        EntityManager::Initialize(LUA);
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

        // Cleanup RTX Light Manager
        RTXLightManager::Instance().Cleanup();

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