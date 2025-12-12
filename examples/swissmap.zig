const std = @import("std");
const zds = @import("zds");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== SwissMap Example ===\n", .{});

    const Map = zds.SwissMap(u32, []const u8);
    var map = Map.init(allocator);
    defer map.deinit();

    // Insert
    try map.put(1, "one");
    try map.put(2, "two");
    try map.put(3, "three");

    std.debug.print("\n   Inserted: 1, 2, 3\n", .{});
    std.debug.print("   Count: {d}\n", .{map.count()});

    // Search
    if (map.get(2)) |val| {
        std.debug.print("   Search(2): Found \"{s}\"\n", .{val});
    }

    // Iterate
    std.debug.print("   Iterate:\n", .{});
    var it = map.iterator();
    while (it.next()) |entry| {
        std.debug.print("      {d} => {s}\n", .{entry.key_ptr.*, entry.value_ptr.*});
    }

    // Remove
    if (map.remove(1)) {
        std.debug.print("   Removed key 1\n", .{});
    }

    // Iterate after remove
    std.debug.print("   Iterate after remove:\n", .{});
    var it2 = map.iterator();
    while (it2.next()) |entry| {
        std.debug.print("      {d} => {s}\n", .{entry.key_ptr.*, entry.value_ptr.*});
    }
}
