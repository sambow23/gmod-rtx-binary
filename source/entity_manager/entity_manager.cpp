#include "entity_manager.hpp"
#include "mathlib/vector.h"
#include "mathlib/mathlib.h"
#include "vstdlib/random.h"
#include <algorithm>

using namespace GarrysMod::Lua;

namespace EntityManager {

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

void Initialize(ILuaBase* LUA) {
    LUA->CreateTable();

    LUA->PushCFunction(BatchUpdateEntityBounds_Native);
    LUA->SetField(-2, "BatchUpdateEntityBounds");

    LUA->PushCFunction(CalculateSpecialEntityBounds_Native);
    LUA->SetField(-2, "CalculateSpecialEntityBounds");

    LUA->PushCFunction(FilterEntitiesByDistance_Native);
    LUA->SetField(-2, "FilterEntitiesByDistance");

    LUA->SetField(-2, "EntityManager");
}

} // namespace EntityManager