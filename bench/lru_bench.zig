const std = @import("std");
const zds = @import("zds");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    const stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("\nLRUCache Benchmark (u32 keys, void values):\n", .{});
    try stdout.print("{s: >12} | {s: >25} | {s: >15} | {s: >15}\n", .{ "Count", "Scenario", "Time (ns)", "Ns/Op" });
    try stdout.print("{s:-<13}|{s:-<27}|{s:-<17}|{s:-<17}\n", .{ "", "", "", "" });

    const N = 1_000_000;
    const capacity = N / 2; // Force 50% eviction

    var lru = try zds.LRUCache(u32, void).init(allocator, capacity);
    defer lru.deinit();

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    // 1. Insert (Fill capacity)
    var timer = try std.time.Timer.start();
    for (0..capacity) |i| {
        try lru.put(@intCast(i), {});
    }
    const fill_time = timer.read();
    try stdout.print("{d: >12} | {s: >25} | {d: >15} | {d: >15}\n", .{
        capacity, "Fill (No Eviction)", fill_time, fill_time / capacity,
    });

    // 2. Insert with Eviction (Over capacity)
    timer.reset();
    for (capacity..N) |i| {
        try lru.put(@intCast(i), {});
    }
    const evict_ops = N - capacity;
    const evict_time = timer.read();
    try stdout.print("{d: >12} | {s: >25} | {d: >15} | {d: >15}\n", .{
        evict_ops, "Put (With Eviction)", evict_time, evict_time / evict_ops,
    });

    // 3. Get (Hit/Miss mix)
    timer.reset();
    for (0..N) |_| {
         const k = random.uintLessThan(u32, N); // 0 to N
         _ = lru.get(k);
    }
    const get_time = timer.read();
    try stdout.print("{d: >12} | {s: >25} | {d: >15} | {d: >15}\n", .{
        N, "Get (Random)", get_time, get_time / N,
    });
    try stdout.flush();
}
