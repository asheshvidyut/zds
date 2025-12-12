//! B-Tree implementation in Zig.
//!
//! A B-Tree is a self-balancing tree data structure that maintains sorted data and allows searches,
//! sequential access, insertions, and deletions in logarithmic time. The B-Tree is a generalization
//! of a binary search tree in that a node can have more than two children.
//!
//! Properties:
//! 1. All leaves are at the same level.
//! 2. A B-Tree is defined by the term minimum degree 't'. The value of t depends upon disk block size.
//! 3. Every node except root must contain at least t-1 keys. The root may contain minimum 1 key.
//! 4. All nodes (including root) may contain at most 2t - 1 keys.
//! 5. Number of children of a node is equal to the number of keys in it plus 1.
//! 6. All keys of a node are sorted in increasing order. The child between two keys k1 and k2 contains all keys in the range from k1 and k2.
//! 7. B-Tree grows and shrinks from the root which is unlike Binary Search Tree. Binary Search Trees grow downward and also shrink from downward.
//! 8. Like other balanced Binary Search Trees, time complexity to search, insert and delete is O(log n).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const assert = std.debug.assert;

pub fn BTree(comptime Key: type, comptime Value: type) type {
    const Context = struct {
        pub fn cmp(self: @This(), a: Key, b: Key) Order {
            _ = self;
            if (Key == []const u8) {
                return std.mem.order(u8, a, b);
            }
            return std.math.order(a, b);
        }
    };
    return BTreeWithOptions(Key, Value, Context);
}

