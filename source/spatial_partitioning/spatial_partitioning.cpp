#include "spatial_partitioning.hpp"
#include "math/math.hpp"
#include <set>
#include <algorithm>

namespace SpatialPartitioning {

SpatialHashGrid::SpatialHashGrid(float cellSize) : cellSize(cellSize) {
}

SpatialHashGrid::~SpatialHashGrid() {
    Clear();
}

int64_t SpatialHashGrid::HashPosition(const Vector& pos) const {
    int x = static_cast<int>(floor(pos.x / cellSize));
    int y = static_cast<int>(floor(pos.y / cellSize));
    int z = static_cast<int>(floor(pos.z / cellSize));
    
    // Use RTXMath's existing hash function
    return RTXMath::GenerateChunkKey(x, y, z);
}

void SpatialHashGrid::Insert(void* entity, const Vector& pos) {
    if (!entity) return;
    int64_t hash = HashPosition(pos);
    auto& cell = grid[hash];
    
    // Avoid duplicates
    if (std::find(cell.begin(), cell.end(), entity) == cell.end()) {
        cell.push_back(entity);
    }
}

void SpatialHashGrid::Remove(void* entity, const Vector& pos) {
    if (!entity) return;
    int64_t hash = HashPosition(pos);
    
    auto it = grid.find(hash);
    if (it != grid.end()) {
        auto& cell = it->second;
        cell.erase(std::remove(cell.begin(), cell.end(), entity), cell.end());
        
        // Remove empty cells
        if (cell.empty()) {
            grid.erase(it);
        }
    }
}

void SpatialHashGrid::Update(void* entity, const Vector& oldPos, const Vector& newPos) {
    // Check if the position changed enough to be in a different cell
    int64_t oldHash = HashPosition(oldPos);
    int64_t newHash = HashPosition(newPos);
    
    if (oldHash != newHash) {
        Remove(entity, oldPos);
        Insert(entity, newPos);
    }
}

std::vector<void*> SpatialHashGrid::Query(const Vector& mins, const Vector& maxs) const {
    std::set<void*> uniqueEntities;
    
    int minX = static_cast<int>(floor(mins.x / cellSize));
    int minY = static_cast<int>(floor(mins.y / cellSize));
    int minZ = static_cast<int>(floor(mins.z / cellSize));
    
    int maxX = static_cast<int>(floor(maxs.x / cellSize));
    int maxY = static_cast<int>(floor(maxs.y / cellSize));
    int maxZ = static_cast<int>(floor(maxs.z / cellSize));
    
    for (int x = minX; x <= maxX; x++) {
        for (int y = minY; y <= maxY; y++) {
            for (int z = minZ; z <= maxZ; z++) {
                int64_t hash = RTXMath::GenerateChunkKey(x, y, z);
                auto it = grid.find(hash);
                if (it != grid.end()) {
                    for (void* entity : it->second) {
                        uniqueEntities.insert(entity);
                    }
                }
            }
        }
    }
    
    return std::vector<void*>(uniqueEntities.begin(), uniqueEntities.end());
}

void SpatialHashGrid::QueryCallback(const Vector& mins, const Vector& maxs, 
                                   const std::function<void(void*)>& callback) const {
    std::set<void*> processedEntities;
    
    int minX = static_cast<int>(floor(mins.x / cellSize));
    int minY = static_cast<int>(floor(mins.y / cellSize));
    int minZ = static_cast<int>(floor(mins.z / cellSize));
    
    int maxX = static_cast<int>(floor(maxs.x / cellSize));
    int maxY = static_cast<int>(floor(maxs.y / cellSize));
    int maxZ = static_cast<int>(floor(maxs.z / cellSize));
    
    for (int x = minX; x <= maxX; x++) {
        for (int y = minY; y <= maxY; y++) {
            for (int z = minZ; z <= maxZ; z++) {
                int64_t hash = RTXMath::GenerateChunkKey(x, y, z);
                auto it = grid.find(hash);
                if (it != grid.end()) {
                    for (void* entity : it->second) {
                        if (processedEntities.insert(entity).second) {
                            callback(entity);
                        }
                    }
                }
            }
        }
    }
}

void SpatialHashGrid::Clear() {
    grid.clear();
}

size_t SpatialHashGrid::GetTotalEntities() const {
    std::set<void*> uniqueEntities;
    for (const auto& pair : grid) {
        for (void* entity : pair.second) {
            uniqueEntities.insert(entity);
        }
    }
    return uniqueEntities.size();
}

size_t SpatialHashGrid::GetCellCount() const {
    return grid.size();
}

} // namespace SpatialPartitioning