//! Red-Black Tree implementation in Zig.
//!
//! DESIGN & LOGIC:
//!
//! 1. Standard Red-Black Tree:
//!    - Maintains balanced properties ensuring O(log N) insertion, deletion, and search.
//!    - Nodes are colored Red or Black to satisfy RB invariants.
//!
//! 2. Augmented Features:
//!    - **Order Statistics**: Each node tracks `subchild_count` (size of its subtree).
//!      - Allows finding the K-th largest/smallest element in O(log N).
//!    - **Subtree Min/Max**: Each node maintains pointers to the minimum and maximum nodes in its subtree.
//!      - Allows fast access to successor/predecessor without traversing up heavily.
//!
//! 3. Doubly Linked List Integration:
//!    - **Optimized Iteration**: Nodes maintain `prev` and `next` pointers, forming a global doubly linked list of all elements in sorted order.
//!    - **Purpose**: This enables O(1) step iteration (next/prev) once you have a node, avoiding the O(log N) overhead or stack usage of standard tree traversal.
//!    - Iteration effectively becomes walking a linked list, which is extremely cache-friendly for linear scans compared to jumping around tree pointers.
//!
//! 4. Context-Based Comparison:
//!    - Uses a generic `Context` for flexible key comparison (e.g., custom sort orders, complex keys).
//!    - `RBTree(K, V)` provides a default context using `std.math.order`.
//!    - `RBTreeWithOptions` allows injecting custom contexts.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

pub fn RBTree(comptime Key: type, comptime Value: type) type {
    const Context = struct {
        pub fn cmp(self: @This(), a: Key, b: Key) Order {
            _ = self;
            if (Key == []const u8) {
                return std.mem.order(u8, a, b);
            }
            return std.math.order(a, b);
        }
    };
    return RBTreeWithOptions(Key, Value, Context);
}

