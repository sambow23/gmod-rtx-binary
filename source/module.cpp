#include "GarrysMod/Lua/Interface.h"
#include <remix.h>
#include <vector>

#include "cdll_client_int.h"	//IVEngineClient
#include "materialsystem/imaterialsystem.h"
#include <shaderapi/ishaderapi.h>
#ifdef GMOD_MAIN
extern IMaterialSystem* materials = NULL;
#endif
#include <e_utils.h>
extern IVEngineClient* engine = NULL;
extern IShaderAPI* g_pShaderAPI = NULL;
remix::Interface* g_remix = nullptr;
remixapi_LightHandle g_scene_light = nullptr;

// Add a vector to store all active light handles
std::vector<remixapi_LightHandle> g_active_lights;

using namespace GarrysMod::Lua;

LUA_FUNCTION(CreateRTXLight)
{
    float x = LUA->CheckNumber(1);
    float y = LUA->CheckNumber(2);
    float z = LUA->CheckNumber(3);
    float size = LUA->CheckNumber(4);
    float brightness = LUA->CheckNumber(5);
    float r = LUA->CheckNumber(6);
    float g = LUA->CheckNumber(7);
    float b = LUA->CheckNumber(8);

    Msg("[RTX Remix Fixes] Creating light at (%f, %f, %f) with size %f and brightness %f\n", 
        x, y, z, size, brightness);

    auto sphereLight = remixapi_LightInfoSphereEXT{
        REMIXAPI_STRUCT_TYPE_LIGHT_INFO_SPHERE_EXT,
        nullptr,
        {x, y, z},  // Position
        size,       // Radius
        false,
        {},
    };

    auto lightInfo = remixapi_LightInfo{
        REMIXAPI_STRUCT_TYPE_LIGHT_INFO,
        &sphereLight,
        0x3,
        { r * brightness, g * brightness, b * brightness },
    };
     
    auto lightHandle = g_remix->CreateLight(lightInfo);
    if (!lightHandle) {
        Msg("[RTX Remix Fixes] Failed to create light!\n");
        LUA->ThrowError("[RTX Remix Fixes] - remix::CreateLight() failed");
        return 0;
    }

    // Add the light to our active lights collection
    g_active_lights.push_back(lightHandle.value());

    Msg("[RTX Remix Fixes] Successfully created light handle\n");
    LUA->PushUserdata(lightHandle.value());
    return 1;
}


LUA_FUNCTION(UpdateRTXLight)
{
    auto handle = (remixapi_LightHandle)LUA->GetUserdata(1);
    float x = LUA->CheckNumber(2);
    float y = LUA->CheckNumber(3);
    float z = LUA->CheckNumber(4);
    float size = LUA->CheckNumber(5);
    float brightness = LUA->CheckNumber(6);
    float r = LUA->CheckNumber(7);
    float g = LUA->CheckNumber(8);
    float b = LUA->CheckNumber(9);

    // Remove old handle from active lights
    auto it = std::find(g_active_lights.begin(), g_active_lights.end(), handle);
    if (it != g_active_lights.end()) {
        g_active_lights.erase(it);
    }

    auto sphereLight = remixapi_LightInfoSphereEXT{
        REMIXAPI_STRUCT_TYPE_LIGHT_INFO_SPHERE_EXT,
        nullptr,
        {x, y, z},
        size,
        false,
        {},
    };

    auto lightInfo = remixapi_LightInfo{
        REMIXAPI_STRUCT_TYPE_LIGHT_INFO,
        &sphereLight,
        0x3,
        { r * brightness, g * brightness, b * brightness },
    };

    g_remix->DestroyLight(handle);
    auto newHandle = g_remix->CreateLight(lightInfo);
    if (!newHandle) {
        LUA->ThrowError("[RTX Remix Fixes] - Failed to update light");
        return 0;
    }

    // Add new handle to active lights
    g_active_lights.push_back(newHandle.value());

    LUA->PushUserdata(newHandle.value());
    return 1;
}

LUA_FUNCTION(DestroyRTXLight)
{
    auto handle = (remixapi_LightHandle)LUA->GetUserdata(1);
    
    // Remove from active lights
    auto it = std::find(g_active_lights.begin(), g_active_lights.end(), handle);
    if (it != g_active_lights.end()) {
        g_active_lights.erase(it);
    }

    g_remix->DestroyLight(handle);
    return 0;
}

