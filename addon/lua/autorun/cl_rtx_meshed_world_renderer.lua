-- Disables source engine world rendering and replaces it with chunked mesh rendering instead, fixes engine culling issues. 
-- MAJOR THANK YOU to the creator of NikNaks, a lot of this would not be possible without it.
if not CLIENT then return end
require("niknaks")

-- ConVars
local CONVARS = {
    ENABLED = CreateClientConVar("rtx_force_render", "1", true, false, "Forces custom mesh rendering of map"),
    DEBUG = CreateClientConVar("rtx_force_render_debug", "0", true, false, "Shows debug info for mesh rendering"),
    CHUNK_SIZE = CreateClientConVar("rtx_chunk_size", "8196", true, false, "Size of chunks for mesh combining")
}

local MAX_MESH_VERTICES = 10000 -- Source engine mesh vertex limit

-- Local Variables and Caches
local mapMeshes = {}
local isEnabled = false
local renderStats = {draws = 0}
local materialCache = {}
local Vector = Vector
local math_min = math.min
local math_max = math.max
local math_huge = math.huge
local math_floor = math.floor
local table_insert = table.insert
local LocalToWorld = LocalToWorld
local angle_zero = Angle(0,0,0)
local vector_origin = Vector(0,0,0)
local MAX_VERTICES = 10000
local EyePos = EyePos

-- Utility Functions

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

local function GetChunkKey(x, y, z)
    return x .. "," .. y .. "," .. z
end

local function GetDisplacementBounds(face)
    if face._bounds then return face._bounds.mins, face._bounds.maxs end
    
    local verts = face:GenerateVertexTriangleData()
    if not verts or #verts == 0 then return vector_origin, vector_origin end
    
    local mins = Vector(math_huge, math_huge, math_huge)
    local maxs = Vector(-math_huge, -math_huge, -math_huge)
    
    for _, vert in ipairs(verts) do
        local pos = vert.pos
        mins.x = math_min(mins.x, pos.x)
        mins.y = math_min(mins.y, pos.y)
        mins.z = math_min(mins.z, pos.z)
        maxs.x = math_max(maxs.x, pos.x)
        maxs.y = math_max(maxs.y, pos.y)
        maxs.z = math_max(maxs.z, pos.z)
    end
    
    -- Cache the bounds
    face._bounds = {mins = mins, maxs = maxs}
    return mins, maxs
end

