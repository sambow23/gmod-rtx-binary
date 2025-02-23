#include "rtx_light_manager.hpp"
#include <cstdint>

using namespace GarrysMod::Lua;

extern remix::Interface* g_remix;

// Static wrapper functions for Lua
LUA_FUNCTION(CreateSphereLight_Wrapper) {
  LUA->CheckType(1, Type::NUMBER); // x
  LUA->CheckType(2, Type::NUMBER); // y
  LUA->CheckType(3, Type::NUMBER); // z
  LUA->CheckType(4, Type::NUMBER); // radius
  LUA->CheckType(5, Type::NUMBER); // r
  LUA->CheckType(6, Type::NUMBER); // g
  LUA->CheckType(7, Type::NUMBER); // b
  LUA->CheckType(8, Type::NUMBER); // intensity

  uint64_t lightId = 0;
  bool success = RTXLightManager::Instance().CreateSphereLight(
    (float)LUA->GetNumber(1),
    (float)LUA->GetNumber(2),
    (float)LUA->GetNumber(3),
    (float)LUA->GetNumber(4),
    (float)LUA->GetNumber(5), 
    (float)LUA->GetNumber(6),
    (float)LUA->GetNumber(7),
    (float)LUA->GetNumber(8),
    lightId
  );

  if (success) {
    LUA->PushNumber(static_cast<double>(lightId));
  } else {
    LUA->PushNil();
  }
  return 1;
}

LUA_FUNCTION(CreateRectLight_Wrapper) {
  LUA->CheckType(1, Type::NUMBER); // x
  LUA->CheckType(2, Type::NUMBER); // y
  LUA->CheckType(3, Type::NUMBER); // z
  LUA->CheckType(4, Type::NUMBER); // xSize
  LUA->CheckType(5, Type::NUMBER); // ySize
  LUA->CheckType(6, Type::NUMBER); // r
  LUA->CheckType(7, Type::NUMBER); // g
  LUA->CheckType(8, Type::NUMBER); // b
  LUA->CheckType(9, Type::NUMBER); // intensity

  uint64_t lightId = 0;
  bool success = RTXLightManager::Instance().CreateRectLight(
    (float)LUA->GetNumber(1),
    (float)LUA->GetNumber(2),
    (float)LUA->GetNumber(3),
    (float)LUA->GetNumber(4),
    (float)LUA->GetNumber(5),
    (float)LUA->GetNumber(6),
    (float)LUA->GetNumber(7), 
    (float)LUA->GetNumber(8),
    (float)LUA->GetNumber(9),
    lightId
  );

  if (success) {
    LUA->PushNumber(static_cast<double>(lightId));
  } else {
    LUA->PushNil();
  }
  return 1;
}

LUA_FUNCTION(CreateDistantLight_Wrapper) {
  LUA->CheckType(1, Type::NUMBER); // dirX
  LUA->CheckType(2, Type::NUMBER); // dirY
  LUA->CheckType(3, Type::NUMBER); // dirZ
  LUA->CheckType(4, Type::NUMBER); // angularDiameter
  LUA->CheckType(5, Type::NUMBER); // r
  LUA->CheckType(6, Type::NUMBER); // g
  LUA->CheckType(7, Type::NUMBER); // b
  LUA->CheckType(8, Type::NUMBER); // intensity

  uint64_t lightId = 0;
  bool success = RTXLightManager::Instance().CreateDistantLight(
    (float)LUA->GetNumber(1),
    (float)LUA->GetNumber(2),
    (float)LUA->GetNumber(3),
    (float)LUA->GetNumber(4),
    (float)LUA->GetNumber(5),
    (float)LUA->GetNumber(6),
    (float)LUA->GetNumber(7),
    (float)LUA->GetNumber(8),
    lightId
  );

  if (success) {
    LUA->PushNumber(static_cast<double>(lightId));
  } else {
    LUA->PushNil();
  }
  return 1;
}

LUA_FUNCTION(RemoveLight_Wrapper) {
  LUA->CheckType(1, Type::NUMBER); // light handle

  bool success = RTXLightManager::Instance().RemoveLight((uint64_t)LUA->GetNumber(1));
  LUA->PushBool(success);
  return 1;
}

