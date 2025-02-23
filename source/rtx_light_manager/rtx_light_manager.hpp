#pragma once

#include <remix/remix.h>
#include <map>
#include <memory>
#include "GarrysMod/Lua/Interface.h"

class RTXLightManager {
public:
  static RTXLightManager& Instance() {
    static RTXLightManager instance;
    return instance;
  }

  bool Initialize();
  void Cleanup();

  // Light management
  bool CreateSphereLight(float x, float y, float z, float radius, 
                        float r, float g, float b, float intensity,
                        uint64_t& outLightId);
  bool CreateRectLight(float x, float y, float z,
                      float xSize, float ySize,
                      float r, float g, float b, float intensity,
                      uint64_t& outLightId);
  bool CreateDistantLight(float dirX, float dirY, float dirZ,
                         float angularDiameter,
                         float r, float g, float b, float intensity,
                         uint64_t& outLightId);
  
  bool RemoveLight(uint64_t handle);
  void DrawLights();
  bool HasActiveLights() const { return !m_lights.empty(); }

  // Lua bindings
  static void RegisterLuaFunctions(GarrysMod::Lua::ILuaBase* LUA);

private:
  RTXLightManager() = default;
  std::map<uint64_t, remixapi_LightHandle> m_lights;
  uint64_t m_nextLightId = 1;
};