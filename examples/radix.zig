const std = @import("std");
const zds = @import("zds");
const RadixTree = zds.RadixTree;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== RadixTree Example ===\n", .{});

    var tree = try RadixTree([]const u8, i32).init(allocator);
    defer tree.deinit();

    std.debug.print("\n   Inserting keys...\n", .{});
    try tree.insert("apple", 1);
    try tree.insert("app", 2);
    try tree.insert("banana", 3);
    try tree.insert("bandana", 4);

    {
        std.debug.print("   Iterating after insert:\n", .{});
        var it = tree.iterator();
        defer it.deinit();
        while (it.next()) |entry| {
            std.debug.print("      {s}: {d}\n", .{entry.key, entry.value});
        }
    }

    // 2. Get
    if (tree.get("apple")) |v| {
        std.debug.print("   Found 'apple': {d}\n", .{v}); // Expected: 1
    }

    // 3. Longest Prefix
    const query = "applepie";
    if (tree.longestPrefix(query)) |v| {
        std.debug.print("   Longest prefix of '{s}' has value: {d}\n", .{query, v}); // Expected: 1 (apple)
    }

    // 4. K-th Node
    std.debug.print("   Order statistics (K-th node):\n", .{});
    // Sorted keys: "app" (2), "apple" (1), "banana" (3), "bandana" (4)
    if (tree.getAtIndex(0)) |v| std.debug.print("      0-th (1st) value: {d}\n", .{v}); // 2
    if (tree.getAtIndex(1)) |v| std.debug.print("      1-st (2nd) value: {d}\n", .{v}); // 1

    // 5. Delete
    std.debug.print("   Deleting 'app'...\n", .{});
    const deleted = tree.delete("app");
    std.debug.print("   Deleted? {any}\n", .{deleted});

    if (tree.get("app")) |_| {
        std.debug.print("   Error: 'app' should be gone!\n", .{});
    } else {
        std.debug.print("   'app' correctly removed.\n", .{});
    }
    
    if (tree.get("apple")) |v| {
        std.debug.print("   'apple' still exists: {d}\n", .{v});
    }

    // 6. Iterator
    std.debug.print("   Iterating all keys:\n", .{});
    var it = tree.iterator();
    defer it.deinit();
    
    while (it.next()) |entry| {
        std.debug.print("      {s}: {d}\n", .{entry.key, entry.value});
    }
}