LUA_FUNCTION(DrawRTXLights)
{ 
    static int frameCount = 0;
    frameCount++;
    
    if (frameCount % 300 == 0) {  // Print every 300 frames
        Msg("[RTX Remix Fixes] Drawing %d lights (frame %d)\n", g_active_lights.size(), frameCount);
    }
    
    // Draw all active lights
    for (const auto& light : g_active_lights) {
        g_remix->DrawLightInstance(light);
    }
    
    return 1;
}

GMOD_MODULE_OPEN()
{ 
    Msg("[RTX Remix Fixes 2] - Module loaded!\n"); 

	g_active_lights.reserve(100);  // Reserve space for up to 100 lights

    LUA->PushSpecial(GarrysMod::Lua::SPECIAL_GLOB); 
        LUA->PushCFunction(CreateRTXLight);
        LUA->SetField(-2, "CreateRTXLight");
        
        LUA->PushCFunction(UpdateRTXLight);
        LUA->SetField(-2, "UpdateRTXLight");
        
        LUA->PushCFunction(DestroyRTXLight);
        LUA->SetField(-2, "DestroyRTXLight");
        
        LUA->PushCFunction(DrawRTXLights);
        LUA->SetField(-2, "DrawRTXLights");
    LUA->Pop();

    Msg("[RTX Remix Fixes 2] - Loading engine\n");
    if (!Sys_LoadInterface("engine", VENGINE_CLIENT_INTERFACE_VERSION, NULL, (void**)&engine))
        LUA->ThrowError("[RTX Remix Fixes 2] - Could not load engine interface");

    Msg("[RTX Remix Fixes 2] - Loading materialsystem\n");
    if (!Sys_LoadInterface("materialsystem", MATERIAL_SYSTEM_INTERFACE_VERSION, NULL, (void**)&materials))
        LUA->ThrowError("[RTX Remix Fixes 2] - Could not load materialsystem interface"); 

    Msg("[RTX Remix Fixes 2] - Loading shaderapi\n"); 
    g_pShaderAPI = (IShaderAPI*)materials->QueryInterface(SHADERAPI_INTERFACE_VERSION);
    if (!g_pShaderAPI)
        LUA->ThrowError("[RTX Remix Fixes 2] - Could not load shaderapi interface");

    auto shaderapidx = GetModuleHandle("shaderapidx9.dll");
    static const char sign[] = "BA E1 0D 74 5E 48 89 1D ?? ?? ?? ??";
    auto ptr = ScanSign(shaderapidx, sign, sizeof(sign) - 1);
    if (!ptr) { LUA->ThrowError("[RTX Remix Fixes 2] - Could find D3D9Device with sig"); }

    auto offset = ((uint32_t*)ptr)[2];
    auto m_pD3DDevice = *(IDirect3DDevice9Ex**)((char*)ptr + offset + 12);
    if (!m_pD3DDevice) { LUA->ThrowError("[RTX Remix Fixes 2] - D3D9Device is null!!"); }

    Msg("[RTX Remix Fixes 2] - Loading remix dll\n");
     
    if (auto interf = remix::lib::loadRemixDllAndInitialize(L"d3d9.dll")) {
        g_remix = new remix::Interface{ *interf };
    }
    else {
        LUA->ThrowError("[RTX Remix Fixes 2] - remix::loadRemixDllAndInitialize() failed"); 
    }

    g_remix->dxvk_RegisterD3D9Device(m_pD3DDevice);

    // Configure RTX settings
    if (g_remix) {
        g_remix->SetConfigVariable("rtx.enableAdvancedMode", "1");
        g_remix->SetConfigVariable("rtx.fallbackLightMode", "2");
        Msg("[RTX Remix Fixes] RTX configuration set\n");
    }

    return 0;
}

GMOD_MODULE_CLOSE()
{
    // Clean up all lights
    for (const auto& light : g_active_lights) {
        if (g_remix && light) {
            g_remix->DestroyLight(light);
        }
    }
    g_active_lights.clear();

    if (g_remix) {
        delete g_remix;
        g_remix = nullptr;
    }
    return 0;
}