const std = @import("std");
const zds = @import("zds");
const SwissMap = zds.SwissMap;
const SwissMapWithOptions = zds.SwissMapWithOptions;

const Point = struct {
    x: u32,
    y: u32,
};

const PointContext = struct {
    pub fn hash(self: @This(), key: Point) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&key.x));
        hasher.update(std.mem.asBytes(&key.y));
        return hasher.final();
    }
    pub fn eql(self: @This(), a: Point, b: Point) bool {
        _ = self;
        return a.x == b.x and a.y == b.y;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const start_n: u64 = 100;
    const end_n: u64 = 1000_000;
    var current_n = start_n;

    // Integer Benchmarks
    try stdout.print("\nInteger Benchmark Results:\n", .{});
    try stdout.print("{s: >12} | {s: >15} | {s: >15} | {s: >15} | {s: >15} | {s: >15}\n", .{ "N", "Map", "Put (ns)", "Get (ns)", "Iterate (ns)", "Remove (ns)" });
    try stdout.print("{s:-<13}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}\n", .{ "", "", "", "", "", "" });

    while (current_n <= end_n) : (current_n *= 10) {
        // std.AutoHashMap
        {
            var map = std.AutoHashMap(u64, u64).init(allocator);
            defer map.deinit();

            var timer = try std.time.Timer.start();
            var i: u64 = 0;
            while (i < current_n) : (i += 1) {
                try map.put(i, i);
            }
            const put_time = timer.read();

            timer.reset();
            i = 0;
            var found: u64 = 0;
            while (i < current_n) : (i += 1) {
                if (map.contains(i)) found += 1;
            }
            if (found != current_n) @panic("Verification failed");
            const get_time = timer.read();

            timer.reset();
            var iter = map.iterator();
            var sum: u64 = 0;
            while (iter.next()) |entry| {
                sum += entry.key_ptr.* + entry.value_ptr.*;
            }
            if (sum == 0) std.mem.doNotOptimizeAway(sum); // ensure logic runs
            const iter_time = timer.read();

            timer.reset();
            i = 0;
            while (i < current_n) : (i += 1) {
                _ = map.remove(i);
            }
            const remove_time = timer.read();

            try stdout.print("{d: >12} | {s: >15} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                current_n, "std.AutoHashMap", put_time, get_time, iter_time, remove_time,
            });
        }

        // zds.SwissMap
        {
            var map = SwissMap(u64, u64).init(allocator);
            defer map.deinit();

            var timer = try std.time.Timer.start();
            var i: u64 = 0;
            while (i < current_n) : (i += 1) {
                try map.put(i, i);
            }
            const put_time = timer.read();

            timer.reset();
            i = 0;
            var found: u64 = 0;
            while (i < current_n) : (i += 1) {
                if (map.get(i)) |_| found += 1;
            }
            if (found != current_n) @panic("Verification failed");
            const get_time = timer.read();

            timer.reset();
            var iter = map.iterator();
            var sum: u64 = 0;
            while (iter.next()) |entry| {
                sum += entry.key_ptr.* + entry.value_ptr.*;
            }
            if (sum == 0) std.mem.doNotOptimizeAway(sum);
            const iter_time = timer.read();

            timer.reset();
            i = 0;
            while (i < current_n) : (i += 1) {
                _ = map.remove(i);
            }
            const remove_time = timer.read();

            try stdout.print("{d: >12} | {s: >15} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                current_n, "zds.SwissMap", put_time, get_time, iter_time, remove_time,
            });
        }
    }

    // String Benchmark with words.txt
    {
        try stdout.print("\nString Benchmark Results (words.txt):\n", .{});

        const file = std.fs.cwd().openFile("bench/words.txt", .{}) catch |err| blk: {
            if (err == error.FileNotFound) {
                if (std.fs.cwd().openFile("words.txt", .{})) |f| {
                    break :blk f;
                } else |_| {}
                break :blk try std.fs.openFileAbsolute("/usr/share/dict/words", .{});
            }
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        const content = try allocator.alloc(u8, stat.size);
        var total_read: usize = 0;
        while (total_read < content.len) {
            const n = try file.read(content[total_read..]);
            if (n == 0) break;
            total_read += n;
        }
        if (total_read != stat.size) {
             // allow partial if EOF reached early?
        }
        defer allocator.free(content);

        var lines = std.ArrayListUnmanaged([]const u8){};
        defer lines.deinit(allocator);

        var it = std.mem.tokenizeAny(u8, content, "\n\r");
        while (it.next()) |line| {
            try lines.append(allocator, line);
        }
        const total_words = lines.items.len;
        try stdout.print("Loaded {d} words\n", .{total_words});
        try stdout.print("{s: >12} | {s: >15} | {s: >15} | {s: >15} | {s: >15} | {s: >15}\n", .{ "Words", "Map", "Put (ns)", "Get (ns)", "Iterate (ns)", "Remove (ns)" });
        try stdout.print("{s:-<13}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}\n", .{ "", "", "", "", "", "" });

        // Test std.StringHashMap
        {
            var map = std.StringHashMap(usize).init(allocator);
            defer map.deinit();

            var timer = try std.time.Timer.start();
            for (lines.items, 0..) |word, i| {
                try map.put(word, i);
            }
            const put_time = timer.read();

            timer.reset();
            var matches: usize = 0;
            for (lines.items) |word| {
                if (map.get(word)) |_| {
                    matches += 1;
                }
            }
            if (matches != total_words) @panic("Verification failed");
            const get_time = timer.read();

            timer.reset();
            var iter = map.iterator();
            var sum: u64 = 0;
            while (iter.next()) |entry| {
                sum += entry.key_ptr.*.len + entry.value_ptr.*;
            }
            if (sum == 0) std.mem.doNotOptimizeAway(sum);
            const iter_time = timer.read();

            timer.reset();
            for (lines.items) |word| {
                _ = map.remove(word);
            }
            const remove_time = timer.read();

            try stdout.print("{d: >12} | {s: >15} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                total_words, "std.StringMap", put_time, get_time, iter_time, remove_time,
            });
        }

        // Test SwissMap
        {
            // Key=String, Value=LineNumber (usize)
            var map = SwissMap([]const u8, usize).init(allocator);
            defer map.deinit();

            var timer = try std.time.Timer.start();
            for (lines.items, 0..) |word, i| {
                try map.put(word, i);
            }
            const put_time = timer.read();

            // Verification and Get Timing
            timer.reset();
            var matches: usize = 0;
            for (lines.items) |word| {
                if (map.get(word)) |val| {
                    // Handle duplicates: if the list has duplicates, map has the LAST index.
                    // we should check if lines.items[val] is the same word.
                    if (std.mem.eql(u8, lines.items[val], word)) {
                        matches += 1;
                    } else {
                        try stdout.print("Error: Mismatch for '{s}', got line {d} which is '{s}'\n", .{ word, val, lines.items[val] });
                        return error.VerificationFailed;
                    }
                } else {
                    try stdout.print("Error: Word '{s}' not found!\n", .{word});
                    return error.VerificationFailed;
                }
            }
            if (matches != total_words) @panic("Verification failed");
            const get_time = timer.read();

            timer.reset();
            var iter = map.iterator();
            var sum: u64 = 0;
            while (iter.next()) |entry| {
                sum += entry.key_ptr.*.len + entry.value_ptr.*;
            }
            if (sum == 0) std.mem.doNotOptimizeAway(sum);
            const iter_time = timer.read();

            timer.reset();
            for (lines.items) |word| {
                _ = map.remove(word);
            }
            const remove_time = timer.read();

            try stdout.print("{d: >12} | {s: >15} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                total_words, "zds.SwissMap", put_time, get_time, iter_time, remove_time,
            });
        }
    }

    // UUID Benchmark (u128)
    {
        try stdout.print("\nUUID Benchmark Results:\n", .{});
        try stdout.print("{s: >12} | {s: >15} | {s: >15} | {s: >15} | {s: >15} | {s: >15}\n", .{ "Count", "Map", "Put (ns)", "Get (ns)", "Iterate (ns)", "Remove (ns)" });
        try stdout.print("{s:-<13}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}\n", .{ "", "", "", "", "", "" });

        var current_uuid_n: u64 = 100;
        const max_uuid_n: u64 = 1_000_000;

        while (current_uuid_n <= max_uuid_n) : (current_uuid_n *= 10) {
            var uuids = std.ArrayListUnmanaged(u128){};
            defer uuids.deinit(allocator);
            try uuids.ensureTotalCapacity(allocator, current_uuid_n);

            var prng = std.Random.DefaultPrng.init(0);
            const random = prng.random();
            for (0..current_uuid_n) |_| {
                uuids.appendAssumeCapacity(random.int(u128));
            }

            // Test std.AutoHashMap(u128, u64)
            {
                var map = std.AutoHashMap(u128, u64).init(allocator);
                defer map.deinit();

                var timer = try std.time.Timer.start();
                for (uuids.items, 0..) |uuid, i| {
                    try map.put(uuid, i);
                }
                const put_time = timer.read();

                timer.reset();
                var matches: usize = 0;
                for (uuids.items) |uuid| {
                    if (map.contains(uuid)) matches += 1;
                }
                if (matches != current_uuid_n) @panic("Verification failed");
                const get_time = timer.read();

                timer.reset();
                var iter = map.iterator();
                var sum: u64 = 0;
                while (iter.next()) |entry| {
                    sum += entry.value_ptr.*;
                }
                if (sum == 0) std.mem.doNotOptimizeAway(sum);
                const iter_time = timer.read();

                timer.reset();
                for (uuids.items) |uuid| {
                    _ = map.remove(uuid);
                }
                const remove_time = timer.read();

                try stdout.print("{d: >12} | {s: >15} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                    current_uuid_n, "std.AutoHashMap", put_time, get_time, iter_time, remove_time,
                });
            }

            // Test SwissMap(u128, u64)
            {
                var map = SwissMap(u128, u64).init(allocator);
                defer map.deinit();

                var timer = try std.time.Timer.start();
                for (uuids.items, 0..) |uuid, i| {
                    try map.put(uuid, i);
                }
                const put_time = timer.read();

                timer.reset();
                var matches: usize = 0;
                for (uuids.items) |uuid| {
                    if (map.get(uuid)) |_| matches += 1;
                }
                if (matches != current_uuid_n) @panic("Verification failed");
                const get_time = timer.read();

                timer.reset();
                var iter = map.iterator();
                var sum: u64 = 0;
                while (iter.next()) |entry| {
                    sum += entry.value_ptr.*;
                }
                if (sum == 0) std.mem.doNotOptimizeAway(sum);
                const iter_time = timer.read();

                timer.reset();
                for (uuids.items) |uuid| {
                    _ = map.remove(uuid);
                }
                const remove_time = timer.read();

                try stdout.print("{d: >12} | {s: >15} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                    current_uuid_n, "zds.SwissMap", put_time, get_time, iter_time, remove_time,
                });
            }
        }
    }

    // Point Struct Benchmark
    {
        try stdout.print("\nPoint Struct Benchmark Results (x, y):\n", .{});
        try stdout.print("{s: >12} | {s: >15} | {s: >15} | {s: >15} | {s: >15} | {s: >15}\n", .{ "Count", "Map", "Put (ns)", "Get (ns)", "Iterate (ns)", "Remove (ns)" });
        try stdout.print("{s:-<13}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}\n", .{ "", "", "", "", "", "" });

        var current_point_n: u64 = 100;
        const max_point_n: u64 = 1_000_000;

        while (current_point_n <= max_point_n) : (current_point_n *= 10) {
            var points = std.ArrayListUnmanaged(Point){};
            defer points.deinit(allocator);
            try points.ensureTotalCapacity(allocator, current_point_n);

            var prng = std.Random.DefaultPrng.init(0);
            const random = prng.random();
            for (0..current_point_n) |_| {
                points.appendAssumeCapacity(.{
                    .x = random.int(u32),
                    .y = random.int(u32),
                });
            }

            // Test std.HashMap(Point, u64, PointContext, 80)
            {
                var map = std.HashMap(Point, u64, PointContext, 80).init(allocator);
                defer map.deinit();

                var timer = try std.time.Timer.start();
                for (points.items, 0..) |p, i| {
                    try map.put(p, i);
                }
                const put_time = timer.read();

                timer.reset();
                var matches: usize = 0;
                for (points.items) |p| {
                    if (map.contains(p)) matches += 1;
                }
                if (matches != current_point_n) @panic("Verification failed");
                const get_time = timer.read();

                timer.reset();
                var iter = map.iterator();
                var sum: u64 = 0;
                while (iter.next()) |entry| {
                    sum += entry.value_ptr.*;
                }
                if (sum == 0) std.mem.doNotOptimizeAway(sum);
                const iter_time = timer.read();

                timer.reset();
                for (points.items) |p| {
                    _ = map.remove(p);
                }
                const remove_time = timer.read();

                try stdout.print("{d: >12} | {s: >15} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                    current_point_n, "std.HashMap", put_time, get_time, iter_time, remove_time,
                });
            }

            // Test SwissMapWithOptions(Point, u64, PointContext, 80)
            {
                var map = SwissMapWithOptions(Point, u64, PointContext, 80).init(allocator);
                defer map.deinit();

                var timer = try std.time.Timer.start();
                for (points.items, 0..) |p, i| {
                    try map.put(p, i);
                }
                const put_time = timer.read();

                timer.reset();
                var matches: usize = 0;
                for (points.items) |p| {
                     if (map.get(p)) |_| matches += 1;
                }
                if (matches != current_point_n) @panic("Verification failed");
                const get_time = timer.read();

                timer.reset();
                var iter = map.iterator();
                var sum: u64 = 0;
                while (iter.next()) |entry| {
                    sum += entry.value_ptr.*;
                }
                if (sum == 0) std.mem.doNotOptimizeAway(sum);
                const iter_time = timer.read();

                timer.reset();
                for (points.items) |p| {
                    _ = map.remove(p);
                }
                const remove_time = timer.read();

                try stdout.print("{d: >12} | {s: >15} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                    current_point_n, "zds.SwissMap", put_time, get_time, iter_time, remove_time,
                });
            }
        }
    }

    // Bad Hash Benchmark
    {
        try stdout.print("\nBad Hash Benchmark Results (Mod 1024 Collision):\n", .{});
        try stdout.print("{s: >12} | {s: >15} | {s: >15} | {s: >15} | {s: >15} | {s: >15}\n", .{ "Count", "Map", "Put (ns)", "Get (ns)", "Iterate (ns)", "Remove (ns)" });
        try stdout.print("{s:-<13}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}\n", .{ "", "", "", "", "", "" });

        var current_bad_n: u64 = 100;
        const max_bad_n: u64 = 100_000; // Lower max because O(N) chains will be slow

        const BadContext = struct {
            pub fn hash(self: @This(), key: u64) u64 {
                _ = self;
                return key % 1024; // Extreme collisions
            }
            pub fn eql(self: @This(), a: u64, b: u64) bool {
                _ = self;
                return a == b;
            }
        };

        while (current_bad_n <= max_bad_n) : (current_bad_n *= 10) {
            // Test std.HashMap with BadContext
            {
                var map = std.HashMap(u64, u64, BadContext, 80).init(allocator);
                defer map.deinit();

                var timer = try std.time.Timer.start();
                var i: u64 = 0;
                while (i < current_bad_n) : (i += 1) {
                    try map.put(i, i);
                }
                const put_time = timer.read();

                timer.reset();
                i = 0;
                var found: u64 = 0;
                while (i < current_bad_n) : (i += 1) {
                    if (map.contains(i)) found += 1;
                }
                if (found != current_bad_n) @panic("Verification failed");
                const get_time = timer.read();

                timer.reset();
                var iter = map.iterator();
                var sum: u64 = 0;
                while (iter.next()) |entry| {
                    sum += entry.value_ptr.*;
                }
                if (sum == 0) std.mem.doNotOptimizeAway(sum);
                const iter_time = timer.read();

                timer.reset();
                i = 0;
                while (i < current_bad_n) : (i += 1) {
                    _ = map.remove(i);
                }
                const remove_time = timer.read();

                try stdout.print("{d: >12} | {s: >15} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                    current_bad_n, "std.HashMap", put_time, get_time, iter_time, remove_time,
                });
            }

            // Test SwissMapWithOptions with BadContext
            {
                var map = SwissMapWithOptions(u64, u64, BadContext, 80).init(allocator);
                defer map.deinit();

                var timer = try std.time.Timer.start();
                var i: u64 = 0;
                while (i < current_bad_n) : (i += 1) {
                    try map.put(i, i);
                }
                const put_time = timer.read();

                timer.reset();
                i = 0;
                var found: u64 = 0;
                while (i < current_bad_n) : (i += 1) {
                    if (map.get(i)) |_| found += 1;
                }
                if (found != current_bad_n) @panic("Verification failed");
                const get_time = timer.read();

                timer.reset();
                var iter = map.iterator();
                var sum: u64 = 0;
                while (iter.next()) |entry| {
                    sum += entry.value_ptr.*;
                }
                if (sum == 0) std.mem.doNotOptimizeAway(sum);
                const iter_time = timer.read();

                timer.reset();
                i = 0;
                while (i < current_bad_n) : (i += 1) {
                    _ = map.remove(i);
                }
                const remove_time = timer.read();

                try stdout.print("{d: >12} | {s: >15} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                    current_bad_n, "zds.SwissMap", put_time, get_time, iter_time, remove_time,
                });
            }
        }
    }

    try stdout.flush();
}
