#pragma once
#include "GarrysMod/Lua/Interface.h"
#include "math/math.hpp"
#include "mathlib/vector.h"
#include <unordered_map>
#include <vector>
#include <random>

namespace EntityManager {
    // Light type definitions
    enum LightType {
        LIGHT_POINT = 0,
        LIGHT_SPOT = 1,
        LIGHT_DIRECTIONAL = 2
    };

    struct BatchedMesh {
        std::vector<Vector> positions;  // Changed to Source's Vector
        std::vector<Vector> normals;    // Changed to Source's Vector
        struct UV {                     // Added UV struct
            float u, v;
        };
        std::vector<UV> uvs;           // Changed to UV struct
        uint32_t vertexCount;
    };

    // Light structure definition
    struct Light {
        Vector position;
        Vector color;
        Vector direction;
        float range;
        float innerAngle;
        float outerAngle;
        LightType type;
        float quadraticFalloff;
        float linearFalloff;
        float constantFalloff;
        float fiftyPercentDistance;
        float zeroPercentDistance;
        float angularFalloff;
    };

    // Static storage
    extern std::vector<Light> cachedLights;
    extern std::random_device rd;
    extern std::mt19937 rng;

    // Helper functions
    void ShuffleLights();
    void GetRandomLights(int count, std::vector<Light>& outLights);

    BatchedMesh CreateOptimizedMeshBatch(const std::vector<Vector>& vertices, 
                                       const std::vector<Vector>& normals,
                                       const std::vector<BatchedMesh::UV>& uvs,
                                       uint32_t maxVertices);

    bool ProcessRegionBatch(const std::vector<Vector>& vertices, 
                        const Vector& playerPos,
                        float threshold);

    // Initialize entity manager
    void Initialize(GarrysMod::Lua::ILuaBase* LUA);
}