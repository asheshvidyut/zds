const std = @import("std");
const zds = @import("zds");
const RadixTree = zds.RadixTree;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var stdout_writer = stdout_file.writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("\nRadixTree vs Sorted ArrayList Benchmark (String Keys):\n", .{});
    try stdout.print("{s: >12} | {s: >25} | {s: >15} | {s: >15} | {s: >15} | {s: >15}\n", .{ "Count", "Structure", "Insert (ns)", "Search (ns)", "LP (ns)", "Iterate (ns)" });
    try stdout.print("{s:-<13}|{s:-<27}|{s:-<17}|{s:-<17}|{s:-<17}|{s:-<17}\n", .{ "", "", "", "", "", "" });

    // Load words
    var words = std.ArrayListUnmanaged([]const u8){};
    defer words.deinit(allocator);

    const paths = [_][]const u8{ "bench/words.txt", "words.txt", "/usr/share/dict/words" };
    var file: ?std.fs.File = null;
    for (paths) |path| {
        if (std.fs.cwd().openFile(path, .{})) |f| {
            file = f;
            break;
        } else |_| {}
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    if (file) |f| {
        defer f.close();
        const stat = try f.stat();
        const content = try arena_alloc.alloc(u8, stat.size);
        // errdefer not needed for arena
        
        var total_read: usize = 0;
        while (true) {
            const n = try f.read(content[total_read..]);
            if (n == 0) break;
            total_read += n;
        }

        var it = std.mem.tokenizeAny(u8, content, "\n\r");
        while (it.next()) |word| {
            try words.append(allocator, word);
        }
    } else {
        try stdout.print("words.txt not found. Generating synthetic keys.\n", .{});
        // Generate synthetic keys if words.txt missing
        var prng = std.Random.DefaultPrng.init(0);
        const random = prng.random();
        const synthetic_count = 100_000;
        const alphabet = "abcdefghijklmnopqrstuvwxyz";

        for (0..synthetic_count) |_| {
            const len = random.intRangeAtMost(usize, 5, 15);
            const word = try arena_alloc.alloc(u8, len);
            for (word) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
            try words.append(allocator, word);
        }
    }

    const total_words = words.items.len;
    if (total_words == 0) {
        try stdout.print("No keys to benchmark.\n", .{});
        return;
    }

    // 1. Radix Tree Benchmark
    {
        var tree = try RadixTree([]const u8, void).init(allocator);
        defer tree.deinit();

        var timer = try std.time.Timer.start();
        for (words.items) |word| {
            try tree.insert(word, {});
        }
        const insert_time = timer.read();

        timer.reset();
        var found: usize = 0;
        for (words.items) |word| {
            if (tree.get(word)) |_| found += 1;
        }
        const search_time = timer.read();

        timer.reset();
        // Benchmark Longest Prefix: Query word + "z" (ensure partial match)
        var lp_found: usize = 0;
        const lp_suffix = "z";
        var lp_arena = std.heap.ArenaAllocator.init(allocator);
        defer lp_arena.deinit();
        const lp_alloc = lp_arena.allocator();
        
        // Pre-allocate queries to exclude allocation time from benchmark
        const lp_queries = try lp_alloc.alloc([]const u8, total_words);
        for (words.items, 0..) |word, i| {
            lp_queries[i] = try std.fmt.allocPrint(lp_alloc, "{s}{s}", .{word, lp_suffix});
        }
        
        timer.reset();
        for (lp_queries) |q| {
            if (tree.longestPrefix(q)) |_| lp_found += 1;
        }
        const lp_time = timer.read();
        timer.reset();
        var it = tree.iterator();
        defer it.deinit();
        var it_count: usize = 0;
        while (it.next()) |_| {
            it_count += 1;
        }
        const iter_time = timer.read();

        try stdout.print("{d: >12} | {s: >25} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
            total_words, "zds.RadixTree", insert_time, search_time, lp_time, iter_time,
        });
    }

    // 2. Sorted ArrayList Benchmark (Comparison)
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
             if (std.sort.binarySearch([]const u8, list.items, word, StringContext.compare)) |_| found += 1;
         }
         const search_time = timer.read();

         timer.reset();
         // Longest Prefix for Sorted Array
         var lp_found: usize = 0;
         const lp_suffix = "z";
         var lp_arena = std.heap.ArenaAllocator.init(allocator);
         defer lp_arena.deinit();
         const lp_alloc = lp_arena.allocator();
         const lp_queries = try lp_alloc.alloc([]const u8, total_words);
         for (words.items, 0..) |word, i| {
             lp_queries[i] = try std.fmt.allocPrint(lp_alloc, "{s}{s}", .{word, lp_suffix});
         }
         
         timer.reset();
         for (lp_queries) |q| {
             const idx = std.sort.upperBound([]const u8, list.items, q, StringContext.compare);
             if (idx > 0) {
                 const candidate = list.items[idx - 1];
                 if (std.mem.startsWith(u8, q, candidate)) {
                     lp_found += 1;
                 }
             }
         }
         const lp_time = timer.read();
          timer.reset();
         var it_count: usize = 0;
         for (list.items) |_| {
             it_count += 1;
         }
         const iter_time = timer.read();
         
        try stdout.print("{d: >12} | {s: >25} | {d: >15} | {d: >15} | {d: >15} | {d: >15}\n", .{
            total_words, "Sorted ArrayList", insert_time, search_time, lp_time, iter_time,
        });
    }

    try stdout.flush();
}

const StringContext = struct {
    pub fn compare(key: []const u8, item: []const u8) std.math.Order {
        return std.mem.order(u8, key, item);
    }
};