-- Main Mesh Building Function
local function BuildMapMeshes()
    mapMeshes = {
        opaque = {},
        translucent = {},
        displacements = {} -- New category for displacements
    }
    materialCache = {}
    
    if not NikNaks or not NikNaks.CurrentMap then return end

    print("[RTX Fixes] Building chunked meshes...")
    local startTime = SysTime()
    local totalVertCount = 0
    
    local chunkSize = CONVARS.CHUNK_SIZE:GetInt()
    local chunks = {
        opaque = {},
        translucent = {},
        displacements = {} -- New category for displacements
    }
    
    -- Sort faces into chunks
    for _, leaf in pairs(NikNaks.CurrentMap:GetLeafs()) do  
        if not leaf or leaf:IsOutsideMap() then continue end
        
        local leafFaces = leaf:GetFaces(true)
        if not leafFaces then continue end
    
        for _, face in pairs(leafFaces) do
            -- Add brush entity check early in the conditions
            if not face or 
               IsBrushEntity(face) or -- Move this check earlier
               not face:ShouldRender() or 
               IsSkyboxFace(face) then 
                continue 
            end
            
            -- Skip processing if no vertices
            local vertices = face:GetVertexs()
            if not vertices or #vertices == 0 then continue end
            
            -- Calculate face center
            local center = Vector(0, 0, 0)
            for _, vert in ipairs(vertices) do
                if not vert then continue end
                center = center + vert
            end
            center = center / #vertices
            
            -- Get chunk coordinates
            local chunkX = math.floor(center.x / chunkSize)
            local chunkY = math.floor(center.y / chunkSize)
            local chunkZ = math.floor(center.z / chunkSize)
            local chunkKey = GetChunkKey(chunkX, chunkY, chunkZ)
            
            local material = face:GetMaterial()
            if not material then continue end
            
            local matName = material:GetName()
            if not matName then continue end
            
            -- Cache material
            if not materialCache[matName] then
                materialCache[matName] = material
            end
            
            -- Determine which chunk group to use
            local chunkGroup
            if face:IsDisplacement() then
                chunkGroup = chunks.displacements
            else
                chunkGroup = face:IsTranslucent() and chunks.translucent or chunks.opaque
            end
            
            chunkGroup[chunkKey] = chunkGroup[chunkKey] or {}
            chunkGroup[chunkKey][matName] = chunkGroup[chunkKey][matName] or {
                material = materialCache[matName],
                faces = {},
                isDisplacement = face:IsDisplacement()
            }
            
            table.insert(chunkGroup[chunkKey][matName].faces, face)
        end
    end
    
    -- Create separate mesh creation functions for regular faces and displacements
    local function CreateRegularMeshGroup(faces, material)
        if not faces or #faces == 0 or not material then return nil end
        
        local meshGroups = {}
        local allVertices = {}
        local totalVertices = 0
        
        -- Collect vertex data
        for _, face in ipairs(faces) do
            local verts = face:GenerateVertexTriangleData()
            if verts then
                for _, vert in ipairs(verts) do
                    if vert.pos and vert.normal then
                        totalVertices = totalVertices + 1
                        table.insert(allVertices, vert)
                    end
                end
            end
        end
        
        if CONVARS.DEBUG:GetBool() then
            print(string.format("[RTX Fixes] Processing chunk with %d total vertices", totalVertices))
        end
        
        -- Create mesh batches
        local vertexIndex = 1
        while vertexIndex <= #allVertices do
            local remainingVerts = #allVertices - vertexIndex + 1
            local vertsThisMesh = math.min(MAX_MESH_VERTICES, remainingVerts)
            
            if vertsThisMesh > 0 then
                if CONVARS.DEBUG:GetBool() then
                    print(string.format("[RTX Fixes] Creating mesh with %d vertices", vertsThisMesh))
                end
                
                local newMesh = Mesh(material)
                mesh.Begin(newMesh, MATERIAL_TRIANGLES, vertsThisMesh)
                
                for i = 0, vertsThisMesh - 1 do
                    local vert = allVertices[vertexIndex + i]
                    mesh.Position(vert.pos)
                    mesh.Normal(vert.normal)
                    mesh.TexCoord(0, vert.u or 0, vert.v or 0)
                    mesh.AdvanceVertex()
                end
                
                mesh.End()
                table.insert(meshGroups, newMesh)
            end
            
            vertexIndex = vertexIndex + vertsThisMesh
        end
        
        return meshGroups
    end

    local function CreateDisplacementMeshGroup(faces, material)
        if not faces or #faces == 0 or not material then return nil end
        
        -- Preallocate tables
        local meshGroups = {}
        local currentVertices = {} -- Changed from table.Create()
        local currentSize = 0      -- Track size manually
        
        -- Sort faces by distance (only when needed)
        local camPos = EyePos()
        local sortedFaces = faces
        if #faces > 1 then
            sortedFaces = table.Copy(faces)
            table.sort(sortedFaces, function(a, b)
                local aMin, aMax = GetDisplacementBounds(a)
                local bMin, bMax = GetDisplacementBounds(b)
                local aDist = ((aMin + aMax) * 0.5):DistToSqr(camPos)
                local bDist = ((bMin + bMax) * 0.5):DistToSqr(camPos)
                return aDist > bDist
            end)
        end
        
        -- Process faces with optimized batching
        local function FlushCurrentBatch()
            if currentSize > 0 then
                local newMesh = Mesh(material)
                mesh.Begin(newMesh, MATERIAL_TRIANGLES, currentSize)
                
                for i = 1, currentSize do
                    local vert = currentVertices[i]
                    mesh.Position(vert.pos)
                    mesh.Normal(vert.normal)
                    mesh.TexCoord(0, vert.u, vert.v)
                    mesh.AdvanceVertex()
                end
                
                mesh.End()
                table_insert(meshGroups, newMesh)
                
                -- Clear batch
                currentVertices = {}
                currentSize = 0
            end
        end
        
        -- Process vertices with minimal table operations
        for _, face in ipairs(sortedFaces) do
            local verts = face:GenerateVertexTriangleData()
            if not verts then continue end
            
            if currentSize + #verts > MAX_VERTICES then
                FlushCurrentBatch()
            end
            
            local bmodel = face.__bmodel
            if bmodel > 0 then
                local func_brush = face.__map:GetEntities()[bmodel]
                if func_brush then
                    local origin = func_brush.origin
                    local angles = func_brush.angles
                    
                    for _, vert in ipairs(verts) do
                        if vert.pos and vert.normal then
                            currentSize = currentSize + 1
                            local finalPos = Vector(vert.pos)
                            local finalNormal = Vector(vert.normal)
                            
                            if origin then
                                finalPos:Add(origin)
                            end
                            if angles then
                                finalPos = LocalToWorld(finalPos, angle_zero, vector_origin, angles)
                                finalNormal = angles:Forward() * finalNormal.x + 
                                            angles:Right() * finalNormal.y + 
                                            angles:Up() * finalNormal.z
                            end
                            
                            currentVertices[currentSize] = {
                                pos = finalPos,
                                normal = finalNormal,
                                u = vert.u,
                                v = vert.v
                            }
                        end
                    end
                end
            else
                for _, vert in ipairs(verts) do
                    if vert.pos and vert.normal then
                        currentSize = currentSize + 1
                        currentVertices[currentSize] = vert
                    end
                end
            end
        end
        
        FlushCurrentBatch()
        return meshGroups
    end
    
    -- Create combined meshes with separate handling
    for renderType, chunkGroup in pairs(chunks) do
        for chunkKey, materials in pairs(chunkGroup) do
            mapMeshes[renderType][chunkKey] = {}
            for matName, group in pairs(materials) do
                if group.faces and #group.faces > 0 then
                    local meshes
                    if renderType == "displacements" then
                        meshes = CreateDisplacementMeshGroup(group.faces, group.material)
                    else
                        meshes = CreateRegularMeshGroup(group.faces, group.material)
                    end
                    
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
    
    -- Regular faces
    local groups = translucent and mapMeshes.translucent or mapMeshes.opaque
    for _, chunkMaterials in pairs(groups) do
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
    
    -- Displacements
    if not translucent then
        render.OverrideDepthEnable(true, true)
        
        for _, chunkMaterials in pairs(mapMeshes.displacements) do
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
        
        render.OverrideDepthEnable(false)
    elseif translucent then
        render.OverrideDepthEnable(false)
    end
    
    renderStats.draws = draws
