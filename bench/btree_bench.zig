const std = @import("std");
const zds = @import("zds");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const N: usize = 1_000_000;
    std.debug.print("BTree Benchmark (N={d})\n", .{N});

    var tree = zds.BTree(u32, u32).init(allocator, .{}, 64);
    defer tree.deinit();

    // Insert
    var timer = try std.time.Timer.start();
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        try tree.insert(i, i);
    }
    const insert_time = timer.read();
    std.debug.print("Insert: {d} ms ({d} ns/op)\n", .{ insert_time / 1_000_000, insert_time / N });

    // Search
    timer.reset();
    i = 0;
    while (i < N) : (i += 1) {
        _ = tree.search(i);
    }
    const search_time = timer.read();
    std.debug.print("Search: {d} ms ({d} ns/op)\n", .{ search_time / 1_000_000, search_time / N });

    // Iterator
    timer.reset();
    var it = tree.iterator();
    defer it.deinit();
    var count: usize = 0;
    while (it.next()) |_| {
        count += 1;
    }
    const iter_time = timer.read();
    std.debug.print("Iterate: {d} ms ({d} ns/op)\n", .{ iter_time / 1_000_000, iter_time / N });
}
