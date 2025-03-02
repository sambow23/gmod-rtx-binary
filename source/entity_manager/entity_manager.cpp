#include "entity_manager.hpp"
#include "mathlib/vector.h"
#include "mathlib/mathlib.h"
#include "vstdlib/random.h"
#include <algorithm>
#include <sstream>

using namespace GarrysMod::Lua;

namespace EntityManager {

// Initialize static members
std::vector<Light> cachedLights;
std::random_device rd;
std::mt19937 rng(rd());
std::unordered_map<int, int> g_EntityRefs;
SpatialPartitioning::SpatialHashGrid* g_SpatialGrid = nullptr;

// Helper function to parse color string "r g b a"
Vector ParseColorString(const char* colorStr) {
    std::istringstream iss(colorStr);
    float r, g, b, a = 200.0f;
    
    iss >> r >> g >> b;
    if (!iss.eof()) {
        iss >> a;
    }

    // Scale by intensity similar to Lua version
    float scale = a / 60000.0f;
    return Vector(r * scale, g * scale, b * scale);
}

void ShuffleLights() {
    std::shuffle(cachedLights.begin(), cachedLights.end(), rng);
}

void GetRandomLights(int count, std::vector<Light>& outLights) {
    outLights.clear();
    if (cachedLights.empty() || count <= 0) return;

    // Shuffle the lights if we need to
    ShuffleLights();

    // Get up to count lights
    int numLights = std::min(static_cast<size_t>(count), cachedLights.size());
    outLights.insert(outLights.end(), cachedLights.begin(), cachedLights.begin() + numLights);
}

void AngleVectorsRadians(const QAngle& angles, Vector* forward, Vector* right, Vector* up) {
    float sr, sp, sy, cr, cp, cy;

    sp = sin(angles.x * M_PI / 180.0f);
    cp = cos(angles.x * M_PI / 180.0f);
    sy = sin(angles.y * M_PI / 180.0f);
    cy = cos(angles.y * M_PI / 180.0f);
    sr = sin(angles.z * M_PI / 180.0f);
    cr = cos(angles.z * M_PI / 180.0f);

    if (forward) {
        forward->x = cp * cy;
        forward->y = cp * sy;
        forward->z = -sp;
    }

    if (right) {
        right->x = (-1 * sr * sp * cy + -1 * cr * -sy);
        right->y = (-1 * sr * sp * sy + -1 * cr * cy);
        right->z = -1 * sr * cp;
    }

    if (up) {
        up->x = (cr * sp * cy + -sr * -sy);
        up->y = (cr * sp * sy + -sr * cy);
        up->z = cr * cp;
    }
}

BatchedMesh ProcessVerticesSIMD(const std::vector<Vector>& vertices,
                               const std::vector<Vector>& normals,
                               const std::vector<BatchedMesh::UV>& uvs,
                               uint32_t maxVertices) {
    BatchedMesh result;
    result.vertexCount = 0;
    
    // Pre-allocate with alignment
    const size_t vertCount = std::min(vertices.size(), static_cast<size_t>(maxVertices));
    result.positions.reserve(vertCount);
    result.normals.reserve(vertCount);
    result.uvs.reserve(vertCount);

    // Process in batches of 4 vertices (SSE)
    for (size_t i = 0; i < vertCount; i += 4) {
        __m128 positions[4];
        __m128 norms[4];
        __m128 uvCoords[4];
        
        // Load 4 vertices
        for (size_t j = 0; j < 4 && (i + j) < vertCount; j++) {
            const Vector& pos = vertices[i + j];
            positions[j] = _mm_set_ps(0.0f, pos.z, pos.y, pos.x);
            
            if (i + j < normals.size()) {
                const Vector& norm = normals[i + j];
                norms[j] = _mm_set_ps(0.0f, norm.z, norm.y, norm.x);
            }
            
            if (i + j < uvs.size()) {
                const BatchedMesh::UV& uv = uvs[i + j];
                uvCoords[j] = _mm_set_ps(0.0f, 0.0f, uv.v, uv.u);
            }
        }

        // Process 4 vertices in parallel
        for (size_t j = 0; j < 4 && (i + j) < vertCount; j++) {
            // Transform position
            float pos[4];
            _mm_store_ps(pos, positions[j]);
            result.positions.emplace_back(pos[0], pos[1], pos[2]);

            // Transform normal
            float norm[4];
            _mm_store_ps(norm, norms[j]);
            result.normals.emplace_back(norm[0], norm[1], norm[2]);

            // Store UV
            float uv[4];
            _mm_store_ps(uv, uvCoords[j]);
            result.uvs.push_back({uv[0], uv[1]});
            
            result.vertexCount++;
        }
    }

    return result;
}


LUA_FUNCTION(CreateOptimizedMeshBatch_Native) {
    LUA->CheckType(1, Type::TABLE);  // vertices
    LUA->CheckType(2, Type::TABLE);  // normals
    LUA->CheckType(3, Type::TABLE);  // uvs
    uint32_t maxVertices = LUA->CheckNumber(4);

    std::vector<Vector> vertices;
    std::vector<Vector> normals;
    std::vector<BatchedMesh::UV> uvs;

    // Parse vertices table
    LUA->PushNil();
    while (LUA->Next(1) != 0) {
        if (LUA->IsType(-1, Type::Vector)) {
            Vector* v = LUA->GetUserType<Vector>(-1, Type::Vector);
            vertices.push_back(*v);
        }
        LUA->Pop();
    }

    // Parse normals table
    LUA->PushNil();
    while (LUA->Next(2) != 0) {
        if (LUA->IsType(-1, Type::Vector)) {
            Vector* n = LUA->GetUserType<Vector>(-1, Type::Vector);
            normals.push_back(*n);
        }
        LUA->Pop();
    }

    // Parse UVs table
    LUA->PushNil();
    while (LUA->Next(3) != 0) {
        if (LUA->IsType(-1, Type::Vector)) {
            Vector* uv = LUA->GetUserType<Vector>(-1, Type::Vector);
            uvs.push_back({uv->x, uv->y});  // Only use x,y for UVs
        }
        LUA->Pop();
    }

    BatchedMesh result = CreateOptimizedMeshBatch(vertices, normals, uvs, maxVertices);

    // Create return table with the same structure as before
    LUA->CreateTable();
    
    // Add vertices
    LUA->CreateTable();
    for (size_t i = 0; i < result.positions.size(); i++) {
        LUA->PushNumber(i + 1);
        Vector* v = new Vector(result.positions[i]);
        LUA->PushUserType(v, Type::Vector);
        LUA->SetTable(-3);
    }
    LUA->SetField(-2, "vertices");

    // Add normals
    LUA->CreateTable();
    for (size_t i = 0; i < result.normals.size(); i++) {
        LUA->PushNumber(i + 1);
        Vector* n = new Vector(result.normals[i]);
        LUA->PushUserType(n, Type::Vector);
        LUA->SetTable(-3);
    }
    LUA->SetField(-2, "normals");

    // Add UVs
    LUA->CreateTable();
    for (size_t i = 0; i < result.uvs.size(); i++) {
        LUA->PushNumber(i + 1);
        Vector* uv = new Vector(result.uvs[i].u, result.uvs[i].v, 0);
        LUA->PushUserType(uv, Type::Vector);
        LUA->SetTable(-3);
    }
    LUA->SetField(-2, "uvs");

    return 1;
}

BatchedMesh CreateOptimizedMeshBatch(const std::vector<Vector>& vertices,
                                   const std::vector<Vector>& normals,
                                   const std::vector<BatchedMesh::UV>& uvs,
                                   uint32_t maxVertices) {
    return ProcessVerticesSIMD(vertices, normals, uvs, maxVertices);
}

LUA_FUNCTION(ProcessRegionBatch_Native) {
    LUA->CheckType(1, Type::TABLE);  // vertices
    LUA->CheckType(2, Type::Vector); // player position
    float threshold = LUA->CheckNumber(3);

    Vector* playerPos = LUA->GetUserType<Vector>(2, Type::Vector);
    std::vector<Vector> vertices;  // Changed to Source Vector

    // Parse vertices table
    LUA->PushNil();
    while (LUA->Next(1) != 0) {
        if (LUA->IsType(-1, Type::Vector)) {
            Vector* v = LUA->GetUserType<Vector>(-1, Type::Vector);
            vertices.push_back(*v);  // Copy the vector
        }
        LUA->Pop();
    }

    bool result = ProcessRegionBatch(vertices, *playerPos, threshold);
    LUA->PushBool(result);

    return 1;
}

BatchedMesh BatchedMesh::CombineBatchesSIMD(const std::vector<BatchedMesh>& meshes) {
    BatchedMesh combined;
    size_t totalVerts = 0;
    
    // Calculate total size
    for (const auto& mesh : meshes) {
        totalVerts += mesh.vertexCount;
    }
    
    // Pre-allocate
    combined.positions.reserve(totalVerts);
    combined.normals.reserve(totalVerts);
    combined.uvs.reserve(totalVerts);
    
    // Combine using SIMD for 4 vertices at a time
    std::vector<SIMDVertex, AlignedAllocator<SIMDVertex>> vertices;
    vertices.reserve(totalVerts);
    
    for (const auto& mesh : meshes) {
        for (size_t i = 0; i < mesh.vertexCount; i++) {
            SIMDVertex vert;
            vert.pos = _mm_set_ps(0.0f, 
                                 mesh.positions[i].z,
                                 mesh.positions[i].y, 
                                 mesh.positions[i].x);
            vert.norm = _mm_set_ps(0.0f,
                                  mesh.normals[i].z,
                                  mesh.normals[i].y,
                                  mesh.normals[i].x);
            vert.uv = _mm_set_ps(0.0f, 0.0f,
                                mesh.uvs[i].v,
                                mesh.uvs[i].u);
            vertices.push_back(vert);
        }
    }
    
    // Process combined vertices in batches of 4
    for (size_t i = 0; i < vertices.size(); i += 4) {
        __m128 positions[4];
        __m128 normals[4];
        __m128 uvs[4];
        
        // Load 4 vertices
        for (size_t j = 0; j < 4 && (i + j) < vertices.size(); j++) {
            positions[j] = vertices[i + j].pos;
            normals[j] = vertices[i + j].norm;
            uvs[j] = vertices[i + j].uv;
        }
        
        // Store processed vertices
        for (size_t j = 0; j < 4 && (i + j) < vertices.size(); j++) {
            float pos[4], norm[4], uv[4];
            _mm_store_ps(pos, positions[j]);
            _mm_store_ps(norm, normals[j]);
            _mm_store_ps(uv, uvs[j]);
            
            combined.positions.emplace_back(pos[0], pos[1], pos[2]);
            combined.normals.emplace_back(norm[0], norm[1], norm[2]);
            combined.uvs.push_back({uv[0], uv[1]});
            combined.vertexCount++;
        }
    }
    
    return combined;
}

bool ProcessRegionBatch(const std::vector<Vector>& vertices, 
                       const Vector& playerPos,
                       float threshold) {
    if (vertices.empty()) return false;

    // Calculate region bounds
    Vector mins(FLT_MAX, FLT_MAX, FLT_MAX);
    Vector maxs(-FLT_MAX, -FLT_MAX, -FLT_MAX);

    for (const auto& vertex : vertices) {
        mins.x = std::min(mins.x, vertex.x);
        mins.y = std::min(mins.y, vertex.y);
        mins.z = std::min(mins.z, vertex.z);
        maxs.x = std::max(maxs.x, vertex.x);
        maxs.y = std::max(maxs.y, vertex.y);
        maxs.z = std::max(maxs.z, vertex.z);
    }

    // Create expanded bounds
    Vector expandedMins(
        mins.x - threshold,
        mins.y - threshold,
        mins.z - threshold
    );
    
    Vector expandedMaxs(
        maxs.x + threshold,
        maxs.y + threshold,
        maxs.z + threshold
    );

    // Check if player is within expanded bounds
    return (playerPos.x >= expandedMins.x && playerPos.x <= expandedMaxs.x &&
            playerPos.y >= expandedMins.y && playerPos.y <= expandedMaxs.y &&
            playerPos.z >= expandedMins.z && playerPos.z <= expandedMaxs.z);
}

LUA_FUNCTION(CalculateSpecialEntityBounds_Native) {
    LUA->CheckType(1, Type::Entity);
    LUA->CheckNumber(2);  // size

    float size = LUA->GetNumber(2);

    // Get entity angles
    LUA->GetField(1, "GetAngles");
    LUA->Push(1);
    LUA->Call(1, 1);
    QAngle* angles = LUA->GetUserType<QAngle>(-1, Type::Angle);

    // Calculate forward, right, up vectors using our implementation
    Vector forward, right, up;
    AngleVectorsRadians(*angles, &forward, &right, &up);

    // Calculate bounds
    Vector scaledForward = forward * (size * 2);  // Double size in rotation direction
    Vector scaledRight = right * size;
    Vector scaledUp = up * size;

    Vector customMins(
        -std::abs(scaledForward.x) - std::abs(scaledRight.x) - std::abs(scaledUp.x),
        -std::abs(scaledForward.y) - std::abs(scaledRight.y) - std::abs(scaledUp.y),
        -std::abs(scaledForward.z) - std::abs(scaledRight.z) - std::abs(scaledUp.z)
    );

    Vector customMaxs(
        std::abs(scaledForward.x) + std::abs(scaledRight.x) + std::abs(scaledUp.x),
        std::abs(scaledForward.y) + std::abs(scaledRight.y) + std::abs(scaledUp.y),
        std::abs(scaledForward.z) + std::abs(scaledRight.z) + std::abs(scaledUp.z)
    );

    // Set the calculated bounds
    LUA->GetField(1, "SetRenderBounds");
    LUA->Push(1);
    LUA->PushVector(customMins);
    LUA->PushVector(customMaxs);
    LUA->Call(3, 0);

    LUA->Pop();  // Pop angles
    return 0;
}

LUA_FUNCTION(FilterEntitiesByDistance_Native) {
    LUA->CheckType(1, Type::TABLE);  // entities
    LUA->CheckType(2, Type::Vector);  // origin
    LUA->CheckNumber(3);  // maxDistance

    Vector* origin = LUA->GetUserType<Vector>(2, Type::Vector);
    float maxDistance = LUA->GetNumber(3);
    float maxDistSqr = maxDistance * maxDistance;

    // Create result table
    LUA->CreateTable();
    int resultTable = LUA->Top();
    int index = 1;

    // Iterate input table
    LUA->PushNil();
    while (LUA->Next(1) != 0) {
        if (LUA->IsType(-1, Type::Entity)) {
            // Get entity position
            LUA->GetField(-1, "GetPos");
            LUA->Push(-2);
            LUA->Call(1, 1);
            Vector* pos = LUA->GetUserType<Vector>(-1, Type::Vector);

            // Calculate distance
            float dx = pos->x - origin->x;
            float dy = pos->y - origin->y;
            float dz = pos->z - origin->z;
            float distSqr = dx*dx + dy*dy + dz*dz;

            if (distSqr <= maxDistSqr) {
                LUA->PushNumber(index++);
                LUA->Push(-2);  // Push the entity
                LUA->SetTable(resultTable);
            }

            LUA->Pop();  // Pop position
        }
        LUA->Pop();  // Pop value, keep key for next iteration
    }

    return 1;  // Return the filtered table
}

LUA_FUNCTION(BatchUpdateEntityBounds_Native) {
    LUA->CheckType(1, Type::TABLE);
    LUA->CheckType(2, Type::Vector);
    LUA->CheckType(3, Type::Vector);

    Vector* mins = LUA->GetUserType<Vector>(2, Type::Vector);
    Vector* maxs = LUA->GetUserType<Vector>(3, Type::Vector);

    RTXMath::Vector3 rtxMins = {mins->x, mins->y, mins->z};
    RTXMath::Vector3 rtxMaxs = {maxs->x, maxs->y, maxs->z};

    // Process entity table
    LUA->PushNil();
    while (LUA->Next(1) != 0) {
        if (LUA->IsType(-1, Type::Entity)) {
            // Get entity position
            LUA->GetField(-1, "GetPos");
            LUA->Push(-2);
            LUA->Call(1, 1);
            Vector* pos = LUA->GetUserType<Vector>(-1, Type::Vector);

            if (RTXMath::IsWithinBounds({pos->x, pos->y, pos->z}, rtxMins, rtxMaxs)) {
                // Set render bounds
                LUA->GetField(-2, "SetRenderBounds");
                LUA->Push(-3);
                LUA->Push(2);  // mins
                LUA->Push(3);  // maxs
                LUA->Call(3, 0);
            }

            LUA->Pop();  // Pop position
        }
        LUA->Pop();  // Pop value, keep key for next iteration
    }

    return 0;
}

LUA_FUNCTION(UpdateLightCache_Native) {
    LUA->CheckType(1, Type::TABLE); // lights table

    cachedLights.clear();
    
    // Iterate input table
    LUA->PushNil();
    while (LUA->Next(1) != 0) {
        if (LUA->IsType(-1, Type::Table)) {
            Light light = {};
            
            // Get class name to determine light type
            LUA->GetField(-1, "classname");
            const char* className = LUA->GetString(-1);
            LUA->Pop();

            // Skip spotlight and disabled lights
            if (strcmp(className, "point_spotlight") == 0) {
                LUA->Pop();
                continue;
            }

            // Check spawnflags
            LUA->GetField(-1, "spawnflags");
            int spawnFlags = LUA->GetNumber(-1);
            LUA->Pop();

            if (spawnFlags == 1) { // Light starts off
                LUA->Pop();
                continue;
            }

            // Set light type
            if (strcmp(className, "light") == 0) light.type = LIGHT_POINT;
            else if (strcmp(className, "light_environment") == 0) light.type = LIGHT_DIRECTIONAL;
            else if (strcmp(className, "light_spot") == 0) light.type = LIGHT_SPOT;
            else if (strcmp(className, "light_dynamic") == 0) light.type = LIGHT_POINT;
            else {
                LUA->Pop();
                continue;
            }

            // Get position
            LUA->GetField(-1, "origin");
            if (LUA->IsType(-1, Type::Vector)) {
                Vector* pos = LUA->GetUserType<Vector>(-1, Type::Vector);
                light.position = *pos;
            }
            LUA->Pop();

            // Get color
            LUA->GetField(-1, "_light");
            if (LUA->IsType(-1, Type::String)) {
                light.color = ParseColorString(LUA->GetString(-1));
            }
            LUA->Pop();

            // Get angles and direction
            LUA->GetField(-1, "angles");
            QAngle* angles = nullptr;
            if (LUA->IsType(-1, Type::Angle)) {
                angles = LUA->GetUserType<QAngle>(-1, Type::Angle);
            }
            LUA->Pop();

            LUA->GetField(-1, "pitch");
            float pitch = LUA->GetNumber(-1);
            LUA->Pop();

            // Calculate direction
            if (angles) {
                QAngle finalAngle;
                if (light.type == LIGHT_DIRECTIONAL) {
                    finalAngle.Init(pitch * -1, angles->y, angles->z); // Use y and z instead of r
                } else {
                    finalAngle.Init(angles->x != 0 ? pitch * -1 : -90, angles->y, angles->z);
                }

                Vector forward, right, up;
                AngleVectorsRadians(*angles, &forward, &right, &up);
                light.direction = forward;
            }

            // Get other properties
            LUA->GetField(-1, "_inner_cone");
            light.innerAngle = LUA->GetNumber(-1) * 2;  // Double the angle as per Lua
            LUA->Pop();

            LUA->GetField(-1, "_cone");
            light.outerAngle = LUA->GetNumber(-1) * 2;  // Double the angle as per Lua
            LUA->Pop();

            LUA->GetField(-1, "_exponent");
            light.angularFalloff = LUA->GetNumber(-1);
            LUA->Pop();

            LUA->GetField(-1, "_quadratic_attn");
            light.quadraticFalloff = LUA->GetNumber(-1);
            LUA->Pop();

            LUA->GetField(-1, "_linear_attn");
            light.linearFalloff = LUA->GetNumber(-1);
            LUA->Pop();

            LUA->GetField(-1, "_constant_attn");
            light.constantFalloff = LUA->GetNumber(-1);
            LUA->Pop();

            LUA->GetField(-1, "_fifty_percent_distance");
            light.fiftyPercentDistance = LUA->GetNumber(-1);
            LUA->Pop();

            LUA->GetField(-1, "_zero_percent_distance");
            light.zeroPercentDistance = LUA->GetNumber(-1);
            LUA->Pop();

            // Get range
            LUA->GetField(-1, "distance");
            light.range = LUA->GetNumber(-1);
            if (light.range <= 0) light.range = 512;
            LUA->Pop();

            // Set default angles if not specified
            if (light.innerAngle == 0) light.innerAngle = 30 * 2;
            if (light.outerAngle == 0) light.outerAngle = 45 * 2;

            // Special handling for environment lights
            if (light.type == LIGHT_DIRECTIONAL) {
                light.position = Vector(0, 0, 0);
            }

            cachedLights.push_back(light);
        }
        LUA->Pop();
    }

    return 0;
}

LUA_FUNCTION(GetRandomLights_Native) {
    LUA->CheckNumber(1); // count

    int count = (int)LUA->GetNumber(1);
    
    // Get random lights
    std::vector<Light> randomLights;
    GetRandomLights(count, randomLights);

    // Create result table
    LUA->CreateTable();

    // Convert to Lua table
    for (size_t i = 0; i < randomLights.size(); i++) {
        const Light& light = randomLights[i];

        LUA->PushNumber(i + 1);
        LUA->CreateTable();

        // Push all light properties
        int luaLightType;
        switch (light.type) {
            case LIGHT_POINT: luaLightType = 0; break;
            case LIGHT_SPOT: luaLightType = 1; break;
            case LIGHT_DIRECTIONAL: luaLightType = 2; break;
            default: luaLightType = 0; break;
        }
        LUA->PushNumber(luaLightType);
        LUA->SetField(-2, "type");

        LUA->PushVector(light.color);
        LUA->SetField(-2, "color");

        LUA->PushVector(light.position);
        LUA->SetField(-2, "pos");

        LUA->PushVector(light.direction);
        LUA->SetField(-2, "dir");

        LUA->PushNumber(light.range);
        LUA->SetField(-2, "range");

        LUA->PushNumber(light.innerAngle);
        LUA->SetField(-2, "innerAngle");

        LUA->PushNumber(light.outerAngle);
        LUA->SetField(-2, "outerAngle");

        LUA->PushNumber(light.angularFalloff);
        LUA->SetField(-2, "angularFalloff");

        LUA->PushNumber(light.quadraticFalloff);
        LUA->SetField(-2, "quadraticFalloff");

        LUA->PushNumber(light.linearFalloff);
        LUA->SetField(-2, "linearFalloff");

        LUA->PushNumber(light.constantFalloff);
        LUA->SetField(-2, "constantFalloff");

        if (light.fiftyPercentDistance > 0) {
            LUA->PushNumber(light.fiftyPercentDistance);
            LUA->SetField(-2, "fiftyPercentDistance");
        }

        if (light.zeroPercentDistance > 0) {
            LUA->PushNumber(light.zeroPercentDistance);
            LUA->SetField(-2, "zeroPercentDistance");
        }

        LUA->SetTable(-3);
    }

    return 1;
}

LUA_FUNCTION(RegisterEntityInGrid_Native) {
    if (!g_SpatialGrid) {
        Msg("[RTX Fixes] Warning: Spatial grid not initialized\n");
        return 0;
    }
    
    LUA->CheckType(1, Type::Entity);
    
    // Get entity position
    LUA->GetField(1, "GetPos");
    LUA->Push(1);
    LUA->Call(1, 1);
    Vector* pos = LUA->GetUserType<Vector>(-1, Type::Vector);
    
    // Get entity index for stable identification
    LUA->GetField(1, "EntIndex");
    LUA->Push(1);
    LUA->Call(1, 1);
    int entIndex = LUA->GetNumber(-1);
    LUA->Pop(); // Pop result
    
    // Create a persistent reference and store it
    int entityRef = LUA->ReferenceCreate();
    
    // Store the reference for later cleanup
    g_EntityRefs[entIndex] = entityRef;
    
    // Register in grid with the entity index as the key
    g_SpatialGrid->Insert(reinterpret_cast<void*>(static_cast<intptr_t>(entIndex)), *pos);
    
    LUA->Pop(); // Pop position vector
    Msg("[RTX Fixes] Registered entity %d in spatial grid\n", entIndex);
    return 0;
}

LUA_FUNCTION(UpdateEntityInGrid_Native) {
    if (!g_SpatialGrid) return 0;
    
    LUA->CheckType(1, Type::Entity);
    LUA->CheckType(2, Type::Vector); // old position
    LUA->CheckType(3, Type::Vector); // new position
    
    int entityRef = LUA->ReferenceCreate();
    Vector* oldPos = LUA->GetUserType<Vector>(2, Type::Vector);
    Vector* newPos = LUA->GetUserType<Vector>(3, Type::Vector);
    
    g_SpatialGrid->Update(reinterpret_cast<void*>(static_cast<intptr_t>(entityRef)), *oldPos, *newPos);
    
    // Free the reference after use
    LUA->ReferenceFree(entityRef);
    
    return 0;
}

LUA_FUNCTION(RemoveEntityFromGrid_Native) {
    if (!g_SpatialGrid) return 0;
    
    LUA->CheckType(1, Type::Entity);
    
    // Get entity position
    LUA->GetField(1, "GetPos");
    LUA->Push(1);
    LUA->Call(1, 1);
    Vector* pos = LUA->GetUserType<Vector>(-1, Type::Vector);
    
    // Get a reference to the entity
    int entityRef = LUA->ReferenceCreate(); // Create reference and get ID
    
    // Use the reference ID as our key (converted to void* for storage)
    g_SpatialGrid->Remove(reinterpret_cast<void*>(static_cast<intptr_t>(entityRef)), *pos);
    
    // Free the reference we just created
    LUA->ReferenceFree(entityRef);
    
    LUA->Pop(); // Pop position vector
    return 0;
}

LUA_FUNCTION(QueryEntitiesInRegion_Native) {
    if (!g_SpatialGrid) {
        LUA->CreateTable();
        return 1;
    }
    
    LUA->CheckType(1, Type::Vector); // mins
    LUA->CheckType(2, Type::Vector); // maxs
    
    Vector* mins = LUA->GetUserType<Vector>(1, Type::Vector);
    Vector* maxs = LUA->GetUserType<Vector>(2, Type::Vector);
    
    std::vector<void*> entities = g_SpatialGrid->Query(*mins, *maxs);
    
    // Create return table
    LUA->CreateTable();
    int tableIndex = LUA->Top();
    int resultIndex = 1;
    
    for (void* entityPtr : entities) {
        // Convert void* back to entity index
        int entIndex = static_cast<int>(reinterpret_cast<intptr_t>(entityPtr));
        
        // Find the reference for this entity index
        auto it = g_EntityRefs.find(entIndex);
        if (it != g_EntityRefs.end()) {
            LUA->PushNumber(resultIndex++);
            LUA->ReferencePush(it->second); // Push entity by reference
            LUA->SetTable(tableIndex);
        }
    }
    
    return 1;
}

LUA_FUNCTION(GetSpatialStats_Native) {
    if (!g_SpatialGrid) {
        LUA->PushNumber(0); // Total entities
        LUA->PushNumber(0); // Cell count
        return 2;
    }
    
    LUA->PushNumber(g_SpatialGrid->GetTotalEntities());
    LUA->PushNumber(g_SpatialGrid->GetCellCount());
    return 2;
}


void BatchProcessEntitiesInArea(GarrysMod::Lua::ILuaBase* LUA, const Vector& playerPos, float radius, bool useOriginal) {
    if (!g_SpatialGrid) return;
    
    Vector mins(playerPos.x - radius, playerPos.y - radius, playerPos.z - radius);
    Vector maxs(playerPos.x + radius, playerPos.y + radius, playerPos.z + radius);
    
    g_SpatialGrid->QueryCallback(mins, maxs, [LUA, useOriginal](void* entityRef) {
        // Convert void* back to reference ID
        int refID = static_cast<int>(reinterpret_cast<intptr_t>(entityRef));
        
        // Push entity to stack
        LUA->ReferencePush(refID);
        
        // Make sure it's an entity
        if (LUA->IsType(-1, GarrysMod::Lua::Type::Entity)) {
            // Call Lua's SetEntityBounds function
            LUA->GetField(GarrysMod::Lua::INDEX_GLOBAL, "SetEntityBounds");
            
            if (LUA->IsType(-1, GarrysMod::Lua::Type::Function)) {
                LUA->Push(-2); // Push entity again
                LUA->PushBool(useOriginal);
                LUA->Call(2, 0); // Call SetEntityBounds(entity, useOriginal)
            }
            else {
                LUA->Pop(); // Pop whatever was on top if not a function
            }
        }
        
        LUA->Pop(); // Pop the entity
    });
}

LUA_FUNCTION(BatchProcessEntitiesInArea_Native) {
    LUA->CheckType(1, Type::Vector); // playerPos
    float radius = LUA->CheckNumber(2);
    bool useOriginal = LUA->GetBool(3);
    
    Vector* playerPos = LUA->GetUserType<Vector>(1, Type::Vector);
    BatchProcessEntitiesInArea(LUA, *playerPos, radius, useOriginal);
    
    return 0;
}

LUA_FUNCTION(InitSpatialGrid_Native) {
    float cellSize = 1024.0f;
    if (LUA->IsType(1, Type::NUMBER)) {
        cellSize = LUA->GetNumber(1);
    }
    
    if (g_SpatialGrid) {
        delete g_SpatialGrid;
        g_SpatialGrid = nullptr;
        Msg("[RTX Fixes] Existing spatial grid deleted\n");
    }
    
    g_SpatialGrid = new SpatialPartitioning::SpatialHashGrid(cellSize);
    Msg("[RTX Fixes] Spatial grid explicitly initialized with cell size %.1f\n", cellSize);
    
    LUA->PushBool(true);
    return 1;
}

void Initialize(ILuaBase* LUA) {
    LUA->CreateTable();

    if (!g_SpatialGrid) {
        g_SpatialGrid = new SpatialPartitioning::SpatialHashGrid(1024.0f);
        Msg("[RTX Fixes] Spatial grid initialized with cell size 1024.0f\n");
    }

    // Add existing functions
    LUA->PushCFunction(BatchUpdateEntityBounds_Native);
    LUA->SetField(-2, "BatchUpdateEntityBounds");

    LUA->PushCFunction(CalculateSpecialEntityBounds_Native);
    LUA->SetField(-2, "CalculateSpecialEntityBounds");

    LUA->PushCFunction(FilterEntitiesByDistance_Native);
    LUA->SetField(-2, "FilterEntitiesByDistance");

    LUA->PushCFunction(UpdateLightCache_Native);
    LUA->SetField(-2, "UpdateLightCache");

    LUA->PushCFunction(GetRandomLights_Native);
    LUA->SetField(-2, "GetRandomLights");

    LUA->PushCFunction(CreateOptimizedMeshBatch_Native);
    LUA->SetField(-2, "CreateOptimizedMeshBatch");

    LUA->PushCFunction(ProcessRegionBatch_Native);
    LUA->SetField(-2, "ProcessRegionBatch");

    LUA->PushCFunction(RegisterEntityInGrid_Native);
    LUA->SetField(-2, "RegisterEntityInGrid");
    
    LUA->PushCFunction(UpdateEntityInGrid_Native);
    LUA->SetField(-2, "UpdateEntityInGrid");
    
    LUA->PushCFunction(RemoveEntityFromGrid_Native);
    LUA->SetField(-2, "RemoveEntityFromGrid");
    
    LUA->PushCFunction(QueryEntitiesInRegion_Native);
    LUA->SetField(-2, "QueryEntitiesInRegion");
    
    LUA->PushCFunction(GetSpatialStats_Native);
    LUA->SetField(-2, "GetSpatialStats");

    LUA->PushCFunction(BatchProcessEntitiesInArea_Native);
    LUA->SetField(-2, "BatchProcessEntitiesInArea");

    LUA->PushCFunction(InitSpatialGrid_Native);
    LUA->SetField(-2, "InitSpatialGrid");

    LUA->SetField(-2, "EntityManager");
}

} // namespace EntityManager