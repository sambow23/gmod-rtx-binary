-- Disables source engine world rendering and replaces it with chunked mesh rendering instead, fixes engine culling issues. 
if not CLIENT then return end
require("niknaks")

-- Local Variables and Caches
local mapMeshes = {
    opaque = {},
    translucent = {},
}
local isEnabled = false
local materialCache = {}
local Vector = Vector
local math_min = math.min
local math_max = math.max
local math_huge = math.huge
local math_floor = math.floor
local table_insert = table.insert
local MAX_VERTICES = 10000
local MAX_CHUNK_VERTS = 32768

-- Pre-allocate common vectors and tables for reuse
local vertexBuffer = {
    positions = {},
    normals = {},
    uvs = {}
}

local function ValidateVertex(pos)
    if not pos or 
       not pos.x or not pos.y or not pos.z or
       pos.x ~= pos.x or pos.y ~= pos.y or pos.z ~= pos.z or -- NaN check
       math.abs(pos.x) > 16384 or 
       math.abs(pos.y) > 16384 or 
       math.abs(pos.z) > 16384 then
        return false
    end
    return true
end

local function IsBrushEntity(face)
    if not face then return false end
    
    if face.__bmodel and face.__bmodel > 0 then
        return true
    end
    
    local parent = face.__parent
    if parent and isentity(parent) and parent:GetClass() then
        return true
    end
    
    return false
end

local function IsSkyboxFace(face)
    if not face then return false end
    
    local material = face:GetMaterial()
    if not material then return false end
    
    local matName = material:GetName():lower()
    
    return matName:find("tools/toolsskybox") or
           matName:find("skybox/") or
           matName:find("sky_") or
           false
end

local function GetChunkKey(x, y, z)
    return x .. "," .. y .. "," .. z
end

