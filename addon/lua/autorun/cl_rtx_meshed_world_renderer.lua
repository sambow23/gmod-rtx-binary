-- Disables source engine world rendering and replaces it with chunked mesh rendering instead, fixes engine culling issues. 
-- MAJOR THANK YOU to the creator of NikNaks, a lot of this would not be possible without it.
if not CLIENT then return end
require("niknaks")

-- ConVars
local CONVARS = {
    ENABLED = CreateClientConVar("rtx_force_render", "1", true, false, "Forces custom mesh rendering of map"),
    DEBUG = CreateClientConVar("rtx_force_render_debug", "0", true, false, "Shows debug info for mesh rendering"),
    CHUNK_SIZE = CreateClientConVar("rtx_chunk_size", "512", true, false, "Size of chunks for mesh combining")
}

local MAX_MESH_VERTICES = 10000 -- Source engine mesh vertex limit

-- Local Variables
local mapMeshes = {}
local isEnabled = false
local renderStats = {draws = 0}
local materialCache = {}

-- Utility Functions
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
    return string.format("%d,%d,%d", x, y, z)
end

-- Displacement Handling Functions
local function GetDisplacementVertexs(self, faceVertexData)
    local dispInfo = self:GetDisplacementInfo()
    local baseVerts = faceVertexData

    -- Check for valid displacement data
    if not baseVerts or #baseVerts ~= 4 then
        if CONVARS.DEBUG:GetBool() then
            print(string.format("[RTX Fixes] Invalid displacement face: Expected 4 vertices, got %d", #baseVerts or 0))
        end
        return nil
    end

    -- Calculate displacement grid size
    local power = dispInfo.power
    local gridSize = bit.lshift(1, power) + 1
    local vertCount = gridSize * gridSize

    -- Get displacement verts data
    local dispVerts = self.__map:GetDispVerts()
    local vertStart = dispInfo.DispVertStart

    -- First, establish the correct base geometry
    local corners = {
        baseVerts[1].pos,
        baseVerts[2].pos,
        baseVerts[3].pos,
        baseVerts[4].pos
    }

    -- Calculate UV basis vectors
    local uAxis = (corners[2] - corners[1])
    local vAxis = (corners[4] - corners[1])
    uAxis:Normalize()
    vAxis:Normalize()

    -- Create vertices array
    local vertices = {}
    
    -- Generate displacement grid
    for row = 0, gridSize - 1 do
        local v = row / (gridSize - 1)
        for col = 0, gridSize - 1 do
            local u = col / (gridSize - 1)
            local vertIdx = vertStart + row * gridSize + col
            local dispVert = dispVerts[vertIdx]
            
            if not dispVert then continue end

            -- Calculate base position using bilinear interpolation
            local left = corners[1] + (corners[4] - corners[1]) * v
            local right = corners[2] + (corners[3] - corners[2]) * v
            local basePos = left + (right - left) * u

            -- Calculate UV coordinates
            local uvLeft = Vector(baseVerts[1].u, baseVerts[1].v, 0) * (1-v) + 
                         Vector(baseVerts[4].u, baseVerts[4].v, 0) * v
            local uvRight = Vector(baseVerts[2].u, baseVerts[2].v, 0) * (1-v) + 
                          Vector(baseVerts[3].u, baseVerts[3].v, 0) * v
            local uv = uvLeft + (uvRight - uvLeft) * u

            -- Apply displacement
            local dispVector = dispVert.vec
            local dispDistance = dispVert.dist
            local finalPos = basePos + dispVector * dispDistance

            -- Handle entity transforms if needed
            if self.__bmodel > 0 then
                local func_brush = self.__map:GetEntities()[self.__bmodel]
                if func_brush and func_brush.origin then
                    finalPos = finalPos + func_brush.origin
                end
            end

            -- Store vertex data
            vertices[#vertices + 1] = {
                pos = finalPos,
                normal = dispVector:GetNormalized(),
                u = uv.x,
                v = uv.y,
                userdata = {0, 0, 0, 0}
            }
        end
    end

    return vertices
end

local function GridPolyChop(grid)
    local width = math.sqrt(#grid)
    local triangles = {}
    
    for row = 0, width - 2 do
        for col = 0, width - 2 do
            local i1 = row * width + col
            local i2 = i1 + 1
            local i3 = i1 + width
            local i4 = i3 + 1
            
            -- First triangle
            table.insert(triangles, grid[i1 + 1])
            table.insert(triangles, grid[i2 + 1])
            table.insert(triangles, grid[i3 + 1])
            
            -- Second triangle
            table.insert(triangles, grid[i2 + 1])
            table.insert(triangles, grid[i4 + 1])
            table.insert(triangles, grid[i3 + 1])
        end
    end
    
    return triangles
end

-- Mesh Creation Functions
local function CreateChunkMeshGroup(faces, material)
    if not faces or #faces == 0 or not material then return nil end

    local MAX_VERTICES = 10000
    local meshGroups = {}
    
    -- Collect vertex data
    local allVertices = {}
    local totalVertices = 0
    
    for _, face in ipairs(faces) do
        -- Use GenerateVertexTriangleData for both regular faces and displacements
        local verts = face:GenerateVertexTriangleData()
        if verts then
            for _, vert in ipairs(verts) do
                if vert.pos and vert.normal then
                    -- Apply brush entity transforms if needed
                    if face.__bmodel > 0 then
                        local func_brush = face.__map:GetEntities()[face.__bmodel]
                        if func_brush and func_brush.origin then
                            vert.pos = vert.pos + func_brush.origin
                            if func_brush.angles then
                                local ang = func_brush.angles
                                vert.pos = LocalToWorld(vert.pos, Angle(0,0,0), Vector(0,0,0), ang)
                                vert.normal = ang:Forward() * vert.normal.x + 
                                            ang:Right() * vert.normal.y + 
                                            ang:Up() * vert.normal.z
                            end
                        end
                    end
                    
                    totalVertices = totalVertices + 1
                    table.insert(allVertices, vert)
                end
            end
        end
    end
    
    if CONVARS.DEBUG:GetBool() then
        print(string.format("[RTX Fixes] Processing chunk with %d total vertices", totalVertices))
    end
    
    -- Calculate mesh distribution
    local meshCount = math.ceil(totalVertices / MAX_VERTICES)
    local vertsPerMesh = math.floor(totalVertices / meshCount)
    
    -- Create mesh batches
    local vertexIndex = 1
    while vertexIndex <= #allVertices do
        local remainingVerts = #allVertices - vertexIndex + 1
        local vertsThisMesh = math.min(MAX_VERTICES, remainingVerts)
        
        if vertsThisMesh > 0 then
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

local function GetDisplacementBounds(face)
    local dispInfo = face:GetDisplacementInfo()
    local verts = face:GenerateVertexTriangleData()
    if not verts or #verts == 0 then return Vector(), Vector() end
    
    local mins = Vector(math.huge, math.huge, math.huge)
    local maxs = Vector(-math.huge, -math.huge, -math.huge)
    
    for _, vert in ipairs(verts) do
        mins.x = math.min(mins.x, vert.pos.x)
        mins.y = math.min(mins.y, vert.pos.y)
        mins.z = math.min(mins.z, vert.pos.z)
        maxs.x = math.max(maxs.x, vert.pos.x)
        maxs.y = math.max(maxs.y, vert.pos.y)
        maxs.z = math.max(maxs.z, vert.pos.z)
    end
    
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
            if not face or not face:ShouldRender() or IsSkyboxFace(face) then continue end
            
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
        
        -- Sort faces by distance from camera (back to front)
        local sortedFaces = table.Copy(faces)
        table.sort(sortedFaces, function(a, b)
            local aMin, aMax = GetDisplacementBounds(a)
            local bMin, bMax = GetDisplacementBounds(b)
            local aCenter = (aMin + aMax) * 0.5
            local bCenter = (bMin + bMax) * 0.5
            local camPos = EyePos()
            return aCenter:DistToSqr(camPos) > bCenter:DistToSqr(camPos)
        end)
        
        local meshGroups = {}
        local currentVertices = {}
        local vertexCount = 0
        
        -- Process faces maintaining back-to-front order
        for _, face in ipairs(sortedFaces) do
            local verts = face:GenerateVertexTriangleData()
            if not verts then continue end
            
            -- Check if adding these vertices would exceed the limit
            if vertexCount + #verts > 10000 then
                -- Create mesh from current vertices
                if #currentVertices > 0 then
                    local newMesh = Mesh(material)
                    mesh.Begin(newMesh, MATERIAL_TRIANGLES, #currentVertices)
                    
                    for _, vert in ipairs(currentVertices) do
                        mesh.Position(vert.pos)
                        mesh.Normal(vert.normal)
                        mesh.TexCoord(0, vert.u or 0, vert.v or 0)
                        mesh.AdvanceVertex()
                    end
                    
                    mesh.End()
                    table.insert(meshGroups, newMesh)
                end
                
                -- Reset for next batch
                currentVertices = {}
                vertexCount = 0
            end
            
            -- Process vertices for this face
            for _, vert in ipairs(verts) do
                if vert.pos and vert.normal then
                    -- Apply any necessary transforms
                    local finalPos = Vector(vert.pos)
                    local finalNormal = Vector(vert.normal)
                    
                    if face.__bmodel > 0 then
                        local func_brush = face.__map:GetEntities()[face.__bmodel]
                        if func_brush then
                            if func_brush.origin then
                                finalPos = finalPos + func_brush.origin
                            end
                            if func_brush.angles then
                                local ang = func_brush.angles
                                finalPos = LocalToWorld(finalPos, angle_zero, Vector(0,0,0), ang)
                                finalNormal = ang:Forward() * finalNormal.x + 
                                            ang:Right() * finalNormal.y + 
                                            ang:Up() * finalNormal.z
                            end
                        end
                    end
                    
                    table.insert(currentVertices, {
                        pos = finalPos,
                        normal = finalNormal,
                        u = vert.u,
                        v = vert.v
                    })
                    vertexCount = vertexCount + 1
                end
            end
        end
        
        -- Create final mesh from remaining vertices
        if #currentVertices > 0 then
            local newMesh = Mesh(material)
            mesh.Begin(newMesh, MATERIAL_TRIANGLES, #currentVertices)
            
            for _, vert in ipairs(currentVertices) do
                mesh.Position(vert.pos)
                mesh.Normal(vert.normal)
                mesh.TexCoord(0, vert.u or 0, vert.v or 0)
                mesh.AdvanceVertex()
            end
            
            mesh.End()
            table.insert(meshGroups, newMesh)
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

    renderStats.draws = 0

    if translucent then
        render.SetBlend(1)
        render.OverrideDepthEnable(true, true)
    end

    -- First render regular faces
    local groups = translucent and mapMeshes.translucent or mapMeshes.opaque
    local currentMaterial = nil
    
    for _, chunkMaterials in pairs(groups) do
        for _, group in pairs(chunkMaterials) do
            if currentMaterial ~= group.material then
                render.SetMaterial(group.material)
                currentMaterial = group.material
            end
            for _, mesh in ipairs(group.meshes) do
                mesh:Draw()
                renderStats.draws = renderStats.draws + 1
            end
        end
    end

    -- Then render displacements with proper depth testing
    if not translucent then
        render.SetColorMaterial() -- Reset material state
        render.OverrideDepthEnable(true, true)
        
        for _, chunkMaterials in pairs(mapMeshes.displacements) do
            for _, group in pairs(chunkMaterials) do
                if currentMaterial ~= group.material then
                    render.SetMaterial(group.material)
                    currentMaterial = group.material
                end
                for _, mesh in ipairs(group.meshes) do
                    mesh:Draw()
                    renderStats.draws = renderStats.draws + 1
                end
            end
        end
        
        render.OverrideDepthEnable(false)
    end

    if translucent then
        render.OverrideDepthEnable(false)
    end
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