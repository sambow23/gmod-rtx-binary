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

GMOD_MODULE_OPEN()
{ 
	Msg("[RTX Remix Fixes 2] - Module loaded!\n"); 
	LUA->PushSpecial( GarrysMod::Lua::SPECIAL_GLOB );
	LUA->PushString( "TestFunction" );
	LUA->PushCFunction( MyExampleFunction );
	LUA->SetTable( -3 ); // `_G.TestFunction = MyExampleFunction`

	remix::lib::loadRemixDllAndInitialize(L"d3d9.dll");

	return 0;
}

GMOD_MODULE_CLOSE()
{
	return 0;
}