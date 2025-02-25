if not CLIENT then return end
require("niknaks")

-- ConVars
local CONVARS = {
    ENABLED = CreateClientConVar("rtx_force_render", "1", true, false, "Forces custom mesh rendering of map"),
    DEBUG = CreateClientConVar("rtx_force_render_debug", "0", true, false, "Shows debug info for mesh rendering"),
    CHUNK_SIZE = CreateClientConVar("rtx_chunk_size", "65536", true, false, "Size of chunks for mesh combining"),
    CAPTURE_MODE = CreateClientConVar("rtx_capture_mode", "0", true, false, "Toggles r_drawworld for capture mode")
}

-- Local Variables and Caches
local mapMeshes = {
    opaque = {},
    translucent = {},
}
local isEnabled = false
local renderStats = {draws = 0}
local materialCache = {}

-- Get native functions
local MeshRenderer = MeshRenderer or {}
local CreateOptimizedMeshBatch = MeshRenderer.CreateOptimizedMeshBatch or function() error("MeshRenderer module not loaded") end
local ProcessRegionBatch = MeshRenderer.ProcessRegionBatch or function() error("MeshRenderer module not loaded") end
local GenerateChunkKey = MeshRenderer.GenerateChunkKey or function(x, y, z) return x .. "," .. y .. "," .. z end
local CalculateEntityBounds = MeshRenderer.CalculateEntityBounds or function() error("MeshRenderer module not loaded") end
local FilterEntitiesByDistance = MeshRenderer.FilterEntitiesByDistance or function() error("MeshRenderer module not loaded") end

-- Helper functions
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
    
    -- First check if it's a brush model
    if face.__bmodel and face.__bmodel > 0 then
        return true -- Any non-zero bmodel index indicates it's a brush entity
    end
    
    -- Secondary check for brush entities using parent entity
    local parent = face.__parent
    if parent and isentity(parent) and parent:GetClass() then
        -- If the face has a valid parent entity, it's likely a brush entity
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
    
    local chunkSize = math.max(4096, math.min(65536, math.floor(1 / (totalFaces / (16384 * 16384 * 16384)) * 32768)))
    CONVARS.CHUNK_SIZE:SetInt(chunkSize)
    
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
            
            -- Calculate center
            local center = Vector(0, 0, 0)
            for _, vert in ipairs(vertices) do
                if vert then
                    center = center + vert
                end
            end
            center = center / #vertices
            
            local chunkX = math.floor(center.x / chunkSize)
            local chunkY = math.floor(center.y / chunkSize)
            local chunkZ = math.floor(center.z / chunkSize)
            local chunkKey = GenerateChunkKey(chunkX, chunkY, chunkZ)
            
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
            
            table.insert(chunkGroup[chunkKey][matName].faces, face)
        end
    end
    
    -- Create optimized meshes using our C++ function
    local function CreateMeshGroup(faces, material)
        if not faces or #faces == 0 or not material then return nil end
        
        -- Collect vertices for optimization
        local allVertices = {}
        local allNormals = {}
        local allUVs = {}
        
        for _, face in ipairs(faces) do
            local verts = face:GenerateVertexTriangleData()
            if verts then
                for _, vert in ipairs(verts) do
                    if ValidateVertex(vert.pos) then
                        table.insert(allVertices, vert.pos)
                        table.insert(allNormals, vert.normal)
                        table.insert(allUVs, Vector(vert.u or 0, vert.v or 0, 0))
                    end
                end
            end
        end
        
        -- Use native optimization
        local MAX_VERTICES = 10000
        local result = CreateOptimizedMeshBatch(allVertices, allNormals, allUVs, MAX_VERTICES)
        
        -- Create meshes from optimized data
        local meshes = {}
        local vertCount = #result.vertices
        local meshCount = math.ceil(vertCount / MAX_VERTICES)
        
        for i = 1, meshCount do
            local startIdx = (i-1) * MAX_VERTICES + 1
            local endIdx = math.min(i * MAX_VERTICES, vertCount)
            local vertexCount = endIdx - startIdx + 1
            
            if vertexCount <= 0 then continue end
            
            local newMesh = Mesh(material)
            mesh.Begin(newMesh, MATERIAL_TRIANGLES, vertexCount)
            
            for j = startIdx, endIdx do
                mesh.Position(result.vertices[j])
                mesh.Normal(result.normals[j])
                mesh.TexCoord(0, result.uvs[j].x, result.uvs[j].y)
                mesh.AdvanceVertex()
            end
            
            mesh.End()
            table.insert(meshes, newMesh)
        end
        
        return meshes
    end

    -- Create combined meshes
    for renderType, chunkGroup in pairs(chunks) do
        for chunkKey, materials in pairs(chunkGroup) do
            mapMeshes[renderType][chunkKey] = {}
            for matName, group in pairs(materials) do
                if group.faces and #group.faces > 0 then
                    local meshes = CreateMeshGroup(group.faces, group.material)
                    
                    if meshes and #meshes > 0 then
                        mapMeshes[renderType][chunkKey][matName] = {
                            meshes = meshes,
                            material = group.material
                        }
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
    
    -- Inline render state changes for speed
    if translucent then
        render.SetBlend(1)
        render.OverrideDepthEnable(true, true)
    end
    
    -- Get player position for culling
    local playerPos = LocalPlayer():GetPos()
    
    -- Regular faces
    local groups = translucent and mapMeshes.translucent or mapMeshes.opaque
    for chunkKey, chunkMaterials in pairs(groups) do
        -- Check if this chunk should be rendered using ProcessRegionBatch
        -- We'll collect all vertices from the first mesh of each material
        local shouldRender = true
        for _, group in pairs(chunkMaterials) do
            if group.meshes and #group.meshes > 0 then
                -- Just check if we're in render range (optimization)
                shouldRender = true
                break
            end
        end
        
        if shouldRender then
            for _, group in pairs(chunkMaterials) do
                if currentMaterial ~= group.material then
                    render.SetMaterial(group.material)
                    currentMaterial = group.material
                end
                
                local meshes = group.meshes
                for i = 1, #meshes do
                    meshes[i]:Draw()
                    draws = draws + 1
                end
            end
        end
    end
    
    if translucent then
        render.OverrideDepthEnable(false)
    end
    
    renderStats.draws = draws
