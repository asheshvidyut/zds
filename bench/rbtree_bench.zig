const std = @import("std");
const zds = @import("zds");
const RBTree = zds.RBTree;

const U64Context = struct {
    pub fn cmp(self: @This(), a: u64, b: u64) std.math.Order {
        _ = self;
        return std.math.order(a, b);
    }
};

const U64Cmp = struct {
    fn compare(context: u64, item: u64) std.math.Order {
        return std.math.order(context, item);
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

    try stdout.print("\nRBTree Comparison Benchmark Results:\n", .{});
    try stdout.print("{s: >12} | {s: >25} | {s: >15} | {s: >15} | {s: >15} | {s: >15}\n", .{ "N", "Tree", "Insert (ns)", "Search (ns)", "Iterate (ns)", "Remove (ns)" });
    try stdout.print("{s:-<13}|{s:-<27}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}\n", .{ "", "", "", "", "", "" });

    const start_n: u64 = 100;
    const end_n: u64 = 100_000;
    var current_n = start_n;

    while (current_n <= end_n) : (current_n *= 10) {
        const numbers = try allocator.alloc(u64, current_n);
        defer allocator.free(numbers);

        var prng = std.Random.DefaultPrng.init(0);
        const random = prng.random();
        for (numbers) |*n| {
            n.* = random.int(u64);
        }
        // Test Sorted ArrayList
        {
            var list = std.ArrayListUnmanaged(u64){};
            defer list.deinit(allocator);

            var timer = try std.time.Timer.start();
            for (numbers) |n| {
                const idx = std.sort.upperBound(u64, list.items, n, U64Cmp.compare);
                try list.insert(allocator, idx, n);
            }
            const insert_time = timer.read();

            timer.reset();
            // 2. Search (Binary Search)
            var found: usize = 0;
            for (numbers) |n| {
                // binarySearch(T, items, context, compareFn)
                const idx = std.sort.binarySearch(u64, list.items, n, U64Cmp.compare);
                if (idx != null) found += 1;
            }
            const search_time = timer.read();

            timer.reset();
            // 3. Iterate (just walk the slice)
            var sum: u64 = 0;
            for (list.items) |item| {
                sum += item;
            }
            if (sum == 0) std.mem.doNotOptimizeAway(sum);
            const iter_time = timer.read();

            timer.reset();
            // 4. Remove (Search + Ordered Remove)
            // Note: This is O(N^2) total, so it might be slow for large N.
            // 4. Remove (Search + Ordered Remove) - Shuffle first
            var prng_remove = std.Random.DefaultPrng.init(0);
            const random_remove = prng_remove.random();
            random_remove.shuffle(u64, numbers);
            
            timer.reset();
            for (numbers) |n| {
                const idx = std.sort.binarySearch(u64, list.items, n, U64Cmp.compare);
                if (idx) |i| {
                    _ = list.orderedRemove(i);
                }
            }
            const remove_time = timer.read();

            try stdout.print("{d: >12} | {s: >25} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                current_n, "Sorted ArrayList", insert_time, search_time, iter_time, remove_time,
            });
        }


        // Test zds.RBTree
        {
            var tree = RBTree(u64, void).init(allocator, .{});
            defer tree.deinit();

            var timer = try std.time.Timer.start();
            for (numbers) |n| {
                try tree.insert(n, {});
            }
            const insert_time = timer.read();

            timer.reset();
            var found: usize = 0;
            for (numbers) |n| {
                if (tree.search(n)) |_| found += 1;
            }
            const search_time = timer.read();

            timer.reset();
            var it = tree.begin();
            var sum: u64 = 0;
            while (it.next()) |node| {
                sum += node.key;
            }
            if (sum == 0) std.mem.doNotOptimizeAway(sum);
            const iter_time = timer.read();

            timer.reset();
            // Shuffle before delete
            var prng_remove = std.Random.DefaultPrng.init(0);
            const random_remove = prng_remove.random();
            random_remove.shuffle(u64, numbers);

            timer.reset();
            for (numbers) |n| {
                _ = tree.deleteNode(n);
            }
            const remove_time = timer.read();

            try stdout.print("{d: >12} | {s: >25} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                current_n, "zds.RBTree", insert_time, search_time, iter_time, remove_time,
            });
        }



    }

    // String Benchmark (words.txt)
    {
        try stdout.print("\nString Benchmark Results (words.txt):\n", .{});
        try stdout.print("{s: >12} | {s: >25} | {s: >15} | {s: >15} | {s: >15} | {s: >15}\n", .{ "Count", "Tree", "Insert (ns)", "Search (ns)", "Iterate (ns)", "Remove (ns)" });
        try stdout.print("{s:-<13}|{s:-<27}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}\n", .{ "", "", "", "", "", "" });

        var words = std.ArrayListUnmanaged([]const u8){};
        defer words.deinit(allocator);

        // Try to find words.txt
        const paths = [_][]const u8{ "bench/words.txt", "words.txt", "/usr/share/dict/words" };
        var file: ?std.fs.File = null;
        for (paths) |path| {
            if (std.fs.cwd().openFile(path, .{})) |f| {
                file = f;
                break;
            } else |_| {}
        }

        if (file) |f| {
            defer f.close();
            // Read entire file (compatible with Zig master and 0.13+)
            const stat = try f.stat();
            const content = try allocator.alloc(u8, stat.size);
            errdefer allocator.free(content);
            var total_read: usize = 0;
            while (true) {
                const n = try f.read(content[total_read..]);
                if (n == 0) break;
                total_read += n;
            }
            defer allocator.free(content);

            var it = std.mem.tokenizeAny(u8, content, "\n\r");
            while (it.next()) |word| {
                try words.append(allocator, word);
            }

            const total_words = words.items.len;

            // Test Sorted ArrayList (Batch)
            {
                var list = std.ArrayListUnmanaged([]const u8){};
                defer list.deinit(allocator);

                var timer = try std.time.Timer.start();
                for (words.items) |word| {
                    const idx = std.sort.upperBound([]const u8, list.items, word, StringContext.compare);
                    try list.insert(allocator, idx, word);
                }
                const insert_time = timer.read();

                timer.reset();
                var found: usize = 0;
                for (words.items) |word| {
                    if (std.sort.binarySearch([]const u8, list.items, word, StringContext.compare)) |_| {
                        found += 1;
                    }
                }
                const search_time = timer.read();

                timer.reset();
                var sum: usize = 0;
                for (list.items) |item| sum += item.len;
                if (sum == 0) std.mem.doNotOptimizeAway(sum);
                const iter_time = timer.read();


                
                // 4. Remove (Search + Ordered Remove) - Shuffle first
                const keys_to_remove = try allocator.dupe([]const u8, words.items);
                defer allocator.free(keys_to_remove);
                var prng_remove = std.Random.DefaultPrng.init(0);
                const random_remove = prng_remove.random();
                random_remove.shuffle([]const u8, keys_to_remove);

                timer.reset();
                for (keys_to_remove) |word| {
                    const idx = std.sort.binarySearch([]const u8, list.items, word, StringContext.compare);
                    if (idx) |i| {
                        _ = list.orderedRemove(i);
                    }
                }
                const remove_time = timer.read();

                try stdout.print("{d: >12} | {s: >25} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                    total_words, "Sorted ArrayList", insert_time, search_time, iter_time, remove_time,
                });
            }

            // Test zds.RBTree
            {
                var tree = RBTree([]const u8, void).init(allocator, .{});
                defer tree.deinit();

                var timer = try std.time.Timer.start();
                for (words.items) |word| {
                    try tree.insert(word, {});
                }
                const insert_time = timer.read();

                timer.reset();
                var found: usize = 0;
                for (words.items) |word| {
                    if (tree.search(word)) |_| found += 1;
                }
                const search_time = timer.read();

                timer.reset();
                var it_tree = tree.begin();
                var sum: usize = 0;
                while (it_tree.next()) |node| sum += node.key.len;
                if (sum == 0) std.mem.doNotOptimizeAway(sum);
                const iter_time = timer.read();

                // Removing from RBTree is fast enough to run
                // Removing from RBTree is fast enough to run
                timer.reset();
                // Shuffle words before delete
                const keys_to_remove = try allocator.dupe([]const u8, words.items);
                defer allocator.free(keys_to_remove);
                var prng_remove = std.Random.DefaultPrng.init(0);
                const random_remove = prng_remove.random();
                random_remove.shuffle([]const u8, keys_to_remove);

                timer.reset();
                for (keys_to_remove) |word| {
                    _ = tree.deleteNode(word);
                }
                const remove_time = timer.read();

                try stdout.print("{d: >12} | {s: >25} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                    total_words, "zds.RBTree", insert_time, search_time, iter_time, remove_time,
                });
            }
        } else {
            try stdout.print("Skipping String benchmark (words.txt not found)\n", .{});
        }
    }

    // UUID Benchmark
    {
        try stdout.print("\nUUID Benchmark Results:\n", .{});
        try stdout.print("{s: >12} | {s: >25} | {s: >15} | {s: >15} | {s: >15} | {s: >15}\n", .{ "N", "Tree", "Insert (ns)", "Search (ns)", "Iterate (ns)", "Remove (ns)" });
        try stdout.print("{s:-<13}|{s:-<27}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}\n", .{ "", "", "", "", "", "" });

        var current_uuid_n: u64 = 100;
        const end_n_uuid: u64 = 100_000; // Limit UUIDs to 100k for speed

        while (current_uuid_n <= end_n_uuid) : (current_uuid_n *= 10) {
            const uuids = try allocator.alloc(u128, current_uuid_n);
            defer allocator.free(uuids);
            
            var prng = std.Random.DefaultPrng.init(0);
            const random = prng.random();
            for (uuids) |*u| u.* = random.int(u128);

            // Test Sorted ArrayList
            {
                var list = std.ArrayListUnmanaged(u128){};
                defer list.deinit(allocator);

                var timer = try std.time.Timer.start();
                for (uuids) |u| {
                    const idx = std.sort.upperBound(u128, list.items, u, UuidContext.compare);
                    try list.insert(allocator, idx, u);
                }
                const insert_time = timer.read();

                timer.reset();
                var found: usize = 0;
                for (uuids) |u| {
                    if (std.sort.binarySearch(u128, list.items, u, UuidContext.compare)) |_| found += 1;
                }
                const search_time = timer.read();

                // 3. Iterate
                timer.reset();
                var sum: u128 = 0;
                for (list.items) |u| sum = sum +% u;
                if (sum == 0) std.mem.doNotOptimizeAway(sum);
                const iter_time = timer.read();



                // 4. Remove (Search + Ordered Remove) - Shuffle first
                const keys_to_remove = try allocator.dupe(u128, uuids);
                defer allocator.free(keys_to_remove);
                var prng_remove = std.Random.DefaultPrng.init(0);
                const random_remove = prng_remove.random();
                random_remove.shuffle(u128, keys_to_remove);

                timer.reset();
                for (keys_to_remove) |u| {
                    const idx = std.sort.binarySearch(u128, list.items, u, UuidContext.compare);
                    if (idx) |i| {
                        _ = list.orderedRemove(i);
                    }
                }
                const remove_time = timer.read();

                 try stdout.print("{d: >12} | {s: >25} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                    current_uuid_n, "Sorted ArrayList", insert_time, search_time, iter_time, remove_time,
                });
            }

            // Test zds.RBTree
            {
                var tree = RBTree(u128, void).init(allocator, .{});
                defer tree.deinit();

                var timer = try std.time.Timer.start();
                for (uuids) |u| {
                    try tree.insert(u, {});
                }
                const insert_time = timer.read();

                timer.reset();
                var found: usize = 0;
                for (uuids) |u| {
                    if (tree.search(u)) |_| found += 1;
                }
                const search_time = timer.read();

                timer.reset();
                var it_tree = tree.begin();
                var sum: u128 = 0;
                while (it_tree.next()) |node| sum = sum +% node.key;
                const iter_time = timer.read();
                if (sum == 0) std.mem.doNotOptimizeAway(sum);

                timer.reset();
                // Shuffle before delete
                const keys_to_remove = try allocator.dupe(u128, uuids);
                defer allocator.free(keys_to_remove);
                var prng_remove = std.Random.DefaultPrng.init(0);
                const random_remove = prng_remove.random();
                random_remove.shuffle(u128, keys_to_remove);
 
                timer.reset();
                for (keys_to_remove) |u| {
                    _ = tree.deleteNode(u);
                }
                const remove_time = timer.read();

                try stdout.print("{d: >12} | {s: >25} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
                    current_uuid_n, "zds.RBTree", insert_time, search_time, iter_time, remove_time,
                });
            }
        }
    }

    try stdout.flush();
}

const StringContext = struct {
    pub fn cmp(self: @This(), a: []const u8, b: []const u8) std.math.Order {
        _ = self;
        return std.mem.order(u8, a, b);
    }
    // For std.sort.binarySearch and upperBound
    pub fn compare(key: []const u8, item: []const u8) std.math.Order {
        return std.mem.order(u8, key, item);
    }
    // For std.mem.sort
    pub fn cmp_bool(ctx: void, a: []const u8, b: []const u8) bool {
        _ = ctx;
        return std.mem.order(u8, a, b) == .lt;
    }
};

const UuidContext = struct {
    pub fn cmp(self: @This(), a: u128, b: u128) std.math.Order {
        _ = self;
        return std.math.order(a, b);
    }
    pub fn compare(key: u128, item: u128) std.math.Order {
        return std.math.order(key, item);
    }
};
