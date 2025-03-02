#pragma once
#include <vector>
#include <unordered_map>
#include "mathlib/vector.h"
#include <functional>

namespace SpatialPartitioning {

class SpatialHashGrid {
private:
    float cellSize;
    std::unordered_map<int64_t, std::vector<void*>> grid;
    
    int64_t HashPosition(const Vector& pos) const;
    
public:
    SpatialHashGrid(float cellSize = 512.0f);
    ~SpatialHashGrid();
    
    void Insert(void* entity, const Vector& pos);
    void Remove(void* entity, const Vector& pos);
    void Update(void* entity, const Vector& oldPos, const Vector& newPos);
    std::vector<void*> Query(const Vector& mins, const Vector& maxs) const;
    void QueryCallback(const Vector& mins, const Vector& maxs, 
                      const std::function<void(void*)>& callback) const;
    void Clear();
    size_t GetTotalEntities() const;
    size_t GetCellCount() const;
};

} // namespace SpatialPartitioning