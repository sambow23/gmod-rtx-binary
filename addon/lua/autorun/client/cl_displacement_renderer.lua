-- cl_displacement_renderer.lua
if not CLIENT then return end
require("niknaks")

local CONVARS = {
    ENABLED = CreateClientConVar("custom_disp_render", "1", true, false, "Enables custom displacement rendering"),
    DEBUG = CreateClientConVar("custom_disp_render_debug", "0", true, false, "Shows debug info for displacement rendering")
}

-- Cache commonly used functions
local Vector = Vector
local table_insert = table.insert
local math_floor = math.floor

local dispMeshes = {
    opaque = {},
    translucent = {}
}

-- Cache for shared vertices between displacement patches
local dispVertexCache = {}

local function GetCacheKey(pos)
    -- Use higher precision for edge matching
    local precision = 10000 -- 4 decimal places
    local x = math.floor(pos.x * precision + 0.5) / precision
    local y = math.floor(pos.y * precision + 0.5) / precision
    local z = math.floor(pos.z * precision + 0.5) / precision
    return string.format("%.4f,%.4f,%.4f", x, y, z)
end

local function FindNeighboringDisplacements(face, faces)
    local neighbors = {}
    local pos = face:GetVertexs()
    if not pos then return neighbors end
    
    -- Find neighbors by checking shared vertices
    for _, otherFace in ipairs(faces) do
        if otherFace == face or not otherFace:IsDisplacement() then continue end
        
        local otherPos = otherFace:GetVertexs()
        if not otherPos then continue end
        
        -- Check if faces share any vertices
        local sharedVerts = 0
        for _, v1 in ipairs(pos) do
            for _, v2 in ipairs(otherPos) do
                -- Compare positions with some tolerance
                if v1:DistToSqr(v2) < 0.1 then
                    sharedVerts = sharedVerts + 1
                    break
                end
            end
        end
        
        -- If faces share 2 or more vertices, they're neighbors
        if sharedVerts >= 2 then
            table.insert(neighbors, otherFace)
        end
    end
    
    return neighbors
end

local function GenerateDispMesh(face)
    if not face:IsDisplacement() then return nil end
    
    local dispInfo = face:GetDisplacementInfo()
    local verts = face:GetVertexs()
    
    if not verts or #verts ~= 4 then return nil end

    local power = dispInfo.power
    local numSegments = 2^power
    
    -- Get texture data
    local texInfo = face:GetTexInfo()
    local texData = face:GetTexData()
    local textureWidth = texData.width
    local textureHeight = texData.height

    -- Start position is crucial for proper alignment
    local startPosition = dispInfo.startPosition
    
    -- Generate vertices
    local vertices = {}
    local dispVerts = NikNaks.CurrentMap:GetDispVerts()
    local startVert = dispInfo.DispVertStart
    
    -- Find the correct starting corner by matching startPosition
    local cornerOrder = {1, 2, 3, 4}
    local bestDist = math.huge
    local bestCorner = 1
    for i, v in ipairs(verts) do
        local dist = v:DistToSqr(startPosition)
        if dist < bestDist then
            bestDist = dist
            bestCorner = i
        end
    end
    
    -- Reorder corners to start from the correct position
    local orderedVerts = {}
    for i = 1, 4 do
        local idx = ((bestCorner + i - 2) % 4) + 1
        orderedVerts[i] = verts[idx]
    end
    
    -- Generate displacement grid
    for i = 0, numSegments do
        local alphaU = i / numSegments
        for j = 0, numSegments do
            local alphaV = j / numSegments
            
            -- Calculate base position using bilinear interpolation
            local top = LerpVector(alphaU, orderedVerts[1], orderedVerts[2])
            local bottom = LerpVector(alphaU, orderedVerts[4], orderedVerts[3])
            local basePos = LerpVector(alphaV, top, bottom)
            
            -- Get displacement data
            local dispIndex = startVert + i * (numSegments + 1) + j
            local dispVert = dispVerts[dispIndex]
            if not dispVert then continue end
            
            -- Apply displacement precisely
            local dispVector = dispVert.vec
            dispVector:Normalize() -- Ensure normalized displacement vector
            local finalPos = basePos + (dispVector * dispVert.dist)
            
            -- Calculate precise UVs using world space
            local u = (texInfo.textureVects[0][0] * finalPos.x + 
                      texInfo.textureVects[0][1] * finalPos.y + 
                      texInfo.textureVects[0][2] * finalPos.z + 
                      texInfo.textureVects[0][3]) / textureWidth
            
            local v = (texInfo.textureVects[1][0] * finalPos.x + 
                      texInfo.textureVects[1][1] * finalPos.y + 
                      texInfo.textureVects[1][2] * finalPos.z + 
                      texInfo.textureVects[1][3]) / textureHeight
            
            -- Calculate proper normal
            local normal = dispVector
            if i > 0 and i < numSegments and j > 0 and j < numSegments then
                -- Use cross product of adjacent edges for interior vertices
                local prevI = vertices[(i-1) * (numSegments + 1) + j + 1]
                local prevJ = vertices[i * (numSegments + 1) + j]
                if prevI and prevJ then
                    local edge1 = prevI.pos - finalPos
                    local edge2 = prevJ.pos - finalPos
                    normal = edge1:Cross(edge2)
                    normal:Normalize()
                end
            end
            
            table_insert(vertices, {
                pos = finalPos,
                normal = normal,
                u = u,
                v = v,
                alpha = dispVert.alpha / 255
            })
        end
    end

    -- Generate triangles with consistent winding
    local triangles = {}
    for i = 0, numSegments - 1 do
        for j = 0, numSegments - 1 do
            local index = i * (numSegments + 1) + j + 1
            
            -- First triangle
            table_insert(triangles, vertices[index])
            table_insert(triangles, vertices[index + numSegments + 1])
            table_insert(triangles, vertices[index + 1])
            
            -- Second triangle
            table_insert(triangles, vertices[index + 1])
            table_insert(triangles, vertices[index + numSegments + 1])
            table_insert(triangles, vertices[index + numSegments + 2])
        end
    end
    
    return {
        vertices = vertices,
        triangles = triangles,
        material = face:GetMaterial()
    }