end

-- Enable/Disable Functions
local function EnableCustomRendering()
    if isEnabled then return end
    isEnabled = true

    -- Disable world rendering
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
        if CONVARS.ENABLED:GetBool() then
            local success, err = pcall(EnableCustomRendering)
            if not success then
                ErrorNoHalt("[RTX Fixes] Failed to enable custom rendering: " .. tostring(err) .. "\n")
                DisableCustomRendering()
            end
        end
    end)
end

-- Hooks
hook.Add("PostCleanupMap", "RTXMeshRebuild", Initialize)

hook.Add("PostPlayerDraw", "RTXCustomWorld", function(ply)
    -- This hook is added to capture player view after player is drawn
    -- Helps maintain proper rendering order
end)

hook.Add("ShutDown", "RTXCustomWorld", function()
    DisableCustomRendering()
    
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
        translucent = {}
    }
    materialCache = {}
end)

-- Debug drawing
if CONVARS.DEBUG:GetBool() then
    hook.Add("HUDPaint", "RTXMeshDebug", function()
        draw.SimpleText("RTX Mesh Renderer", "BudgetLabel", 10, 10, Color(255, 255, 255))
        draw.SimpleText("Draws: " .. renderStats.draws, "BudgetLabel", 10, 25, Color(255, 255, 255))
        
        local opaque = 0
        local translucent = 0
        
        for _, materials in pairs(mapMeshes.opaque) do
            for _, group in pairs(materials) do
                if group.meshes then
                    opaque = opaque + #group.meshes
                end
            end
        end
        
        for _, materials in pairs(mapMeshes.translucent) do
            for _, group in pairs(materials) do
                if group.meshes then
                    translucent = translucent + #group.meshes
                end
            end
        end
        
        draw.SimpleText("Opaque Meshes: " .. opaque, "BudgetLabel", 10, 40, Color(255, 255, 255))
        draw.SimpleText("Translucent Meshes: " .. translucent, "BudgetLabel", 10, 55, Color(255, 255, 255))
        draw.SimpleText("Chunk Size: " .. CONVARS.CHUNK_SIZE:GetInt(), "BudgetLabel", 10, 70, Color(255, 255, 255))
    end)
end

-- ConVar Changes
cvars.AddChangeCallback("rtx_force_render", function(_, _, new)
    if tobool(new) then
        EnableCustomRendering()
    else
        DisableCustomRendering()
    end
end)