// Rest of the RTXLightManager implementation
bool RTXLightManager::Initialize() {
  return true;
}

void RTXLightManager::Cleanup() {
  for (const auto& [id, handle] : m_lights) {
    if (g_remix) {
      g_remix->DestroyLight(handle);
    }
  }
  m_lights.clear();
}

bool RTXLightManager::CreateSphereLight(float x, float y, float z, float radius,
                                      float r, float g, float b, float intensity,
                                      uint64_t& outLightId) {
  if (!g_remix) return false;

  remix::LightInfoSphereEXT sphereLight;
  sphereLight.position = {x, y, z};
  sphereLight.radius = radius;

  remix::LightInfo lightInfo;
  lightInfo.pNext = &sphereLight;
  lightInfo.hash = m_nextLightId++;
  lightInfo.radiance = {r * intensity, g * intensity, b * intensity};

  auto result = g_remix->CreateLight(lightInfo);
  if (result) {
    m_lights[lightInfo.hash] = result.value();
    outLightId = lightInfo.hash;
    return true;
  }
  return false;
}

bool RTXLightManager::CreateRectLight(float x, float y, float z,
                                    float xSize, float ySize,
                                    float r, float g, float b, float intensity,
                                    uint64_t& outLightId) {
  if (!g_remix) return false;

  remix::LightInfoRectEXT rectLight;
  rectLight.position = {x, y, z};
  rectLight.xSize = xSize;
  rectLight.ySize = ySize;
  rectLight.xAxis = {1, 0, 0};
  rectLight.yAxis = {0, 1, 0};
  rectLight.direction = {0, 0, 1};

  remix::LightInfo lightInfo;
  lightInfo.pNext = &rectLight;
  lightInfo.hash = m_nextLightId++;
  lightInfo.radiance = {r * intensity, g * intensity, b * intensity};

  auto result = g_remix->CreateLight(lightInfo);
  if (result) {
    m_lights[lightInfo.hash] = result.value();
    outLightId = lightInfo.hash;
    return true; 
  }
  return false;
}

bool RTXLightManager::CreateDistantLight(float dirX, float dirY, float dirZ,
                                       float angularDiameter,
                                       float r, float g, float b, float intensity,
                                       uint64_t& outLightId) {
  if (!g_remix) return false;

  remix::LightInfoDistantEXT distantLight;
  distantLight.direction = {dirX, dirY, dirZ};
  distantLight.angularDiameterDegrees = angularDiameter;

  remix::LightInfo lightInfo;
  lightInfo.pNext = &distantLight;
  lightInfo.hash = m_nextLightId++;
  lightInfo.radiance = {r * intensity, g * intensity, b * intensity};

  auto result = g_remix->CreateLight(lightInfo);
  if (result) {
    m_lights[lightInfo.hash] = result.value();
    outLightId = lightInfo.hash;
    return true;
  }
  return false;
}

bool RTXLightManager::RemoveLight(uint64_t handle) {
  auto it = m_lights.find(handle);
  if (it != m_lights.end() && g_remix) {
    g_remix->DestroyLight(it->second);
    m_lights.erase(it);
    return true;
  }
  return false;
}

void RTXLightManager::DrawLights() {
  if (!g_remix) return;
  
  for (const auto& [id, handle] : m_lights) {
    g_remix->DrawLightInstance(handle);
  }
}

void RTXLightManager::RegisterLuaFunctions(ILuaBase* LUA) {
  LUA->PushSpecial(SPECIAL_GLOB);

    LUA->PushCFunction(CreateSphereLight_Wrapper);
    LUA->SetField(-2, "CreateRTXSphereLight");

    LUA->PushCFunction(CreateRectLight_Wrapper);
    LUA->SetField(-2, "CreateRTXRectLight");

    LUA->PushCFunction(CreateDistantLight_Wrapper);
    LUA->SetField(-2, "CreateRTXDistantLight");

    LUA->PushCFunction(RemoveLight_Wrapper);
    LUA->SetField(-2, "RemoveRTXLight");

  LUA->Pop();
}