end

local function BuildDispMeshes()
    print("[Displacement Renderer] Starting mesh build...")
    local startTime = SysTime()

    -- Clear existing meshes
    for _, group in pairs(dispMeshes) do
        for _, mesh in pairs(group) do
            if mesh.mesh then
                mesh.mesh:Destroy()
            end
        end
    end
    
    dispMeshes = {
        opaque = {},
        translucent = {}
    }
    
    -- Get all displacement faces
    local faces = NikNaks.CurrentMap:GetDisplacmentFaces()
    
    for _, face in ipairs(faces) do
        local meshData = GenerateDispMesh(face)
        if not meshData then continue end
        
        -- Create mesh
        local meshObj = Mesh(meshData.material)
        
        -- Set material before beginning mesh creation
        render.SetMaterial(meshData.material)
        
        mesh.Begin(meshObj, MATERIAL_TRIANGLES, #meshData.triangles)
        for _, vert in ipairs(meshData.triangles) do
            mesh.Position(vert.pos)
            mesh.Normal(vert.normal)
            mesh.TexCoord(0, vert.u, vert.v)
            mesh.Color(255, 255, 255, math.floor(vert.alpha * 255)) -- Apply vertex alpha
            mesh.AdvanceVertex()
        end
        mesh.End()
        
        -- Store in appropriate group
        local group = face:IsTranslucent() and dispMeshes.translucent or dispMeshes.opaque
        table_insert(group, {
            mesh = meshObj,
            material = meshData.material
        })
    end

    local meshCount = #dispMeshes.opaque + #dispMeshes.translucent
    print(string.format("[Displacement Renderer] Built %d meshes in %.2f seconds", 
        meshCount, 
        SysTime() - startTime))
end

local function RenderDisplacements(translucent)
    if not CONVARS.ENABLED:GetBool() then return end
    
    local group = translucent and dispMeshes.translucent or dispMeshes.opaque
    
    if CONVARS.DEBUG:GetBool() then
        local count = #group
        debugoverlay.Text(Vector(0,0,0), string.format("Rendering %d %s displacement meshes", 
            count, 
            translucent and "translucent" or "opaque"), 
            FrameTime())
    end
    
    
    for _, meshData in ipairs(group) do
        render.SetMaterial(meshData.material)
        meshData.mesh:Draw()
    end
end

-- Cleanup function
local function CleanupDispCache()
    dispVertexCache = {}
end

-- Hooks
hook.Add("InitPostEntity", "DisplacementInit", function()
    CleanupDispCache()
    BuildDispMeshes()
    RunConsoleCommand("r_drawdisp", "0")
end)

hook.Add("PostCleanupMap", "DisplacementRebuild", function()
    CleanupDispCache()
    BuildDispMeshes()
end)

hook.Add("PreDrawOpaqueRenderables", "DisplacementRender", function()
    RenderDisplacements(false)
end)

hook.Add("PreDrawTranslucentRenderables", "DisplacementRender", function()
    RenderDisplacements(true) 
end)