cvars.AddChangeCallback("rtx_capture_mode", function(_, _, new)
    -- Invert the value: if capture_mode is 1, r_drawworld should be 0 and vice versa
    RunConsoleCommand("r_drawworld", new == "1" and "0" or "1")
end)

cvars.AddChangeCallback("rtx_force_render_debug", function(_, _, new)
    if tobool(new) then
        hook.Add("HUDPaint", "RTXMeshDebug", function()
            draw.SimpleText("RTX Mesh Renderer", "BudgetLabel", 10, 10, Color(255, 255, 255))
            draw.SimpleText("Draws: " .. renderStats.draws, "BudgetLabel", 10, 25, Color(255, 255, 255))
            
            local opaque = 0
            local translucent = 0
            
            for _, materials in pairs(mapMeshes.opaque) do
                for _, group in pairs(materials) do
                    if group.meshes then
                        opaque = opaque + #group.meshes
                    end
                end
            end
            
            for _, materials in pairs(mapMeshes.translucent) do
                for _, group in pairs(materials) do
                    if group.meshes then
                        translucent = translucent + #group.meshes
                    end
                end
            end
            
            draw.SimpleText("Opaque Meshes: " .. opaque, "BudgetLabel", 10, 40, Color(255, 255, 255))
            draw.SimpleText("Translucent Meshes: " .. translucent, "BudgetLabel", 10, 55, Color(255, 255, 255))
            draw.SimpleText("Chunk Size: " .. CONVARS.CHUNK_SIZE:GetInt(), "BudgetLabel", 10, 70, Color(255, 255, 255))
        end)
    else
        hook.Remove("HUDPaint", "RTXMeshDebug")
    end
end)

-- Optional Optimization: Adaptive mesh rebuilding
local function ShouldRebuildMeshes()
    -- Check if map has changed or if settings requiring a rebuild have changed
    return false -- Default to not rebuilding constantly
end

hook.Add("Think", "RTXMeshRebuildCheck", function()
    if ShouldRebuildMeshes() then
        BuildMapMeshes()
    end
end)

-- Menu
hook.Add("PopulateToolMenu", "RTXCustomWorldMenu", function()
    spawnmenu.AddToolMenuOption("Utilities", "User", "RTX_ForceRender", "#RTX Custom World", "", "", function(panel)
        panel:ClearControls()
        
        panel:CheckBox("Enable Custom World Rendering", "rtx_force_render")
        panel:ControlHelp("Renders the world using chunked meshes")

        panel:CheckBox("Remix Capture Mode", "rtx_capture_mode")
        panel:ControlHelp("Enable this if you're taking a capture with RTX Remix")
        
        panel:CheckBox("Show Debug Info", "rtx_force_render_debug")
        panel:ControlHelp("Displays information about mesh rendering")
        
        panel:Button("Rebuild Meshes", "rtx_rebuild_meshes")
    end)
end)

-- Console Commands
concommand.Add("rtx_rebuild_meshes", function()
    BuildMapMeshes()
end)

-- Function to force reload resources when map changes or when requested
concommand.Add("rtx_reload_resources", function()
    if ClearRTXResources then
        ClearRTXResources()
        print("[RTX] Resources cleared")
    else
        print("[RTX] ClearRTXResources function not available")
    end
end)

-- Performance optimization: Prioritize mesh processing by distance
local function BuildPrioritizedChunks()
    local playerPos = LocalPlayer():GetPos()
    local chunkSize = CONVARS.CHUNK_SIZE:GetInt()
    
    -- Get current chunk
    local currentChunkX = math.floor(playerPos.x / chunkSize)
    local currentChunkY = math.floor(playerPos.y / chunkSize)
    local currentChunkZ = math.floor(playerPos.z / chunkSize)
    
    -- Prioritize nearby chunks first
    local nearbyChunks = {}
    for x = -1, 1 do
        for y = -1, 1 do
            for z = -1, 1 do
                local chunkKey = GenerateChunkKey(currentChunkX + x, currentChunkY + y, currentChunkZ + z)
                table.insert(nearbyChunks, chunkKey)
            end
        end
    end
    
    return nearbyChunks
end

-- Initial setup
if MeshRenderer then
    print("[RTX Mesh Renderer] Module loaded successfully")
else
    print("[RTX Mesh Renderer] WARNING: Native module not found, falling back to Lua implementation")
    -- Implement fallback functions here if needed
end