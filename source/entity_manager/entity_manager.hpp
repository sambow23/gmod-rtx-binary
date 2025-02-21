#pragma once
#include "GarrysMod/Lua/Interface.h"
#include "math/math.hpp"
#include <unordered_map>

namespace EntityManager {
    // Core functions for computationally intensive operations
    void BatchUpdateEntityBounds(GarrysMod::Lua::ILuaBase* LUA, const RTXMath::Vector3& mins, const RTXMath::Vector3& maxs);
    void CalculateSpecialEntityBounds(GarrysMod::Lua::ILuaBase* LUA, int entityIndex, float size);
    void FilterEntitiesByDistance(GarrysMod::Lua::ILuaBase* LUA, const RTXMath::Vector3& origin, float maxDistance);

    // Initialize entity manager
    void Initialize(GarrysMod::Lua::ILuaBase* LUA);
}