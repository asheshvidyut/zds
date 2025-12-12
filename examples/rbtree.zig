const std = @import("std");
const zds = @import("zds");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== RBTree Example ===\n", .{});

    // 1. Simple Usage: RBTree(K, V) with default context
    {
        std.debug.print("\n1. Basic Usage (u32 -> []const u8):\n", .{});
        const Tree = zds.RBTree(u32, []const u8);
        var tree = Tree.init(allocator, .{});
        defer tree.deinit();

        // Insert
        try tree.insert(10, "Ten");
        try tree.insert(5, "Five");
        try tree.insert(15, "Fifteen");
        
        std.debug.print("   Inserted: 10, 5, 15\n", .{});

        // Search
        if (tree.search(5)) |node| {
            std.debug.print("   Search(5): Found \"{s}\"\n", .{node.value});
        }

        // Iterate
        std.debug.print("   Iterate (Sorted):\n", .{});
        var it = tree.iterator();
        while (it.next()) |node| {
            std.debug.print("      {d} -> {s}\n", .{node.key, node.value});
        }

        // Delete
        _ = tree.delete(5);
        std.debug.print("   Deleted 5. New count: {d}\n", .{tree.count()});

        // Iterate
        std.debug.print("   Iterate (Sorted):\n", .{});
        it = tree.iterator();
        while (it.next()) |node| {
            std.debug.print("      {d} -> {s}\n", .{node.key, node.value});
        }
        // Re-insert 5 for Range Queries demo
        try tree.insert(5, "Five");

        // Range Queries
        std.debug.print("   Range Queries:\n", .{});
        if (tree.ceiling(9)) |node| std.debug.print("      Ceiling(9): {d}\n", .{node.key}); // Expected 10
        if (tree.floor(12)) |node| std.debug.print("      Floor(12): {d}\n", .{node.key});   // Expected 10
        if (tree.higher(10)) |node| std.debug.print("      Higher(10): {d}\n", .{node.key}); // Expected 15
        if (tree.lower(10)) |node| std.debug.print("      Lower(10): {d}\n", .{node.key});   // Expected 5
    }

    // 2. Custom Context Usage: RBTreeWithOptions
    {
        std.debug.print("\n2. Custom Context (Descending Order):\n", .{});
        
        const DescendingContext = struct {
            pub fn cmp(self: @This(), a: u32, b: u32) std.math.Order {
                _ = self;
                // Reverse order: b compared to a
                return std.math.order(b, a);
            }
        };

        const DescTree = zds.RBTreeWithOptions(u32, void, DescendingContext);
        var tree = DescTree.init(allocator, .{});
        defer tree.deinit();

        try tree.insert(10, {});
        try tree.insert(5, {});
        try tree.insert(20, {});

        std.debug.print("   Inserted: 10, 5, 20\n", .{});
        std.debug.print("   Iterate (Descending):\n", .{});

        var it = tree.iterator();
        while (it.next()) |node| {
            std.debug.print("      {d}\n", .{node.key});
        }
    }
}
