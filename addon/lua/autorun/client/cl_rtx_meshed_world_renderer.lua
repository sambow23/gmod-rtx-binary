-- Disables source engine world rendering and replaces it with chunked mesh rendering instead, fixes engine culling issues. 
-- MAJOR THANK YOU to the creator of NikNaks, a lot of this would not be possible without it.
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
local Vector = Vector
local math_min = math.min
local math_max = math.max
local math_huge = math.huge
local math_floor = math.floor
local table_insert = table.insert
local MAX_VERTICES = 10000
local MAX_CHUNK_VERTS = 32768
local boundingRegions = {}
local isDrawingSkybox = false
local lastSkyState = GetConVar("r_3dsky"):GetBool()
local disclaimerShown = false


-- Pre-allocate common vectors and tables for reuse
local vertexBuffer = {
    positions = {},
    normals = {},
    uvs = {}
}

local function MapTable(tbl, func)
    local mapped = {}
    for i, v in ipairs(tbl) do
        mapped[i] = func(v)
    end
    return mapped
end

local function CalculateRegionBounds(vertices)
    local mins = Vector(math_huge, math_huge, math_huge)
    local maxs = Vector(-math_huge, -math_huge, -math_huge)
    local vertCount = #vertices
    local center = Vector(0, 0, 0)
    
    for _, vert in ipairs(vertices) do
        mins.x = math_min(mins.x, vert.x)
        mins.y = math_min(mins.y, vert.y)
        mins.z = math_min(mins.z, vert.z)
        maxs.x = math_max(maxs.x, vert.x)
        maxs.y = math_max(maxs.y, vert.y)
        maxs.z = math_max(maxs.z, vert.z)
        center:Add(vert)
    end
    
    center:Div(vertCount)
    
    return {
        mins = mins,
        maxs = maxs,
        center = center,
        size = maxs - mins
    }
end

local function IsRegionConnected(regionA, regionB)
    local gap_threshold = 1024 -- Smaller threshold for direct connections
    
    -- Check if regions are directly adjacent or overlapping on any axis
    local isConnectedX = (regionA.maxs.x + gap_threshold) >= regionB.mins.x and
                        (regionB.maxs.x + gap_threshold) >= regionA.mins.x
    local isConnectedY = (regionA.maxs.y + gap_threshold) >= regionB.mins.y and
                        (regionB.maxs.y + gap_threshold) >= regionA.mins.y
    local isConnectedZ = (regionA.maxs.z + gap_threshold) >= regionB.mins.z and
                        (regionB.maxs.z + gap_threshold) >= regionA.mins.z
    
    -- Check if regions share a plane (like different floors of a building)
    local sharesPlanXY = math.abs(regionA.center.z - regionB.center.z) < gap_threshold * 2
    local sharesPlanXZ = math.abs(regionA.center.y - regionB.center.y) < gap_threshold * 2
    local sharesPlanYZ = math.abs(regionA.center.x - regionB.center.x) < gap_threshold * 2
    
    return (isConnectedX and isConnectedY) or
           (isConnectedY and isConnectedZ) or
           (isConnectedX and isConnectedZ) or
           sharesPlanXY or sharesPlanXZ or sharesPlanYZ
end

local function IsPointInRegion(point, region, tolerance)
    tolerance = tolerance or 0
    return point.x >= (region.mins.x - tolerance) and point.x <= (region.maxs.x + tolerance) and
           point.y >= (region.mins.y - tolerance) and point.y <= (region.maxs.y + tolerance) and
           point.z >= (region.mins.z - tolerance) and point.z <= (region.maxs.z + tolerance)
end

