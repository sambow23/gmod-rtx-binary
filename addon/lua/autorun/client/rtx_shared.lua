-- RTX Shared functionality between world and prop rendering
if not CLIENT then return end

RTX = RTX or {}
RTX.Shared = {}

-- ConVars that might be shared
RTX.ConVars = {
    ENABLED = CreateClientConVar("rtx_force_render", "1", true, false, "Forces custom rendering of map"),
    PROPS_ENABLED = CreateClientConVar("rtx_force_render_props", "1", true, false, "Forces custom rendering of static props"),
    DEBUG = CreateClientConVar("rtx_force_render_debug", "0", true, false, "Shows debug info for rendering"),
    CHUNK_SIZE = CreateClientConVar("rtx_chunk_size", "65536", true, false, "Size of chunks for mesh combining"),
    CAPTURE_MODE = CreateClientConVar("rtx_capture_mode", "0", true, false, "Toggles r_drawworld for capture mode")
}

-- Shared rendering functions
function RTX.Shared.PushMatrix(matrix)
    cam.PushModelMatrix(matrix)
end

function RTX.Shared.PopMatrix()
    cam.PopModelMatrix()
end

-- Shared mesh handling
function RTX.Shared.CreateMesh(vertices, material)
    if #vertices == 0 then return nil end
    
    local newMesh = Mesh(material)
    mesh.Begin(newMesh, MATERIAL_TRIANGLES, #vertices)
    
    -- Process triangles
    for i = 1, #vertices, 3 do
        local v1, v2, v3 = vertices[i], vertices[i + 1], vertices[i + 2]
        if not (v1 and v2 and v3) then continue end
        
        -- Calculate face normal if not provided
        if not v1.normal or not v2.normal or not v3.normal then
            local normal = (v2.pos - v1.pos):Cross(v3.pos - v1.pos):GetNormalized()
            v1.normal = normal
            v2.normal = normal
            v3.normal = normal
        end
        
        -- First vertex
        mesh.Position(v1.pos)
        mesh.Normal(v1.normal)
        mesh.TexCoord(0, v1.u or 0, v1.v or 0)
        mesh.AdvanceVertex()
        
        -- Second vertex
        mesh.Position(v2.pos)
        mesh.Normal(v2.normal)
        mesh.TexCoord(0, v2.u or 0, v2.v or 0)
        mesh.AdvanceVertex()
        
        -- Third vertex
        mesh.Position(v3.pos)
        mesh.Normal(v3.normal)
        mesh.TexCoord(0, v3.u or 0, v3.v or 0)
        mesh.AdvanceVertex()
    end
    
    mesh.End()
    return newMesh
end

function RTX.Shared.GenerateVertexData(modelMeshes)
    local vertices = {}
    
    for _, meshData in ipairs(modelMeshes) do
        -- Get base vertex data
        local verts = meshData.verticies
        if not verts or #verts == 0 then continue end
        
        -- Process triangles
        for i = 1, #verts, 3 do
            local v1, v2, v3 = verts[i], verts[i + 1], verts[i + 2]
            if not (v1 and v2 and v3) then continue end
            
            -- Calculate face normal
            local normal = (v2.pos - v1.pos):Cross(v3.pos - v1.pos):GetNormalized()
            
            -- Store vertices with corrected normals
            table.insert(vertices, {
                pos = v1.pos,
                normal = normal,
                u = v1.u,
                v = v1.v
            })
            table.insert(vertices, {
                pos = v2.pos,
                normal = normal,
                u = v2.u,
                v = v2.v
            })
            table.insert(vertices, {
                pos = v3.pos,
                normal = normal,
                u = v3.u,
                v = v3.v
            })
        end
    end
    
    return vertices
end

function RTX.Shared.DetermineOptimalChunkSize(totalFaces)
    local density = totalFaces / (16384 * 16384 * 16384) -- Approximate map volume
    return math.max(4096, math.min(65536, math.floor(1 / density * 32768)))
end

function RTX.Shared.GenerateVerticesForFaces(faces)
    local vertices = {}
    for _, face in ipairs(faces) do
        local faceVerts = face:GenerateVertexTriangleData()
        if faceVerts then
            for _, vert in ipairs(faceVerts) do
                table.insert(vertices, vert)
            end
        end
    end
    return #vertices > 0 and vertices or nil
end

function RTX.Shared.CreateMeshBatch(vertices, material, maxVertsPerMesh)
    local meshes = {}
    local currentVerts = {}
    local vertCount = 0
    
    for i = 1, #vertices, 3 do
        for j = 0, 2 do
            if vertices[i + j] then
                table.insert(currentVerts, vertices[i + j])
                vertCount = vertCount + 1
            end
        end
        
        if vertCount >= maxVertsPerMesh - 3 then
            local newMesh = RTX.Shared.CreateMesh(currentVerts, material)
            if newMesh then
                table.insert(meshes, newMesh)
            end
            currentVerts = {}
            vertCount = 0
        end
    end
    
    if #currentVerts > 0 then
        local newMesh = RTX.Shared.CreateMesh(currentVerts, material)
        if newMesh then
            table.insert(meshes, newMesh)
        end
    end
    
    return #meshes > 0 and meshes or nil
end

-- Shared debug functionality
RTX.Shared.RenderStats = {
    worldDraws = 0,
    propsRendered = 0,
    totalProps = 0
}

function RTX.Shared.PrintDebugInfo()
    print("\n=== RTX Debug Info ===")
    print("World Renders:", RTX.Shared.RenderStats.worldDraws)
    print("Props Rendered:", RTX.Shared.RenderStats.propsRendered)
    print("Total Props:", RTX.Shared.RenderStats.totalProps)
    print("===================\n")
end