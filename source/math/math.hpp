#pragma once
#include "GarrysMod/Lua/Interface.h"
#include <cmath>
#include <algorithm>

namespace RTXMath {
    struct Vector3 {
        float x, y, z;
    };

    // Core math functions
    Vector3 LerpVector(float t, const Vector3& a, const Vector3& b);
    float DistToSqr(const Vector3& a, const Vector3& b);
    bool IsWithinBounds(const Vector3& point, const Vector3& mins, const Vector3& maxs);
    int64_t GenerateChunkKey(int x, int y, int z);
    Vector3 ComputeNormal(const Vector3& v1, const Vector3& v2, const Vector3& v3);

    // Initialize math module
    void Initialize(GarrysMod::Lua::ILuaBase* LUA);
}