-- Main Mesh Building Function
local function BuildMapMeshes()
    -- Clean up existing meshes first
    for renderType, chunks in pairs(mapMeshes) do
        for chunkKey, materials in pairs(chunks) do
            for matName, group in pairs(materials) do
                if group.meshes then
                    for _, mesh in ipairs(group.meshes) do
                        if mesh and mesh.Destroy then
                            mesh:Destroy()
                        end
                    end
                end
            end
        end
    end

    mapMeshes = {
        opaque = {},
        translucent = {},
    }
    materialCache = {}
    
    if not NikNaks or not NikNaks.CurrentMap then return end

    print("[RTX Fixes] Building chunked meshes...")
    local startTime = SysTime()
    
    -- Count total faces for chunk size optimization
    local totalFaces = 0
    for _, leaf in pairs(NikNaks.CurrentMap:GetLeafs()) do
        if not leaf or leaf:IsOutsideMap() then continue end
        local leafFaces = leaf:GetFaces(true)
        if leafFaces then
            totalFaces = totalFaces + #leafFaces
        end
    end
    
    local chunkSize = RTX.Shared.DetermineOptimalChunkSize(totalFaces)
    RTX.ConVars.CHUNK_SIZE:SetInt(chunkSize)
    
    local chunks = {
        opaque = {},
        translucent = {},
    }
    
    -- Sort faces into chunks
    for _, leaf in pairs(NikNaks.CurrentMap:GetLeafs()) do  
        if not leaf or leaf:IsOutsideMap() then continue end
        
        local leafFaces = leaf:GetFaces(true)
        if not leafFaces then continue end
    
        for _, face in pairs(leafFaces) do
            if not face or 
               face:IsDisplacement() or
               IsBrushEntity(face) or
               not face:ShouldRender() or 
               IsSkyboxFace(face) then 
                continue 
            end
            
            local vertices = face:GetVertexs()
            if not vertices or #vertices == 0 then continue end
            
            local center = Vector(0, 0, 0)
            for _, vert in ipairs(vertices) do
                if not vert then continue end
                center:Add(vert)
            end
            center:Div(#vertices)
            
            local chunkX = math_floor(center.x / chunkSize)
            local chunkY = math_floor(center.y / chunkSize)
            local chunkZ = math_floor(center.z / chunkSize)
            local chunkKey = GetChunkKey(chunkX, chunkY, chunkZ)
            
            local material = face:GetMaterial()
            if not material then continue end
            
            local matName = material:GetName()
            if not matName then continue end
            
            if not materialCache[matName] then
                materialCache[matName] = material
            end
            
            local chunkGroup = face:IsTranslucent() and chunks.translucent or chunks.opaque
            
            chunkGroup[chunkKey] = chunkGroup[chunkKey] or {}
            chunkGroup[chunkKey][matName] = chunkGroup[chunkKey][matName] or {
                material = materialCache[matName],
                faces = {}
            }
            
            table_insert(chunkGroup[chunkKey][matName].faces, face)
        end
    end
    
    -- Create combined meshes
    for renderType, chunkGroup in pairs(chunks) do
        for chunkKey, materials in pairs(chunkGroup) do
            mapMeshes[renderType][chunkKey] = {}
            for matName, group in pairs(materials) do
                if group.faces and #group.faces > 0 then
                    local vertices = RTX.Shared.GenerateVerticesForFaces(group.faces)
                    if vertices then
                        local meshes = RTX.Shared.CreateMeshBatch(vertices, group.material, MAX_VERTICES)
                        
                        if meshes then
                            mapMeshes[renderType][chunkKey][matName] = {
                                meshes = meshes,
                                material = group.material
                            }
                        end
                    end
                end
            end
        end
    end

    print(string.format("[RTX Fixes] Built chunked meshes in %.2f seconds", SysTime() - startTime))
end

-- Rendering Functions
local function RenderCustomWorld(translucent)
    if not isEnabled then return end

    local draws = 0
    local currentMaterial = nil
    
    if translucent then
        render.SetBlend(1)
        render.OverrideDepthEnable(true, true)
    end
    
    -- Regular faces
    local groups = translucent and mapMeshes.translucent or mapMeshes.opaque
    for _, chunkMaterials in pairs(groups) do
        for _, group in pairs(chunkMaterials) do
            if currentMaterial ~= group.material then
                render.SetMaterial(group.material)
                currentMaterial = group.material
            end
            for _, meshObj in ipairs(group.meshes) do
                meshObj:Draw()
                draws = draws + 1
            end
        end
    end
    
    if translucent then
        render.OverrideDepthEnable(false)
    end
    
    RTX.Shared.RenderStats.worldDraws = draws
end

-- Enable/Disable Functions
local function EnableCustomRendering()
    if isEnabled then return end
    isEnabled = true

    hook.Add("PreDrawWorld", "RTXHideWorld", function()
        render.OverrideDepthEnable(true, false)
        return true
    end)
    
    hook.Add("PostDrawWorld", "RTXHideWorld", function()
        render.OverrideDepthEnable(false)
    end)
    
    hook.Add("PreDrawOpaqueRenderables", "RTXCustomWorld", function()
        RenderCustomWorld(false)
    end)
    
    hook.Add("PreDrawTranslucentRenderables", "RTXCustomWorld", function()
        RenderCustomWorld(true)
    end)
end

local function DisableCustomRendering()
    if not isEnabled then return end
    isEnabled = false

    hook.Remove("PreDrawWorld", "RTXHideWorld")
    hook.Remove("PostDrawWorld", "RTXHideWorld")
    hook.Remove("PreDrawOpaqueRenderables", "RTXCustomWorld")
    hook.Remove("PreDrawTranslucentRenderables", "RTXCustomWorld")
end

-- Initialization and Cleanup
local function Initialize()
    local success, err = pcall(BuildMapMeshes)
    if not success then
        ErrorNoHalt("[RTX Fixes] Failed to build meshes: " .. tostring(err) .. "\n")
        DisableCustomRendering()
        return
    end
    
    timer.Simple(1, function()
        if RTX.ConVars.ENABLED:GetBool() then
            local success, err = pcall(EnableCustomRendering)
            if not success then
                ErrorNoHalt("[RTX Fixes] Failed to enable custom rendering: " .. tostring(err) .. "\n")
                DisableCustomRendering()
            end
        end
    end)
end

-- Hooks
hook.Add("InitPostEntity", "RTXMeshInit", Initialize)
hook.Add("PostCleanupMap", "RTXMeshRebuild", Initialize)

hook.Add("PreDrawParticles", "ParticleSkipper", function()
    return true
end)

hook.Add("ShutDown", "RTXCustomWorld", function()
    DisableCustomRendering()
    
    for renderType, chunks in pairs(mapMeshes) do
        for chunkKey, materials in pairs(chunks) do
            for matName, group in pairs(materials) do
                if group.meshes then
                    for _, mesh in ipairs(group.meshes) do
                        if mesh.Destroy then
                            mesh:Destroy()
                        end
                    end
                end
            end
        end
    end
    
    mapMeshes = {
        opaque = {},
        translucent = {}
    }
    materialCache = {}
end)

-- ConVar Changes
cvars.AddChangeCallback("rtx_force_render", function(_, _, new)
    if tobool(new) then
        EnableCustomRendering()
    else
        DisableCustomRendering()
    end
end)

cvars.AddChangeCallback("rtx_capture_mode", function(_, _, new)
    RunConsoleCommand("r_drawworld", new == "1" and "0" or "1")
end)