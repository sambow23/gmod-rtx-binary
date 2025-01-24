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

-- Local Variables and Caches
local mapMeshes = {
    opaque = {},
    translucent = {},
}
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
local MAX_VERTICES = 6000
local MAX_CHUNK_VERTS = 32768
local EyePos = EyePos

-- Pre-allocate common vectors and tables for reuse
local vertexBuffer = {
    positions = {},
    normals = {},
    uvs = {}
}

local function ValidateVertex(pos)
    -- Check for NaN or extreme values
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
    
    local chunkSize = CONVARS.CHUNK_SIZE:GetInt()
    local chunks = {
        opaque = {},
        translucent = {},
    }
    
    -- Sort faces into chunks with optimized table operations
    for _, leaf in pairs(NikNaks.CurrentMap:GetLeafs()) do  
        if not leaf or leaf:IsOutsideMap() then continue end
        
        local leafFaces = leaf:GetFaces(true)
        if not leafFaces then continue end
    
-- In the BuildMapMeshes function, modify the face sorting section:
        for _, face in pairs(leafFaces) do
            -- Add displacement check early to skip them entirely
            if not face or 
            face:IsDisplacement() or -- Skip displacements early
            IsBrushEntity(face) or
            not face:ShouldRender() or 
            IsSkyboxFace(face) then 
                continue 
            end
            
            local vertices = face:GetVertexs()
            if not vertices or #vertices == 0 then continue end
            
            -- Optimized center calculation
            local center = Vector(0, 0, 0)
            local vertCount = #vertices
            for i = 1, vertCount do
                local vert = vertices[i]
                if not vert then continue end
                center:Add(vert)
            end
            center:Div(vertCount)
            
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
            
            table_insert(chunkGroup[chunkKey][matName].faces, face)
        end
    end
    
    -- Create separate mesh creation functions for regular faces and displacements
    local function CreateRegularMeshGroup(faces, material)
        if not faces or #faces == 0 or not material then return nil end
        
        -- Pre-allocate vertex buffer
        local vertexCount = 0
        table.Empty(vertexBuffer.positions)
        table.Empty(vertexBuffer.normals)
        table.Empty(vertexBuffer.uvs)
        
        -- Track chunk bounds
        local minBounds = Vector(math_huge, math_huge, math_huge)
        local maxBounds = Vector(-math_huge, -math_huge, -math_huge)
        
        -- First pass: collect and validate vertices
        local validFaces = {}
        for _, face in ipairs(faces) do
            local verts = face:GenerateVertexTriangleData()
            if verts then
                local faceValid = true
                local faceVerts = {}
                
                for _, vert in ipairs(verts) do
                    if not ValidateVertex(vert.pos) then
                        faceValid = false
                        break
                    end
                    
                    -- Update bounds
                    minBounds.x = math_min(minBounds.x, vert.pos.x)
                    minBounds.y = math_min(minBounds.y, vert.pos.y)
                    minBounds.z = math_min(minBounds.z, vert.pos.z)
                    maxBounds.x = math_max(maxBounds.x, vert.pos.x)
                    maxBounds.y = math_max(maxBounds.y, vert.pos.y)
                    maxBounds.z = math_max(maxBounds.z, vert.pos.z)
                    
                    table_insert(faceVerts, vert)
                end
                
                if faceValid then
                    table_insert(validFaces, faceVerts)
                end
            end
        end
        
        -- Check chunk size
        local chunkSize = maxBounds - minBounds
        if chunkSize.x > MAX_CHUNK_VERTS or 
           chunkSize.y > MAX_CHUNK_VERTS or 
           chunkSize.z > MAX_CHUNK_VERTS then
            return nil -- Skip oversized chunks
        end
        
        -- Second pass: build vertex buffer from valid faces
        for _, faceVerts in ipairs(validFaces) do
            for _, vert in ipairs(faceVerts) do
                if vertexCount >= MAX_VERTICES then break end
                
                vertexCount = vertexCount + 1
                vertexBuffer.positions[vertexCount] = vert.pos
                vertexBuffer.normals[vertexCount] = vert.normal
                vertexBuffer.uvs[vertexCount] = {vert.u or 0, vert.v or 0}
            end
        end
        
        -- Create mesh batches using pre-allocated data
        local meshGroups = {}
        local vertexIndex = 1
        
        while vertexIndex <= vertexCount do
            local vertsThisMesh = math_min(MAX_VERTICES, vertexCount - vertexIndex + 1)
            if vertsThisMesh > 0 then
                local newMesh = Mesh(material)
                mesh.Begin(newMesh, MATERIAL_TRIANGLES, vertsThisMesh)
                
                for i = 0, vertsThisMesh - 1 do
                    local idx = vertexIndex + i
                    mesh.Position(vertexBuffer.positions[idx])
                    mesh.Normal(vertexBuffer.normals[idx])
                    mesh.TexCoord(0, vertexBuffer.uvs[idx][1], vertexBuffer.uvs[idx][2])
                    mesh.AdvanceVertex()
                end
                
                mesh.End()
                table_insert(meshGroups, newMesh)
            end
            vertexIndex = vertexIndex + vertsThisMesh
        end
        
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
    
    if translucent then
        render.OverrideDepthEnable(false)
    end
    
    renderStats.draws = draws
end

-- Enable/Disable Functions
local function EnableCustomRendering()
    if isEnabled then return end
    isEnabled = true

    -- Disable world rendering using render.OverrideDepthEnable
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
        
        panel:NumSlider("Chunk Size", "rtx_chunk_size", 4, 65536, 0)
        panel:ControlHelp("Size of chunks for mesh combining. Larger = better performance but more memory")
        
        panel:CheckBox("Show Debug Info", "rtx_force_render_debug")
        
        panel:Button("Rebuild Meshes", "rtx_rebuild_meshes")
    end)
end)

-- Console Commands
concommand.Add("rtx_rebuild_meshes", BuildMapMeshes)