pub fn RBTreeWithOptions(comptime Key: type, comptime Value: type, comptime Context: type) type {
    return struct {
        const Self = @This();

        pub const Color = enum { Red, Black };

        pub const Node = struct {
            key: Key,
            value: Value,
            color: Color,
            parent: ?*Node = null,
            left: ?*Node = null,
            right: ?*Node = null,
            prev: ?*Node = null, // Doubly linked list pointers
            next: ?*Node = null,
            min_node: *Node, // Min node in subtree
            max_node: *Node, // Max node in subtree
            subchild_count: usize = 1,

            pub fn init(k: Key, v: Value) Node {
                // Warning: min_node and max_node must be set to self pointer after creation
                // We can't do it here easily without a pointer to self, so we set them to undefined or expect caller to fix up.
                // However, since we are returning by value, the address will change.
                // We will handle initialization in the `insert` function where we allocate.
                return .{
                    .key = k,
                    .value = v,
                    .color = .Red,
                    .min_node = undefined, // Set after allocation
                    .max_node = undefined, // Set after allocation
                };
            }
        };

        root: ?*Node = null,
        allocator: Allocator,
        ctx: Context,

        pub fn init(allocator: Allocator, ctx: Context) Self {
            return .{
                .root = null,
                .allocator = allocator,
                .ctx = ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.deleteNodes(self.root);
        }

        fn deleteNodes(self: *Self, node: ?*Node) void {
            if (node) |n| {
                self.deleteNodes(n.left);
                self.deleteNodes(n.right);
                self.allocator.destroy(n);
            }
        }

        // Helper functions
        fn getSubchildCount(node: ?*Node) usize {
            return if (node) |n| n.subchild_count else 0;
        }

        fn updateSubchildCount(node: ?*Node) void {
            if (node) |n| {
                n.subchild_count = getSubchildCount(n.left) + getSubchildCount(n.right) + 1;
            }
        }

        fn minimum(node: ?*Node) ?*Node {
            return if (node) |n| n.min_node else null;
        }

        fn maximum(node: ?*Node) ?*Node {
            return if (node) |n| n.max_node else null;
        }

        fn updateMinMax(node: ?*Node) void {
            if (node) |n| {
                n.min_node = n;
                n.max_node = n;
                if (n.left) |left| n.min_node = left.min_node;
                if (n.right) |right| n.max_node = right.max_node;
            }
        }

        fn leftRotate(self: *Self, x: *Node) void {
            const y = x.right orelse return; // Should not happen if called correctly
            x.right = y.left;
            if (y.left) |yl| {
                yl.parent = x;
            }
            y.parent = x.parent;
            if (x.parent == null) {
                self.root = y;
            } else if (x == x.parent.?.left) {
                x.parent.?.left = y;
            } else {
                x.parent.?.right = y;
            }
            y.left = x;
            x.parent = y;

            updateMinMax(x);
            updateMinMax(y);
            updateSubchildCount(x);
            updateSubchildCount(y);
        }

        fn rightRotate(self: *Self, x: *Node) void {
            const y = x.left orelse return;
            x.left = y.right;
            if (y.right) |yr| {
                yr.parent = x;
            }
            y.parent = x.parent;
            if (x.parent == null) {
                self.root = y;
            } else if (x == x.parent.?.right) {
                x.parent.?.right = y;
            } else {
                x.parent.?.left = y;
            }
            y.right = x;
            x.parent = y;

            updateMinMax(x);
            updateMinMax(y);
            updateSubchildCount(x);
            updateSubchildCount(y);
        }

        fn transplant(self: *Self, u: *Node, v: ?*Node) void {
            if (u.parent == null) {
                self.root = v;
            } else if (u == u.parent.?.left) {
                u.parent.?.left = v;
            } else {
                u.parent.?.right = v;
            }
            if (v) |val| {
                val.parent = u.parent;
            }
        }

        pub fn search(self: Self, key: Key) ?*Node {
            var current = self.root;
            while (current) |curr| {
                const order = self.ctx.cmp(key, curr.key);
                switch (order) {
                    .eq => return curr,
                    .lt => current = curr.left,
                    .gt => current = curr.right,
                }
            }
            return null;
        }

        pub fn insert(self: *Self, key: Key, value: Value) !void {
            var node = try self.allocator.create(Node);
            node.* = Node.init(key, value);
            node.min_node = node;
            node.max_node = node;

            var y: ?*Node = null;
            var x = self.root;

            while (x) |curr| {
                y = curr;
                const order = self.ctx.cmp(node.key, curr.key);
                switch (order) {
                    .lt => x = curr.left,
                    else => x = curr.right, // .gt or .eq (multiset or replace? C++ implementation allows duplicates or goes right on eq? C++ code: key < x->key ... else x->right. So >= goes right)
                }
            }

            node.parent = y;
            if (y == null) {
                self.root = node;
            } else {
                const order = self.ctx.cmp(node.key, y.?.key);
                if (order == .lt) {
                    y.?.left = node;
                } else {
                    y.?.right = node;
                }
            }

            if (node.parent == null) {
                node.color = .Black;
                return;
            }

            // Update min/max pointers up the tree
            var temp: ?*Node = node;
            while (temp) |t| {
                updateMinMax(t);
                temp = t.parent;
            }

            // Link into doubly linked list
            var pred: ?*Node = null;
            if (node.left) |left| {
                pred = left.max_node;
            } else {
                temp = node;
                while (temp) |t| {
                    if (t.parent) |parent| {
                        if (t == parent.right) {
                            pred = parent;
                            break;
                        }
                    }
                    temp = t.parent;
                }
            }

            var succ: ?*Node = null;
            if (node.right) |right| {
                succ = right.min_node;
            } else {
                temp = node;
                while (temp) |t| {
                    if (t.parent) |parent| {
                        if (t == parent.left) {
                            succ = parent;
                            break;
                        }
                    }
                    temp = t.parent;
                }
            }

            node.prev = pred;
            node.next = succ;
            if (pred) |p| p.next = node;
            if (succ) |s| s.prev = node;

            // Update subchild_count for ancestors
            temp = node.parent;
            while (temp) |t| {
                updateSubchildCount(t);
                temp = t.parent;
            }

            if (node.parent == null) {
                node.color = .Black;
                return;
            }
            if (node.parent.?.parent == null) {
                return;
            }

            self.fixInsertViolation(node);
        }

        fn fixInsertViolation(self: *Self, k_in: *Node) void {
            var k = k_in;
            var u: ?*Node = null;

            while (k.parent != null and k.parent.?.color == .Red) {
                const parent = k.parent.?;
                const grandparent = parent.parent.?; // Must exist if parent is Red (root is Black)

                if (parent == grandparent.right) {
                    u = grandparent.left;
                    if (u != null and u.?.color == .Red) {
                        u.?.color = .Black;
                        parent.color = .Black;
                        grandparent.color = .Red;
                        k = grandparent;
                    } else {
                        if (k == parent.left) {
                            k = parent;
                            self.rightRotate(k);
                        }
                        // k might have changed, re-fetch parent/grandparent
                        k.parent.?.color = .Black;
                        k.parent.?.parent.?.color = .Red;
                        self.leftRotate(k.parent.?.parent.?);
                    }
                } else {
                    u = grandparent.right;
                    if (u != null and u.?.color == .Red) {
                        u.?.color = .Black;
                        parent.color = .Black;
                        grandparent.color = .Red;
                        k = grandparent;
                    } else {
                        if (k == parent.right) {
                            k = parent;
                            self.leftRotate(k);
                        }
                        k.parent.?.color = .Black;
                        k.parent.?.parent.?.color = .Red;
                        self.rightRotate(k.parent.?.parent.?);
                    }
                }
                if (k == self.root) break;
            }
            self.root.?.color = .Black;
        }

        pub fn deleteNode(self: *Self, key: Key) bool {
            const z = self.search(key) orelse return false;

            // Unlink from doubly linked list
            if (z.prev) |p| p.next = z.next;
            if (z.next) |n| n.prev = z.prev;

            var y = z;
            var y_original_color = y.color;
            var x: ?*Node = null;
            var x_parent: ?*Node = null;

            if (z.left == null) {
                x = z.right;
                x_parent = z.parent;
                self.transplant(z, z.right);
            } else if (z.right == null) {
                x = z.left;
                x_parent = z.parent;
                self.transplant(z, z.left);
            } else {
                y = minimum(z.right).?;
                y_original_color = y.color;
                x = y.right;
                x_parent = y; // x_parent is y if x is y's child

                if (y.parent == z) {
                    x_parent = y;
                } else {
                    x_parent = y.parent;
                    self.transplant(y, y.right);
                    y.right = z.right;
                    if (y.right) |yr| yr.parent = y;
                }
                self.transplant(z, y);
                y.left = z.left;
                y.left.?.parent = y;
                y.color = z.color;
            }

            // Update subchild_count for ancestors
            var temp = x_parent;
            while (temp) |t| {
                updateSubchildCount(t);
                temp = t.parent;
            }

            // Update min/max for ancestors
            var curr = x_parent;
            while (curr) |c| {
                updateMinMax(c);
                curr = c.parent;
            }

            if (y_original_color == .Black) {
                self.fixDeleteViolation(x, x_parent);
            }

            self.allocator.destroy(z);
            return true;
        }

        pub fn delete(self: *Self, key: Key) bool {
            return self.deleteNode(key);
        }

        fn fixDeleteViolation(self: *Self, x_in: ?*Node, parent_in: ?*Node) void {
            var x = x_in;
            var parent = parent_in;

            while (x != self.root and (x == null or x.?.color == .Black)) {
                if (parent == null) break;

                if (x == parent.?.left) {
                    var w = parent.?.right;
                    // Sibling w cannot be null in valid RB tree if x is black node (or null acting as black)
                    // But for safety in Zig optional unwrap...
                    if (w == null) break; // Should not happen

                    if (w.?.color == .Red) {
                        w.?.color = .Black;
                        parent.?.color = .Red;
                        self.leftRotate(parent.?);
                        w = parent.?.right;
                    }
                    if (w == null) break;

                    if ((w.?.left == null or w.?.left.?.color == .Black) and
                        (w.?.right == null or w.?.right.?.color == .Black))
                    {
                        w.?.color = .Red;
                        x = parent;
                        parent = x.?.parent;
                    } else {
                        if (w.?.right == null or w.?.right.?.color == .Black) {
                            if (w.?.left) |wl| wl.color = .Black;
                            w.?.color = .Red;
                            self.rightRotate(w.?);
                            w = parent.?.right;
                        }
                        if (w == null) break;

                        w.?.color = parent.?.color;
                        parent.?.color = .Black;
                        if (w.?.right) |wr| wr.color = .Black;
                        self.leftRotate(parent.?);
                        x = self.root;
                    }
                } else {
                    var w = parent.?.left;
                    if (w == null) break;

                    if (w.?.color == .Red) {
                        w.?.color = .Black;
                        parent.?.color = .Red;
                        self.rightRotate(parent.?);
                        w = parent.?.left;
                    }
                    if (w == null) break;

                    if ((w.?.right == null or w.?.right.?.color == .Black) and
                        (w.?.left == null or w.?.left.?.color == .Black))
                    {
                        w.?.color = .Red;
                        x = parent;
                        parent = x.?.parent;
                    } else {
                        if (w.?.left == null or w.?.left.?.color == .Black) {
                            if (w.?.right) |wr| wr.color = .Black;
                            w.?.color = .Red;
                            self.leftRotate(w.?);
                            w = parent.?.left;
                        }
                        if (w == null) break;

                        w.?.color = parent.?.color;
                        parent.?.color = .Black;
                        if (w.?.left) |wl| wl.color = .Black;
                        self.rightRotate(parent.?);
                        x = self.root;
                    }
                }
            }
            if (x) |xv| xv.color = .Black;
        }

        pub fn findKthLargest(self: Self, k: usize) ?*Node {
            if (k <= 0 or k > getSubchildCount(self.root)) return null;

            var current = self.root;
            var current_k = k;

            while (current) |curr| {
                const right_count = getSubchildCount(curr.right);
                if (current_k == right_count + 1) {
                    return curr;
                } else if (current_k <= right_count) {
                    current = curr.right;
                } else {
                    current_k = current_k - right_count - 1;
                    current = curr.left;
                }
            }
            return null;
        }

        pub const Iterator = struct {
            current: ?*Node,

            pub fn next(self: *Iterator) ?*Node {
                const curr = self.current orelse return null;
                self.current = curr.next;
                return curr;
            }

            pub fn prev(self: *Iterator) ?*Node {
                const curr = self.current orelse return null;
                self.current = curr.prev;
                return curr;
            }
        };

        pub fn count(self: Self) usize {
            return getSubchildCount(self.root);
        }

        pub fn printTree(self: Self) void {
            if (self.root) |r| {
                self.printTreeHelper(r, "", true, false);
            }
        }

        pub fn printTreeWithSubchildCount(self: Self) void {
            if (self.root) |r| {
                self.printTreeHelper(r, "", true, true);
            }
        }

        fn printTreeHelper(self: Self, node: *Node, indent: []const u8, is_last: bool, with_count: bool) void {
            var new_indent_buf: [256]u8 = undefined;
            var new_indent = std.ArrayList(u8).initBuffer(&new_indent_buf);
            new_indent.appendSlice(indent) catch {};

            std.debug.print("{s}", .{indent});
            if (is_last) {
                std.debug.print("R----", .{});
                new_indent.appendSlice("     ") catch {};
            } else {
                std.debug.print("L----", .{});
                new_indent.appendSlice("|    ") catch {};
            }

            const color_str = if (node.color == .Red) "RED" else "BLACK";
            if (with_count) {
                std.debug.print("{} ({s}) [{}]\n", .{ node.key, color_str, node.subchild_count });
            } else {
                std.debug.print("{} ({s})\n", .{ node.key, color_str });
            }

            // Note: recursive implementation might overflow stack for deep trees, but fine for examples.
            // Also managing indentation string allocs is tricky without an allocator.
            // I used a fixed buffer for indentation which limits depth but simple for this debug print.
            // Actually, for arbitrary depth we need allocator.
            // But the C++ code used std::string + operator+.

            // To be safe and simple, let's just pass the string slices recursively?
            // "indent" is passed in. We construct next indent.
            // We can't easily construct new strings without allocator.
            // But wait, the C++ code does `indent += "     "`.
            // I'll assume for debug printing we can use a temporary allocator or just limited depth.
            // Or better, passed-in allocator?
            // `printTree` is usually for small trees.
            // Let's rely on `std.debug.print` which is for debugging.

            if (node.left) |left| self.printTreeHelper(left, new_indent.items, false, with_count);
            if (node.right) |right| self.printTreeHelper(right, new_indent.items, true, with_count);
        }

        pub fn begin(self: Self) Iterator {
            return Iterator{ .current = if (self.root) |r| r.min_node else null };
        }

        pub fn end(self: Self) Iterator {
            _ = self;
            return Iterator{ .current = null };
        }

        pub fn last(self: Self) Iterator {
            return Iterator{ .current = if (self.root) |r| r.max_node else null };
        }
        pub fn iterator(self: Self) Iterator {
            return self.begin();
        }

        pub fn ceiling(self: Self, k: Key) ?*Node {
            var node = self.root;
            var result: ?*Node = null;

            while (node) |n| {
                const order = self.ctx.cmp(k, n.key);
                switch (order) {
                    .eq => return n,
                    .lt => {
                        // k < n.key. n is a candidate (>= k).
                        // Try to find a smaller candidate in the left subtree.
                        result = n;
                        node = n.left;
                    },
                    .gt => {
                        // k > n.key. n is too small (< k).
                        // Go right.
                        node = n.right;
                    },
                }
            }
            return result;
        }

        pub fn floor(self: Self, k: Key) ?*Node {
            var node = self.root;
            var result: ?*Node = null;

            while (node) |n| {
                const order = self.ctx.cmp(k, n.key);
                switch (order) {
                    .eq => return n,
                    .lt => {
                        // k < n.key. n is too big (> k).
                        // Go left.
                        node = n.left;
                    },
                    .gt => {
                        // k > n.key. n is a candidate (<= k).
                        // Try to find a larger candidate in the right subtree.
                        result = n;
                        node = n.right;
                    },
                }
            }
            return result;
        }

        pub fn higher(self: Self, k: Key) ?*Node {
            var node = self.root;
            var result: ?*Node = null;

            while (node) |n| {
                const order = self.ctx.cmp(k, n.key);
                switch (order) {
                    .eq => {
                        // k == n.key. We need > k.
                        // Go right to find larger keys.
                        node = n.right;
                    },
                    .lt => {
                        // k < n.key. n is a candidate (> k).
                        // Try to find a smaller candidate (closer to k) in left subtree.
                        result = n;
                        node = n.left;
                    },
                    .gt => {
                        // k > n.key. n is too small (<= k).
                        // Go right.
                        node = n.right;
                    },
                }
            }
            return result;
        }

        pub fn lower(self: Self, k: Key) ?*Node {
            var node = self.root;
            var result: ?*Node = null;

            while (node) |n| {
                const order = self.ctx.cmp(k, n.key);
                switch (order) {
                    .eq => {
                        // k == n.key. We need < k.
                        // Go left.
                        node = n.left;
                    },
                    .lt => {
                        // k < n.key. n is too big (>= k).
                        // Go left.
                        node = n.left;
                    },
                    .gt => {
                        // k > n.key. n is a candidate (< k).
                        // Try to find a larger candidate (closer to k) in right subtree.
                        result = n;
                        node = n.right;
                    },
                }
            }
            return result;
        }
    };
}

const U32Context = struct {
    pub fn cmp(self: @This(), a: u32, b: u32) Order {
        _ = self;
        return std.math.order(a, b);
    }
};

test "RBTree basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tree = RBTreeWithOptions(u32, []const u8, U32Context).init(allocator, .{});
    defer tree.deinit();

    try tree.insert(7, "seven");
    try tree.insert(3, "three");
    try tree.insert(18, "eighteen");
    try tree.insert(10, "ten");
    try tree.insert(22, "twenty-two");
    try tree.insert(8, "eight");
    try tree.insert(11, "eleven");
    try tree.insert(26, "twenty-six");
    try tree.insert(2, "two");
    try tree.insert(6, "six");
    try tree.insert(13, "thirteen");

    // Print tree structure not easily testable in unit test without capturing stdout,
    // but we can verify structure properties or specific nodes.

    // Verify search
    if (tree.search(10)) |node| {
        try testing.expectEqualStrings("ten", node.value);
    } else {
        return error.NotFound;
    }

    // Delete 18
    if (!tree.deleteNode(18)) return error.DeleteFailed;
    try testing.expect(tree.search(18) == null);

    // Delete 11
    if (!tree.deleteNode(11)) return error.DeleteFailed;
    try testing.expect(tree.search(11) == null);

    // Delete 3
    if (!tree.deleteNode(3)) return error.DeleteFailed;
    try testing.expect(tree.search(3) == null);

    // Verify search after deletes
    if (tree.search(10)) |node| {
        try testing.expectEqualStrings("ten", node.value);
    } else {
        return error.NotFound;
    }

    // Verify list traversal forward (expected order of remaining keys)
    // Remaining: 2, 6, 7, 8, 10, 13, 22, 26
    const expected_forward = [_]u32{ 2, 6, 7, 8, 10, 13, 22, 26 };
    var it = tree.begin();
    var idx: usize = 0;
    while (it.next()) |node| {
        try testing.expectEqual(expected_forward[idx], node.key);
        idx += 1;
    }
    try testing.expectEqual(expected_forward.len, idx);

    // Verify list traversal backward
    var it_back = tree.last();
    var idx_back: usize = expected_forward.len;
    while (it_back.prev()) |node| {
        idx_back -= 1;
        try testing.expectEqual(expected_forward[idx_back], node.key);
    }
    try testing.expectEqual(0, idx_back);

    // Verify Kth Largest
    // Tree size is 8.
    // 1st largest: 26 (rank 1 if K=1 is largest)
    // Wait, "Kth Largest" usually means 1 = Max, N = Min.
    // The implementation logic:
    // k = right_count + 1 => current is the k-th largest.
    // if k <= right_count => go right (larger elements).
    // so yes, k=1 is the largest.

    // 1st largest: 26
    // 2nd largest: 22
    // 3rd largest: 13
    // 4th largest: 10
    // 5th largest: 8
    // 6th largest: 7
    // 7th largest: 6
    // 8th largest: 2

    if (tree.findKthLargest(1)) |n| try testing.expectEqual(@as(u32, 26), n.key) else return error.KthNotFound;
    if (tree.findKthLargest(4)) |n| try testing.expectEqual(@as(u32, 10), n.key) else return error.KthNotFound;
    if (tree.findKthLargest(8)) |n| try testing.expectEqual(@as(u32, 2), n.key) else return error.KthNotFound;
    try testing.expect(tree.findKthLargest(9) == null);
}

