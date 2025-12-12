//! Least Recently Used (LRU) Cache example.
//!
//! Implementation Features:
//! - **O(1) Access**: Uses `zds.SwissMap` for fast key lookups.
//! - **O(1) Eviction**: Uses a custom intrusive doubly linked list to track usage order.
//! - **Memory Recycling**: Reuses internal nodes upon eviction to reduce memory allocation overhead.
//! - **Generics**: Supports any key/value types.
//!
//! Note: This data structure is **not thread-safe**.

const std = @import("std");
const zds = @import("zds");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== LRUCache Example ===\n", .{});

    // Initialize LRU with capacity 2
    var lru = try zds.LRUCache(u32, []const u8).init(allocator, 2);
    defer lru.deinit();

    // 1. Put
    std.debug.print("\n   Inserting keys...\n", .{});
    try lru.put(1, "one");
    try lru.put(2, "two");
    
    std.debug.print("   Count: {d}\n", .{lru.count()}); // 2

    // 2. Get (updates LRU)
    if (lru.get(1)) |val| {
        std.debug.print("   Get(1): Found \"{s}\"\n", .{val});
    }

    // 3. Put causing eviction
    std.debug.print("   Inserting key 3 (should evict 2)...\n", .{});
    try lru.put(3, "three");

    if (lru.get(2)) |_| {
        std.debug.print("   Error: 2 should be evicted!\n", .{});
    } else {
        std.debug.print("   Verified: 2 was evicted.\n", .{});
    }

    if (lru.get(1)) |val| {
         std.debug.print("   Get(1): Still exists \"{s}\"\n", .{val});
    }
    if (lru.get(3)) |val| {
         std.debug.print("   Get(3): Found \"{s}\"\n", .{val});
    }

    // 4. Update existing
    try lru.put(1, "ONE_UPDATED");
    if (lru.get(1)) |val| {
         std.debug.print("   Updated(1): \"{s}\"\n", .{val});
    }
}