local function IdentifyMapRegions()
    boundingRegions = {}
    local initialRegions = {}
    local processedCount = 0
    
    print("[RTX Fixes] Starting intelligent region identification...")
    
    -- First pass: Create initial regions based on spatial proximity
    for _, leaf in pairs(NikNaks.CurrentMap:GetLeafs()) do
        if not leaf or leaf:IsOutsideMap() then continue end
        
        local leafFaces = leaf:GetFaces(true)
        if not leafFaces then continue end
        
        for _, face in pairs(leafFaces) do
            if not face then continue end
            
            local vertices = face:GetVertexs()
            if not vertices or #vertices == 0 then continue end
            
            local bounds = CalculateRegionBounds(vertices)
            
            -- Find a region to merge with
            local mergedWithExisting = false
            for _, region in ipairs(initialRegions) do
                if IsRegionConnected(bounds, region) then
                    -- Expand existing region
                    region.mins.x = math_min(region.mins.x, bounds.mins.x)
                    region.mins.y = math_min(region.mins.y, bounds.mins.y)
                    region.mins.z = math_min(region.mins.z, bounds.mins.z)
                    region.maxs.x = math_max(region.maxs.x, bounds.maxs.x)
                    region.maxs.y = math_max(region.maxs.y, bounds.maxs.y)
                    region.maxs.z = math_max(region.maxs.z, bounds.maxs.z)
                    region.size = region.maxs - region.mins
                    region.center = (region.maxs + region.mins) / 2
                    region.faceCount = (region.faceCount or 0) + 1
                    mergedWithExisting = true
                    break
                end
            end
            
            if not mergedWithExisting then
                bounds.faceCount = 1
                table_insert(initialRegions, bounds)
            end
            
            processedCount = processedCount + 1
            if processedCount % 5000 == 0 then
                print(string.format("[RTX Fixes] Processed %d faces...", processedCount))
            end
        end
    end
    
    -- Second pass: Merge connected regions and identify main play area
    local mainRegion = nil
    local maxFaces = 0
    
    -- Find the region with the most faces (likely the main play area)
    for _, region in ipairs(initialRegions) do
        if region.faceCount > maxFaces then
            maxFaces = region.faceCount
            mainRegion = region
        end
    end
    
    if mainRegion then
        -- Only keep regions that are definitely separate from the main area
        for _, region in ipairs(initialRegions) do
            if region ~= mainRegion then
                local distToMain = (region.center - mainRegion.center):Length()
                local sizeRatio = region.size:Length() / mainRegion.size:Length()
                
                -- Keep region separate if:
                -- 1. It's very far from the main region
                -- 2. It's much smaller than the main region (likely a skybox or separate room)
                -- 3. It's not connected to the main region
                if (distToMain > 8192 and sizeRatio < 0.25) or
                   (not IsRegionConnected(region, mainRegion) and distToMain > 4096) then
                    table_insert(boundingRegions, region)
                end
            end
        end
    end
    
    print(string.format("[RTX Fixes] Identified main play area and %d separate regions", #boundingRegions))
end

local function IsInSeparateRegion(face)
    if #boundingRegions <= 1 then return false end
    
    local vertices = face:GetVertexs()
    if not vertices or #vertices == 0 then return false end
    
    return EntityManager.ProcessRegionBatch(vertices, LocalPlayer():GetPos(), 256)
end

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

local function SplitChunk(faces, chunkSize)
    local subChunks = {}
    for _, face in ipairs(faces) do
        local vertices = face:GetVertexs()
        if not vertices or #vertices == 0 then continue end
        
        -- Calculate face center
        local center = Vector(0, 0, 0)
        for _, vert in ipairs(vertices) do
            center:Add(vert)
        end
        center:Div(#vertices)
        
        -- Use smaller chunk size for subdivision
        local subX = math_floor(center.x / (chunkSize/2))
        local subY = math_floor(center.y / (chunkSize/2))
        local subZ = math_floor(center.z / (chunkSize/2))
        local subKey = GetChunkKey(subX, subY, subZ)
        
        subChunks[subKey] = subChunks[subKey] or {}
        table_insert(subChunks[subKey], face)
    end
    return subChunks
end

local function DetermineOptimalChunkSize(totalFaces)
    -- Base chunk size on face density, but keep within reasonable bounds
    local density = totalFaces / (16384 * 16384 * 16384) -- Approximate map volume
    return math_max(4096, math_min(65536, math_floor(1 / density * 32768)))
end

local function CreateMeshBatch(vertices, material, maxVertsPerMesh)
    local vertexData = {
        positions = {},
        normals = {},
        uvs = {}
    }
    
    -- Collect vertex data
    for _, vert in ipairs(vertices) do
        table.insert(vertexData.positions, vert.pos)
        table.insert(vertexData.normals, vert.normal)
        table.insert(vertexData.uvs, Vector(vert.u or 0, vert.v or 0, 0))
    end
    
    -- Get optimized batch from native code
    local batch = EntityManager.CreateOptimizedMeshBatch(
        vertexData.positions,
        vertexData.normals,
        vertexData.uvs,
        maxVertsPerMesh
    )
    
    -- Create mesh from optimized data
    local meshes = {}
    local newMesh = Mesh(material)
    
    mesh.Begin(newMesh, MATERIAL_TRIANGLES, #batch.vertices)
    for i = 1, #batch.vertices do
        mesh.Position(batch.vertices[i])
        mesh.Normal(batch.normals[i])
        mesh.TexCoord(0, batch.uvs[i].x, batch.uvs[i].y)
        mesh.AdvanceVertex()
    end
    mesh.End()
    
    table.insert(meshes, newMesh)
    return meshes
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
    
    -- Initialize regions before processing faces
    IdentifyMapRegions()
    
    -- Count total faces for chunk size optimization
    local totalFaces = 0
    for _, leaf in pairs(NikNaks.CurrentMap:GetLeafs()) do
        if not leaf or leaf:IsOutsideMap() then continue end
        local leafFaces = leaf:GetFaces(true)
        if leafFaces then
            totalFaces = totalFaces + #leafFaces
        end
    end
    
    local chunkSize = DetermineOptimalChunkSize(totalFaces)
    CONVARS.CHUNK_SIZE:SetInt(chunkSize)
    
    local chunks = {
        opaque = {},
        translucent = {},
    }
    
    -- Sort faces into chunks with optimized table operations
    for _, leaf in pairs(NikNaks.CurrentMap:GetLeafs()) do  
        if not leaf or leaf:IsOutsideMap() then continue end
        
        local leafFaces = leaf:GetFaces(true)
        if not leafFaces then continue end
    
        for _, face in pairs(leafFaces) do
            if not face or 
               face:IsDisplacement() or -- Skip displacements early
               IsBrushEntity(face) or
               not face:ShouldRender() or 
               IsSkyboxFace(face) or
               IsInSeparateRegion(face) then -- New region check here
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
            
            local chunkGroup = face:IsTranslucent() and chunks.translucent or chunks.opaque
            
            chunkGroup[chunkKey] = chunkGroup[chunkKey] or {}
            chunkGroup[chunkKey][matName] = chunkGroup[chunkKey][matName] or {
                material = materialCache[matName],
                faces = {}
            }
            
            table_insert(chunkGroup[chunkKey][matName].faces, face)
        end
    end
    
    -- Create separate mesh creation functions for regular faces and displacements
    local function CreateRegularMeshGroup(faces, material)
        if not faces or #faces == 0 or not material then return nil end
        
        -- Track chunk bounds
        local minBounds = Vector(math_huge, math_huge, math_huge)
        local maxBounds = Vector(-math_huge, -math_huge, -math_huge)
        
        -- Collect and validate vertices
        local allVertices = {}
        for _, face in ipairs(faces) do
            local verts = face:GenerateVertexTriangleData()
            if verts then
                local faceValid = true
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
                end
                
                if faceValid then
                    for _, vert in ipairs(verts) do
                        table_insert(allVertices, vert)
                    end
                end
            end
        end
        
        -- Check chunk size and split if needed
        local chunkSize = maxBounds - minBounds
        if chunkSize.x > MAX_CHUNK_VERTS or 
           chunkSize.y > MAX_CHUNK_VERTS or 
           chunkSize.z > MAX_CHUNK_VERTS then
            -- Split into sub-chunks and process each
            local subChunks = SplitChunk(faces, CONVARS.CHUNK_SIZE:GetInt())
            local allMeshes = {}
            
            for _, subFaces in pairs(subChunks) do
                local subMeshes = CreateRegularMeshGroup(subFaces, material)
                if subMeshes then
                    for _, mesh in ipairs(subMeshes) do
                        table_insert(allMeshes, mesh)
                    end
                end
            end
            
            return allMeshes
        end
        
        -- Create mesh batches for this chunk
        return CreateMeshBatch(allVertices, material, MAX_VERTICES)
    end

    -- Create combined meshes with separate handling
    for renderType, chunkGroup in pairs(chunks) do
        for chunkKey, materials in pairs(chunkGroup) do
            mapMeshes[renderType][chunkKey] = {}
            for matName, group in pairs(materials) do
                if group.faces and #group.faces > 0 then
                    local meshes = CreateRegularMeshGroup(group.faces, group.material)
                    
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
-- Update the EnableCustomRendering function
local function EnableCustomRendering()
    if isEnabled then return end
    isEnabled = true

    hook.Add("PreDrawSkyBox", "RTXSkyboxState", function()
        isDrawingSkybox = true
    end)

    hook.Add("PostDrawSkyBox", "RTXSkyboxState", function()
        isDrawingSkybox = false
    end)

    hook.Add("PreDrawWorld", "RTXHideWorld", function()
        if isDrawingSkybox then return end
        if render.GetRenderTarget() then return end
        
        render.OverrideDepthEnable(true, false)
        return true
    end)
    
    hook.Add("PostDrawWorld", "RTXHideWorld", function()
        if isDrawingSkybox then return end
        if render.GetRenderTarget() then return end
        
        render.OverrideDepthEnable(false)
    end)
    
    hook.Add("PreDrawOpaqueRenderables", "RTXCustomWorld", function(bDrawingDepth, bDrawingSkybox)
        if isDrawingSkybox then return end
        if render.GetRenderTarget() then return end
        
        RenderCustomWorld(false)
    end)
    
    hook.Add("PreDrawTranslucentRenderables", "RTXCustomWorld", function(bDrawingDepth, bDrawingSkybox)
        if isDrawingSkybox then return end
        if render.GetRenderTarget() then return end
        
        RenderCustomWorld(true)
    end)
end

local function DisableCustomRendering()
    if not isEnabled then return end
    isEnabled = false

    hook.Remove("PreDrawSkyBox", "RTXSkyboxState")
    hook.Remove("PostDrawSkyBox", "RTXSkyboxState")
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

cvars.AddChangeCallback("rtx_capture_mode", function(_, _, new)
    -- Invert the value: if capture_mode is 1, r_drawworld should be 0 and vice versa
    RunConsoleCommand("r_drawworld", new == "1" and "0" or "1")
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
    end)
end)

-- Console Commands
concommand.Add("rtx_rebuild_meshes", BuildMapMeshes)

------ r_3dsky disclaimer ------
local function ShowSkyDisclaimer()
    if disclaimerShown then return end
    disclaimerShown = true

    local frame = vgui.Create("DFrame")
    frame:SetSize(400, 150)
    frame:Center()
    frame:SetTitle("3D Sky Warning")
    frame:MakePopup()

    local label = vgui.Create("DLabel", frame)
    label:SetPos(20, 30)
    label:SetSize(360, 60)
    label:SetWrap(true)
    label:SetText("Warning: Enabling r_3dsky may cause visual artifacts with the custom renderer. It's recommended to keep it disabled for the best experience.")

    local button = vgui.Create("DButton", frame)
    button:SetText("OK")
    button:SetPos(150, 100)
    button:SetSize(100, 30)
    button:SetTextColor(Color(255, 255, 255))
    button.DoClick = function()
        frame:Remove()
    end
end

hook.Add("Think", "RTXSkyMonitor", function()
    local currentSkyState = GetConVar("r_3dsky"):GetBool()
    
    if currentSkyState ~= lastSkyState then
        lastSkyState = currentSkyState
        
        if currentSkyState then
            ShowSkyDisclaimer()
        else
            disclaimerShown = false -- Reset disclaimer state when disabled
        end
    end
end)

hook.Add("ShutDown", "RTXSkyMonitor", function()

    hook.Remove("Think", "RTXSkyMonitor")
end)