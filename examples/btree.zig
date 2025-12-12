const std = @import("std");
const zds = @import("zds");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tree = zds.BTree(u32, []const u8).init(allocator, .{}, 32);
    defer tree.deinit();

    // Insert
    try tree.insert(1, "one");
    try tree.insert(2, "two");
    try tree.insert(3, "three");

    // Search
    if (tree.search(2)) |v| {
        std.debug.print("Found: {s}\n", .{v});
    }

    // Iterator
    var it = tree.iterator();
    defer it.deinit();
    while (it.next()) |entry| {
        std.debug.print("{d}: {s}\n", .{entry.key, entry.value});
    }
}