pub fn BTreeWithOptions(comptime Key: type, comptime Value: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            keys: std.ArrayListUnmanaged(Key),
            values: std.ArrayListUnmanaged(Value),
            children: std.ArrayListUnmanaged(*Node), // Child pointers
            is_leaf: bool,

            pub fn init(allocator: Allocator, is_leaf: bool, capacity: usize) !*Node {
                const node = try allocator.create(Node);
                node.* = Node{
                    .keys = try std.ArrayListUnmanaged(Key).initCapacity(allocator, capacity),
                    .values = try std.ArrayListUnmanaged(Value).initCapacity(allocator, capacity),
                    .children = if (is_leaf)
                        std.ArrayListUnmanaged(*Node){}
                    else
                        try std.ArrayListUnmanaged(*Node).initCapacity(allocator, capacity + 1),
                    .is_leaf = is_leaf,
                };
                return node;
            }

            pub fn deinit(self: *Node, allocator: Allocator) void {
                self.keys.deinit(allocator);
                self.values.deinit(allocator);
                self.children.deinit(allocator);
                allocator.destroy(self);
            }
        };

        root: ?*Node,
        allocator: Allocator,
        ctx: Context,
        t: usize, // Minimum degree

        pub fn init(allocator: Allocator, ctx: Context, t: usize) Self {
            assert(t >= 2);
            return Self{
                .root = null,
                .allocator = allocator,
                .ctx = ctx,
                .t = t,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.root) |r| {
                self.freeNode(r);
            }
            self.root = null;
        }

        fn freeNode(self: *Self, node: *Node) void {
            if (!node.is_leaf) {
                for (node.children.items) |child| {
                    self.freeNode(child);
                }
            }
            node.deinit(self.allocator);
        }

        pub fn search(self: Self, key: Key) ?Value {
            return self.searchNode(self.root, key);
        }

        fn searchNode(self: Self, node_opt: ?*Node, key: Key) ?Value {
            const node = node_opt orelse return null;

            // Find the first key greater than or equal to k
            var i: usize = 0;
            while (i < node.keys.items.len) : (i += 1) {
                const order = self.ctx.cmp(key, node.keys.items[i]);
                if (order == .eq) {
                    return node.values.items[i];
                }
                if (order == .lt) {
                    break;
                }
            }

            if (node.is_leaf) {
                return null;
            }

            return self.searchNode(node.children.items[i], key);
        }

        pub fn insert(self: *Self, key: Key, value: Value) !void {
            if (self.root == null) {
                const node = try Node.init(self.allocator, true, 2 * self.t - 1);
                try node.keys.append(self.allocator, key);
                try node.values.append(self.allocator, value);
                self.root = node;
            } else {
                const root = self.root.?;
                if (root.keys.items.len == 2 * self.t - 1) {
                    const s = try Node.init(self.allocator, false, 2 * self.t);
                    self.root = s;
                    try s.children.append(self.allocator, root);
                    try self.splitChild(s, 0);
                    try self.insertNonFull(s, key, value);
                } else {
                    try self.insertNonFull(root, key, value);
                }
            }
        }

        // Correct implementation of splitChild
        fn splitChildFixed(self: *Self, x: *Node, i: usize) !void {
            const t = self.t;
            const y = x.children.items[i];
            const z = try Node.init(self.allocator, y.is_leaf, 2 * t - 1);

            // z stores t-1 keys
            try z.keys.appendSlice(self.allocator, y.keys.items[t..]);
            try z.values.appendSlice(self.allocator, y.values.items[t..]);

            if (!y.is_leaf) {
                try z.children.appendSlice(self.allocator, y.children.items[t..]);
            }

            // Median key/value to move up
            const median_key = y.keys.items[t - 1];
            const median_val = y.values.items[t - 1];

            // Adjust y count to t-1
            y.keys.shrinkRetainingCapacity(t - 1);
            y.values.shrinkRetainingCapacity(t - 1);
            if (!y.is_leaf) {
                y.children.shrinkRetainingCapacity(t);
            }

            try x.children.insert(self.allocator, i + 1, z);
            try x.keys.insert(self.allocator, i, median_key);
            try x.values.insert(self.allocator, i, median_val);
        }

        fn insertNonFull(self: *Self, x: *Node, key: Key, value: Value) !void {
            // var i: usize = x.keys.items.len; // Index of last key (Unused)

            if (x.is_leaf) {
                // Find location to insert
                // Insert key such that it remains sorted
                // We'll traverse backwards
                // Or since we use ArrayList, we can find index and insert.
                // Standard B-Tree algorithms usually move elements.

                // Optimization: Binary search for position?
                // For now, linear scan backwards is fine for small t.

                // Zig array list insert is O(N).
                // Let's find index.
                var insert_idx: usize = 0;
                while (insert_idx < x.keys.items.len) : (insert_idx += 1) {
                    const order = self.ctx.cmp(key, x.keys.items[insert_idx]);
                    if (order == .lt) break;
                    if (order == .eq) {
                        // Key exists, update value?
                        x.values.items[insert_idx] = value;
                        return;
                    }
                }

                try x.keys.insert(self.allocator, insert_idx, key);
                try x.values.insert(self.allocator, insert_idx, value);
            } else {
                // Find child
                // Loop backwards or forwards?
                // Standard is backwards or appropriate child.
                // keys: k0, k1, k2
                // children: c0, c1, c2, c3
                // if key < k0, c0
                // if k0 < key < k1, c1
                // ...

                var child_idx: usize = 0;
                while (child_idx < x.keys.items.len) : (child_idx += 1) {
                    const order = self.ctx.cmp(key, x.keys.items[child_idx]);
                    if (order == .lt) break;
                    if (order == .eq) {
                        x.values.items[child_idx] = value;
                        return;
                    }
                }

                // child_idx is now the index of child to descend to
                // Check if that child is full
                if (x.children.items[child_idx].keys.items.len == 2 * self.t - 1) {
                    try self.splitChildFixed(x, child_idx);
                    // After split, x has a new key at child_idx.
                    // We need to decide whether to go to the left child (child_idx) or new right child (child_idx+1)
                    // Compare key with the new key at x.keys[child_idx]
                    const order = self.ctx.cmp(key, x.keys.items[child_idx]);
                    if (order == .gt) {
                        child_idx += 1;
                    } else if (order == .eq) {
                        x.values.items[child_idx] = value;
                        return;
                    }
                }

                try self.insertNonFull(x.children.items[child_idx], key, value);
            }
        }

        // Redefine splitChild to use the fixed version
        fn splitChild(self: *Self, x: *Node, i: usize) !void {
            return self.splitChildFixed(x, i);
        }

        pub const Iterator = struct {
            // Simplified iterator: perform in-order traversal and yield values.

            const StackItem = struct {
                node: *Node,
                index: usize,
            };

            stack: std.ArrayListUnmanaged(StackItem),
            allocator: Allocator,

            pub fn init(allocator: Allocator, root: ?*Node) Iterator {
                var list = std.ArrayListUnmanaged(StackItem){};
                if (root) |r| {
                    pushLeft(r, &list, allocator);
                }
                return Iterator{
                    .stack = list,
                    .allocator = allocator,
                };
            }

            pub fn deinit(self: *Iterator) void {
                self.stack.deinit(self.allocator);
            }

            fn pushLeft(node: *Node, stack: *std.ArrayListUnmanaged(StackItem), allocator: Allocator) void {
                var curr = node;
                while (true) {
                    stack.append(allocator, .{ .node = curr, .index = 0 }) catch return;
                    if (curr.is_leaf) break;
                    curr = curr.children.items[0];
                }
            }

            pub fn next(self: *Iterator) ?struct { key: Key, value: Value } {
                if (self.stack.items.len == 0) return null;

                // Peek at top
                var top = &self.stack.items[self.stack.items.len - 1];

                if (top.index < top.node.keys.items.len) {
                    const k = top.node.keys.items[top.index];
                    const v = top.node.values.items[top.index];

                    top.index += 1;

                    if (!top.node.is_leaf) {
                        pushLeft(top.node.children.items[top.index], &self.stack, self.allocator);
                    }

                    return .{ .key = k, .value = v };
                } else {
                    _ = self.stack.pop();
                    return self.next();
                }
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return Iterator.init(self.allocator, self.root);
        }
    };
}

test "BTree basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // t=2 (2-3-4 tree)
    var tree = BTree(u32, u32).init(allocator, .{}, 2);
    defer tree.deinit();

    try tree.insert(10, 100);
    try tree.insert(20, 200);
    try tree.insert(5, 50);
    try tree.insert(6, 60);
    try tree.insert(12, 120);
    try tree.insert(30, 300);
    try tree.insert(7, 70); // Should cause split if t=2 (max 3 keys)
    try tree.insert(17, 170);

    // Search
    try testing.expectEqual(@as(?u32, 100), tree.search(10));
    try testing.expectEqual(@as(?u32, 200), tree.search(20));
    try testing.expectEqual(@as(?u32, 50), tree.search(5));
    try testing.expectEqual(@as(?u32, 170), tree.search(17));
    try testing.expect(tree.search(999) == null);

    // Iterator
    var it = tree.iterator();
    defer it.deinit();

    var count: usize = 0;
    var last_key: u32 = 0;
    while (it.next()) |entry| {
        if (count > 0) {
            try testing.expect(entry.key > last_key);
        }
        last_key = entry.key;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 8), count);
}