test "RBTree ceiling floor higher lower" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tree = RBTreeWithOptions(u32, []const u8, U32Context).init(allocator, .{});
    defer tree.deinit();

    const keys = [_]u32{ 2, 6, 7, 8, 10, 13, 22, 26 };
    const values = [_][]const u8{ "two", "six", "seven", "eight", "ten", "thirteen", "twenty-two", "twenty-six" };

    for (keys, values) |k, v| {
        try tree.insert(k, v);
    }

    // Checking exact matches
    try testing.expectEqual(@as(u32, 6), tree.ceiling(6).?.key);
    try testing.expectEqual(@as(u32, 6), tree.floor(6).?.key);

    // Checking boundaries and gaps
    // ceiling(5) -> 6
    if (tree.ceiling(5)) |n| try testing.expectEqual(@as(u32, 6), n.key) else return error.CeilingFoundNull;
    // ceiling(9) -> 10
    if (tree.ceiling(9)) |n| try testing.expectEqual(@as(u32, 10), n.key) else return error.CeilingFoundNull;
    // ceiling(27) -> null
    try testing.expect(tree.ceiling(27) == null);

    // floor(5) -> 2
    if (tree.floor(5)) |n| try testing.expectEqual(@as(u32, 2), n.key) else return error.FloorFoundNull;
    // floor(9) -> 8
    if (tree.floor(9)) |n| try testing.expectEqual(@as(u32, 8), n.key) else return error.FloorFoundNull;
    // floor(1) -> null
    try testing.expect(tree.floor(1) == null);

    // higher(6) -> 7
    if (tree.higher(6)) |n| try testing.expectEqual(@as(u32, 7), n.key) else return error.HigherFoundNull;
    // higher(5) -> 6
    if (tree.higher(5)) |n| try testing.expectEqual(@as(u32, 6), n.key) else return error.HigherFoundNull;
    // higher(26) -> null
    try testing.expect(tree.higher(26) == null);

    // lower(6) -> 2
    if (tree.lower(6)) |n| try testing.expectEqual(@as(u32, 2), n.key) else return error.LowerFoundNull;
    // lower(5) -> 2
    if (tree.lower(5)) |n| try testing.expectEqual(@as(u32, 2), n.key) else return error.LowerFoundNull;
    // lower(2) -> null
    try testing.expect(tree.lower(2) == null);
}