end

-- Enable/Disable Functions
local function EnableCustomRendering()
    if isEnabled then return end
    isEnabled = true

    RunConsoleCommand("r_drawworld", "0")
    
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

    RunConsoleCommand("r_drawworld", "1")
    
    hook.Remove("PreDrawOpaqueRenderables", "RTXCustomWorld")
    hook.Remove("PreDrawTranslucentRenderables", "RTXCustomWorld")
end

-- Initialization and Cleanup
local function Initialize()
    BuildMapMeshes()
    
    timer.Simple(1, function()
        if CONVARS.ENABLED:GetBool() then
            EnableCustomRendering()
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

-- Menu
hook.Add("PopulateToolMenu", "RTXCustomWorldMenu", function()
    spawnmenu.AddToolMenuOption("Utilities", "User", "RTX_ForceRender", "#RTX Custom World", "", "", function(panel)
        panel:ClearControls()
        
        panel:CheckBox("Enable Custom World Rendering", "rtx_force_render")
        panel:ControlHelp("Renders the world using chunked meshes")
        
        panel:NumSlider("Chunk Size", "rtx_chunk_size", 4, 8196, 0)
        panel:ControlHelp("Size of chunks for mesh combining. Larger = better performance but more memory")
        
        panel:CheckBox("Show Debug Info", "rtx_force_render_debug")
        
        panel:Button("Rebuild Meshes", "rtx_rebuild_meshes")
    end)
end)

-- Console Commands
concommand.Add("rtx_rebuild_meshes", BuildMapMeshes)