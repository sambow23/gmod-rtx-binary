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

local function GenerateDispMesh(face)
    if not face:IsDisplacement() then return nil end
    
    local dispInfo = face:GetDisplacementInfo()
    local verts = face:GetVertexs()
    
    if not verts or #verts ~= 4 then return nil end

    -- Get displacement data
    local power = dispInfo.power
    local numSegments = 2^power
    local vertexCount = (numSegments + 1) * (numSegments + 1)
    
    -- Get texture data for proper scaling
    local texInfo = face:GetTexInfo()
    local texData = face:GetTexData()
    local textureWidth = texData.width
    local textureHeight = texData.height
    
    -- Generate grid of vertices
    local vertices = {}
    local dispVerts = NikNaks.CurrentMap:GetDispVerts()
    local startVert = dispInfo.DispVertStart
    
    for i = 0, numSegments do
        local t1 = i / numSegments
        for j = 0, numSegments do
            local t2 = j / numSegments
            
            -- Get base position by bilinear interpolation of corners
            local basePos = LerpVector(t2, 
                              LerpVector(t1, verts[1], verts[2]), 
                              LerpVector(t1, verts[4], verts[3]))
            
            -- Apply displacement
            local dispIndex = startVert + i * (numSegments + 1) + j
            local dispVert = dispVerts[dispIndex]
            if not dispVert then continue end
            
            local finalPos = basePos + dispVert.vec * dispVert.dist
            
            -- Generate properly scaled UVs
            local u = (texInfo.textureVects[0][0] * finalPos.x + 
                      texInfo.textureVects[0][1] * finalPos.y + 
                      texInfo.textureVects[0][2] * finalPos.z + 
                      texInfo.textureVects[0][3]) / textureWidth
            
            local v = (texInfo.textureVects[1][0] * finalPos.x + 
                      texInfo.textureVects[1][1] * finalPos.y + 
                      texInfo.textureVects[1][2] * finalPos.z + 
                      texInfo.textureVects[1][3]) / textureHeight
            
            -- Store the vertex with alpha
            table_insert(vertices, {
                pos = finalPos,
                normal = dispVert.vec,
                u = u,
                v = v,
                alpha = dispVert.alpha / 255  -- Normalize alpha to 0-1 range
            })
        end
    end
    
    -- Generate triangles with alpha
    local triangles = {}
    for i = 0, numSegments - 1 do
        for j = 0, numSegments - 1 do
            local index = i * (numSegments + 1) + j + 1
            
            -- First triangle (counter-clockwise winding)
            table_insert(triangles, vertices[index])
            table_insert(triangles, vertices[index + numSegments + 1])
            table_insert(triangles, vertices[index + 1])
            
            -- Second triangle (counter-clockwise winding)
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

-- Hooks
hook.Add("InitPostEntity", "DisplacementInit", function()
    BuildDispMeshes()
    RunConsoleCommand("r_drawdisp", "0") -- Disable engine displacement rendering
end)

hook.Add("PostCleanupMap", "DisplacementRebuild", BuildDispMeshes)

hook.Add("PreDrawOpaqueRenderables", "DisplacementRender", function()
    RenderDisplacements(false)
end)

hook.Add("PreDrawTranslucentRenderables", "DisplacementRender", function()
    RenderDisplacements(true) 
end)