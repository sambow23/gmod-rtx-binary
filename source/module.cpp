#include "GarrysMod/Lua/Interface.h"
#include <remix.h>

/*
	require "HelloWorld"
	print( TestFunction( 5, 17 ) )
*/

using namespace GarrysMod::Lua;

LUA_FUNCTION( MyExampleFunction )
{
	double first_number = LUA->CheckNumber( 1 );
	double second_number = LUA->CheckNumber( 2 );

	LUA->PushNumber( first_number + second_number );
	return 1;
}

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

GMOD_MODULE_OPEN()
{ 
	Msg("[RTX Remix Fixes 2] - Module loaded!\n"); 
	LUA->PushSpecial( GarrysMod::Lua::SPECIAL_GLOB );
	LUA->PushString( "TestFunction" );
	LUA->PushCFunction( MyExampleFunction );
	LUA->SetTable( -3 ); // `_G.TestFunction = MyExampleFunction`

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

	//MaterialAdapterInfo_t info;
	//g_pShaderAPI->shader

	// supply IDirect3DDevice9Ex
	// 
	// HOW do i get this thing
	g_remix->dxvk_RegisterD3D9Device(m_pD3DDevice); //g_pShaderAPI->GetD3DDevice() or Dx9Device() somehow?

	g_remix->SetConfigVariable("rtx.fallbackLightMode", "2");

	auto sphereLight = remixapi_LightInfoSphereEXT{
		REMIXAPI_STRUCT_TYPE_LIGHT_INFO_SPHERE_EXT,
		nullptr,
		{0,-1,0},
		0.1f,
		false ,
		{},
	};
	auto lightInfo = remixapi_LightInfo{
		REMIXAPI_STRUCT_TYPE_LIGHT_INFO,
		&sphereLight,
		0x3,
		{ 100, 200, 100 },
	};
	 
	auto lightHandle = g_remix->CreateLight(lightInfo);
	Msg("[RTX Remix Fixes 2] - creating light...\n");
	if (!lightHandle) {
		LUA->ThrowError("[RTX Remix Fixes 2] - remix::CreateLight() failed"); 
	}

	return 0;
}

GMOD_MODULE_CLOSE()
{
	return 0;
}