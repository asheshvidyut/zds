const std = @import("std");
const zds = @import("root.zig");
const SwissMap = zds.SwissMap;

pub fn LRUCache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            key: K,
            value: V,
        };

        // Node for DoublyLinkedList
        // Internal DoublyLinkedList
        const List = struct {
            pub const LinkNode = struct {
                prev: ?*LinkNode = null,
                next: ?*LinkNode = null,
                data: Entry,
            };
            pub const Node = LinkNode;

            first: ?*LinkNode = null,
            last: ?*LinkNode = null,

            pub fn prepend(self: *@This(), node: *LinkNode) void {
                node.prev = null;
                node.next = self.first;
                if (self.first) |first| {
                    first.prev = node;
                } else {
                    self.last = node;
                }
                self.first = node; // Fix: Assign first to new node
            }

            pub fn remove(self: *@This(), node: *LinkNode) void {
                if (node.prev) |prev| {
                    prev.next = node.next;
                } else {
                    self.first = node.next;
                }
                if (node.next) |next| {
                    next.prev = node.prev;
                } else {
                    self.last = node.prev;
                }
                node.prev = null;
                node.next = null;
            }

            pub fn pop(self: *@This()) ?*LinkNode {
                const node = self.last orelse return null;
                self.remove(node);
                return node;
            }
        };
        const Node = List.Node;

        // Map stores pointers to List Nodes
        const Map = SwissMap(K, *Node);

        map: Map,
        list: List,
        capacity: usize,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return Self{
                .map = Map.init(allocator),
                .list = .{},
                .capacity = capacity,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Free all nodes in the list
            var it = self.list.first;
            while (it) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                it = next;
            }
            self.map.deinit();
        }

        pub fn put(self: *Self, key: K, value: V) !void {
            if (self.map.get(key)) |node| {
                // Key exists: update value and move to front
                node.data.value = value;
                self.list.remove(node);
                self.list.prepend(node);
            } else {
                // New key
                if (self.map.count() >= self.capacity) {
                    // Evict LRU (last)
                    if (self.list.pop()) |last| {
                        _ = self.map.remove(last.data.key);

                        // Reuse the node for the new entry!
                        last.data.key = key;
                        last.data.value = value;

                        self.list.prepend(last);
                        try self.map.put(key, last);
                    } else {
                        // Should not happen if count >= capacity > 0
                        // Fallback alloc if capacity is 0 (though LRU with cap 0 is useless)
                        const node = try self.allocator.create(Node);
                        node.data = .{ .key = key, .value = value };
                        self.list.prepend(node);
                        try self.map.put(key, node);
                    }
                } else {
                    // Allocate new node
                    const node = try self.allocator.create(Node);
                    node.data = .{ .key = key, .value = value };

                    self.list.prepend(node);
                    try self.map.put(key, node);
                }
            }
        }

        pub fn get(self: *Self, key: K) ?V {
            if (self.map.get(key)) |node| {
                self.list.remove(node);
                self.list.prepend(node);
                return node.data.value;
            }
            return null;
        }

        pub fn count(self: *Self) usize {
            return self.map.count();
        }
    };
}

test "LRUCache basic" {
    const testing = std.testing;
    var lru = try LRUCache(u32, []const u8).init(testing.allocator, 2);
    defer lru.deinit();

    // Fill up
    try lru.put(1, "one");
    try lru.put(2, "two");

    try testing.expectEqualStrings("one", lru.get(1).?);
    try testing.expectEqualStrings("two", lru.get(2).?);

    // Evict 1 (LRU because 2 was just accessed? No, wait.
    // get(1) made 1 MRU.
    // get(2) made 2 MRU.
    // So 1 is LRU? No, 1 was accessed LAST.
    // Wait.
    // put(1) -> 1 is MRU. List: [1]
    // put(2) -> 2 is MRU. List: [2, 1]
    // get(1) -> 1 is MRU. List: [1, 2]
    // put(3) -> Evict 2. List: [3, 1]

    _ = lru.get(1).?; // 1 is now MRU

    try lru.put(3, "three"); // Should evict 2

    try testing.expect(lru.get(2) == null);
    try testing.expectEqualStrings("one", lru.get(1).?);
    try testing.expectEqualStrings("three", lru.get(3).?);
}

test "LRUCache update existing" {
    const testing = std.testing;
    var lru = try LRUCache(u32, u32).init(testing.allocator, 2);
    defer lru.deinit();

    try lru.put(1, 10);
    try lru.put(2, 20);

    // Update 1, making it MRU. List: [1, 2]
    try lru.put(1, 11);

    // Insert 3, evict 2 (LRU). List: [3, 1]
    try lru.put(3, 30);

    try testing.expect(lru.get(2) == null);
    try testing.expectEqual(11, lru.get(1));
    try testing.expectEqual(30, lru.get(3));
}
