//! Radix Tree (Compact Prefix Tree) implementation in Zig.
//!
//! Features:
//! - **String Keys**: Optimized for `[]const u8` keys.
//! - **Prefix Compression**: Nodes with single children are merged to save space and reduce tree depth.
//! - **Order Statistics**: Maintains subtree leaf counts to support efficient `getAtIndex(k)` queries (K-th smallest key).
//! - **Sparse Nodes**: Uses an embedded Red-Black Tree (`zds.RBTree`) to store edges, efficiently handling nodes with many children (up to 256).
//! - **Longest Prefix Match**: Efficiently finds values associated with the longest matching prefix of a query key.
//! - **Doubly Linked Leaves**: Leaf nodes are linked in a global doubly linked list for O(1) step iteration.
//!
//! Complexity:
//! - Insert/Delete/Get: O(L) where L is the length of the string key (plus O(log 256) per edge lookup, effectively O(L)).
//! - GetAtIndex: O(D * log C) where D is tree depth and C is average children count.
//!
//! Note: This data structure is **not thread-safe**.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const rb = @import("rbtree.zig");

/// RadixTree implements a mutable radix tree.
pub fn RadixTree(comptime Key: type, comptime Value: type) type {
    if (Key != []const u8) {
        @compileError("RadixTree only supports []const u8 keys for now.");
    }

    const EdgeContext = struct {
        pub fn cmp(self: @This(), a: u8, b: u8) Order {
            _ = self;
            return std.math.order(a, b);
        }
    };

    return struct {
        const Self = @This();
        const ByteList = std.ArrayListUnmanaged(u8);

        // RBTree used for edges: Key=u8 (label), Value=*Node
        const Edges = rb.RBTreeWithOptions(u8, *Node, EdgeContext);

        pub const LeafNode = struct {
            key: Key,
            val: Value,
            next: ?*LeafNode = null,
            prev: ?*LeafNode = null,
        };

        const Node = struct {
            leaf: ?*LeafNode = null,
            min_leaf: ?*LeafNode = null,
            max_leaf: ?*LeafNode = null,
            leaves_in_subtree: usize = 0,

            prefix: ByteList,
            edges: Edges,
            allocator: Allocator,

            pub fn init(allocator: Allocator, prefix: []const u8) !*Node {
                const node = try allocator.create(Node);
                node.* = .{
                    .prefix = ByteList{},
                    .edges = Edges.init(allocator, .{}),
                    .allocator = allocator,
                    .min_leaf = null,
                    .max_leaf = null,
                };
                try node.prefix.appendSlice(allocator, prefix);
                return node;
            }

            pub fn updateMinMaxLeaves(self: *Node) void {
                self.min_leaf = null;
                self.max_leaf = null;
                if (self.leaf) |l| self.min_leaf = l;

                // First child
                var it = self.edges.begin();
                if (it.next()) |first| {
                    if (self.min_leaf == null) self.min_leaf = first.value.min_leaf;
                }

                // Last child
                var it_last = self.edges.last();
                if (it_last.prev()) |last| {
                    self.max_leaf = last.value.max_leaf;
                }
                if (self.max_leaf == null and self.leaf != null) self.max_leaf = self.leaf;
            }

            pub fn computeLinks(self: *Node) void {
                self.updateMinMaxLeaves();
                self.leaves_in_subtree = 0;
                if (self.leaf) |_| self.leaves_in_subtree += 1;

                var prev_max: ?*LeafNode = self.leaf;

                var it = self.edges.begin();
                while (it.next()) |entry| {
                    const child = entry.value;
                    self.leaves_in_subtree += child.leaves_in_subtree;

                    if (prev_max) |p| {
                        if (child.min_leaf) |cmin| {
                            p.next = cmin;
                            cmin.prev = p;
                        }
                    }
                    if (child.max_leaf) |cmax| {
                        prev_max = cmax;
                    }
                }
            }

            pub fn deinit(self: *Node) void {
                self.prefix.deinit(self.allocator);
                var it = self.edges.iterator();
                while (it.next()) |entry| {
                    entry.value.deinit();
                }
                self.edges.deinit();
                if (self.leaf) |l| {
                    self.allocator.destroy(l);
                }
                self.allocator.destroy(self);
            }

            pub fn isLeaf(self: *Node) bool {
                return self.leaf != null;
            }

            pub fn getEdge(self: *Node, label: u8) ?*Node {
                if (self.edges.search(label)) |n| {
                    return n.value;
                }
                return null;
            }

            pub fn addEdge(self: *Node, label: u8, child: *Node) !void {
                try self.edges.insert(label, child);
            }

            pub fn deleteEdge(self: *Node, label: u8) void {
                _ = self.edges.delete(label);
            }

            // Recursive insert returning true if a new leaf was added (to update counts)
            pub fn insert(self: *Node, key: Key, full_key: Key, val: Value, tree: *Self) !bool {
                // 1. Handle key exhaustion
                if (key.len == 0) {
                    if (self.leaf) |leaf| {
                        leaf.val = val;
                        return false;
                    } else {
                        const leaf = try self.allocator.create(LeafNode);
                        leaf.* = .{ .key = full_key, .val = val };
                        self.leaf = leaf;
                        self.computeLinks();
                        tree.size += 1;
                        return true;
                    }
                }

                // 2. Look for edge
                const label = key[0];
                const child_wrapper = self.edges.search(label);

                // No edge, create one
                if (child_wrapper == null) {
                    const leaf = try self.allocator.create(LeafNode);
                    leaf.* = .{ .key = full_key, .val = val };

                    const new_node = try Node.init(self.allocator, key);
                    new_node.leaf = leaf;
                    new_node.computeLinks();

                    try self.addEdge(label, new_node);
                    self.computeLinks();
                    tree.size += 1;
                    return true;
                }

                const child = child_wrapper.?.value;
                const common = commonPrefix(key, child.prefix.items);

                // Full match on child prefix?
                if (common == child.prefix.items.len) {
                    const added = try child.insert(key[common..], full_key, val, tree);
                    if (added) {
                        self.computeLinks();
                    }
                    return added;
                }

                // Partial match - Split needed
                const split_node = try Node.init(self.allocator, key[0..common]);
                _ = self.deleteEdge(label);

                // Child becomes child of split_node
                // Adjust child prefix
                const child_new_prefix = child.prefix.items[common..];
                const child_suffix_label = child_new_prefix[0];

                // We need to update child's prefix.
                // Careful: child is reused.
                const suffix_copy = try self.allocator.dupe(u8, child_new_prefix);
                defer self.allocator.free(suffix_copy);

                child.prefix.clearRetainingCapacity();
                try child.prefix.appendSlice(self.allocator, suffix_copy);

                try split_node.addEdge(child_suffix_label, child);
                // Child already has correct subtree info
                // We will computeLinks on split_node later

                // Insert new value into split_node
                const search_rest = key[common..];

                if (search_rest.len == 0) {
                    const leaf = try self.allocator.create(LeafNode);
                    leaf.* = .{ .key = full_key, .val = val };
                    split_node.leaf = leaf;
                    // split_node.computeLinks() will handle subtree count
                    tree.size += 1;
                } else {
                    const leaf = try self.allocator.create(LeafNode);
                    leaf.* = .{ .key = full_key, .val = val };

                    const new_branch = try Node.init(self.allocator, search_rest);
                    new_branch.leaf = leaf;
                    new_branch.computeLinks();

                    try split_node.addEdge(search_rest[0], new_branch);
                    // split_node.computeLinks() will handle subtree count
                    tree.size += 1;
                }

                split_node.computeLinks();
                try self.addEdge(label, split_node);
                self.computeLinks();
                return true;
            }

            pub fn delete(self: *Node, _: ?*Node, key: []const u8, tree: *Self) bool {
                if (key.len == 0) {
                    if (self.isLeaf()) {
                        self.allocator.destroy(self.leaf.?);
                        self.leaf = null;
                        self.computeLinks();
                        tree.size -= 1;

                        if (self.edges.count() == 1 and self != tree.root) {
                            self.mergeChild(self.allocator) catch {};
                        }
                        return true;
                    }
                    return false;
                }

                const label = key[0];
                const child_wrapper = self.edges.search(label);
                if (child_wrapper == null) return false;

                const child = child_wrapper.?.value;
                if (!std.mem.startsWith(u8, key, child.prefix.items)) return false;

                const remaining = key[child.prefix.items.len..];
                const deleted = child.delete(self, remaining, tree);

                if (deleted) {
                    self.computeLinks();
                    if (child.leaf == null and child.edges.count() == 0) {
                        _ = self.edges.delete(label);
                        child.deinit();

                        if (self != tree.root and self.edges.count() == 1 and self.leaf == null) {
                            self.mergeChild(self.allocator) catch {};
                        }
                    }
                }
                return deleted;
            }

            fn mergeChild(node: *Node, allocator: Allocator) !void {
                var it = node.edges.begin();
                const next_entry = it.next();
                if (next_entry == null) return;
                const child = next_entry.?.value;

                try node.prefix.appendSlice(allocator, child.prefix.items);

                if (node.leaf) |l| allocator.destroy(l);
                node.leaf = child.leaf;

                // leaves_in_subtree remains same because we just collapsed a node
                // node.leaves_in_subtree == child.leaves_in_subtree (since node had no leaf and 1 child)
                // BUT we need to re-link potentially because 'node' effectively replaced 'child' in the tree structure
                // However computeLinks is purely internal to 'node' children and leaf.
                // The 'child' leaf is moving to 'node'.
                // The 'child' edges are moving to 'node'.
                // So min_leaf/max_leaf of 'node' should become 'child's.
                // Re-running computeLinks is safest.

                _ = node.edges.delete(next_entry.?.key);
                node.edges = child.edges;

                child.prefix.deinit(allocator);
                allocator.destroy(child);

                node.computeLinks();
            }

            pub fn getAtIndex(self: *Node, k: usize) ?*LeafNode {
                if (k >= self.leaves_in_subtree) return null;

                var current_k = k;

                // 1. Check self leaf
                if (self.leaf) |l| {
                    if (current_k == 0) return l;
                    current_k -= 1;
                }

                // 2. Iterate children
                // RBTree iterator is standard in-order
                var it = self.edges.begin();
                while (it.next()) |entry| {
                    const child = entry.value;
                    if (current_k < child.leaves_in_subtree) {
                        return child.getAtIndex(current_k);
                    }
                    current_k -= child.leaves_in_subtree;
                }
                return null;
            }
        };

        root: *Node,
        size: usize = 0,
        allocator: Allocator,

        pub fn init(allocator: Allocator) !Self {
            const root = try Node.init(allocator, "");
            return .{
                .root = root,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.root.deinit();
        }

        pub fn insert(self: *Self, key: Key, val: Value) !void {
            _ = try self.root.insert(key, key, val, self);
        }

        pub fn get(self: *Self, key: Key) ?Value {
            var n = self.root;
            var search = key;

            while (true) {
                if (search.len == 0) {
                    if (n.leaf) |l| return l.val;
                    return null;
                }

                const label = search[0];
                const child_opt = n.getEdge(label);
                if (child_opt == null) return null;

                const child = child_opt.?;
                if (std.mem.startsWith(u8, search, child.prefix.items)) {
                    search = search[child.prefix.items.len..];
                    n = child;
                } else {
                    return null;
                }
            }
        }

        pub fn delete(self: *Self, key: Key) bool {
            return self.root.delete(null, key, self);
        }

        pub fn longestPrefix(self: *Self, key: Key) ?Value {
            var n = self.root;
            var search = key;
            var last_val: ?Value = null;

            while (true) {
                if (n.leaf) |l| last_val = l.val;

                if (search.len == 0) break;

                const label = search[0];
                const child_opt = n.getEdge(label);
                if (child_opt == null) break;

                const child = child_opt.?;
                if (std.mem.startsWith(u8, search, child.prefix.items)) {
                    search = search[child.prefix.items.len..];
                    n = child;
                } else {
                    break;
                }
            }
            return last_val;
        }

        pub fn getAtIndex(self: *Self, k: usize) ?Value {
            if (self.root.getAtIndex(k)) |leaf| {
                return leaf.val;
            }
            return null;
        }
        pub const Iterator = struct {
            current: ?*LeafNode,

            pub fn init(root: *Node) Iterator {
                return Iterator{ .current = root.min_leaf };
            }

            // No allocation needed for linked list traversal
            pub fn deinit(self: *Iterator) void {
                _ = self;
            }

            pub const Entry = struct {
                key: []const u8,
                value: Value,
            };

            pub fn next(self: *Iterator) ?Entry {
                const curr = self.current orelse return null;
                self.current = curr.next;
                return Entry{
                    .key = curr.key,
                    .value = curr.val,
                };
            }

            // Optional: backward traversal
            pub fn prev(self: *Iterator) ?Entry {
                const curr = self.current orelse return null;
                self.current = curr.prev;
                return Entry{
                    .key = curr.key,
                    .value = curr.val,
                };
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return Iterator.init(self.root);
        }
    };
}

// Helper to concat A+B into A
fn concat(allocator: Allocator, a: *std.ArrayListUnmanaged(u8), b: []const u8) !void {
    try a.appendSlice(allocator, b);
}

fn commonPrefix(a: []const u8, b: []const u8) usize {
    var i: usize = 0;
    const min_len = @min(a.len, b.len);
    while (i < min_len and a[i] == b[i]) : (i += 1) {}
    return i;
}

test "radix basic" {
    const testing = std.testing;
    var tree = try RadixTree([]const u8, i32).init(testing.allocator);
    defer tree.deinit();

    try tree.insert("foo", 1);
    try tree.insert("bar", 2);
    try tree.insert("foobar", 3);
    try tree.insert("foo", 4);

    try testing.expectEqual(@as(?i32, 4), tree.get("foo"));
    try testing.expectEqual(@as(?i32, 2), tree.get("bar"));
    try testing.expectEqual(@as(?i32, 3), tree.get("foobar"));
    try testing.expectEqual(@as(?i32, null), tree.get("f"));
    try testing.expectEqual(@as(?i32, null), tree.get("missing"));
}

test "radix delete and merge" {
    const testing = std.testing;
    var tree = try RadixTree([]const u8, i32).init(testing.allocator);
    defer tree.deinit();

    // 1. Simple delete leaf
    try tree.insert("foo", 1);
    try tree.insert("foobar", 2);

    // Tree: "foo" (val=1) -> "bar" (val=2)

    try testing.expect(tree.delete("foobar"));
    try testing.expectEqual(@as(?i32, null), tree.get("foobar"));
    try testing.expectEqual(@as(?i32, 1), tree.get("foo"));

    // 2. Merge check
    // "foo" (val=1) should have no edges now.
    // If we insert "fooz", it should be child of "foo".
    try tree.insert("fooz", 3);
    try testing.expectEqual(@as(?i32, 3), tree.get("fooz"));

    // 3. Delete parent value -> Merge
    // "foo" (val=1) -> "z" (val=3)
    // Delete "foo". Node "foo" becomes empty value. 1 edge "z".
    // Should merge "foo" + "z" -> "fooz".
    try testing.expect(tree.delete("foo"));
    try testing.expectEqual(@as(?i32, null), tree.get("foo"));
    try testing.expectEqual(@as(?i32, 3), tree.get("fooz"));
}

test "radix longest prefix" {
    const testing = std.testing;
    var tree = try RadixTree([]const u8, i32).init(testing.allocator);
    defer tree.deinit();

    try tree.insert("foo", 1);
    try tree.insert("foobar", 2);
    try tree.insert("f", 3);

    try testing.expectEqual(@as(?i32, 2), tree.longestPrefix("foobar"));
    try testing.expectEqual(@as(?i32, 1), tree.longestPrefix("foobaz"));
    try testing.expectEqual(@as(?i32, 1), tree.longestPrefix("fooa"));
    try testing.expectEqual(@as(?i32, 3), tree.longestPrefix("f"));
    try testing.expectEqual(@as(?i32, null), tree.longestPrefix("a"));
}

test "radix kth node" {
    const testing = std.testing;
    var tree = try RadixTree([]const u8, i32).init(testing.allocator);
    defer tree.deinit();

    // Insert keys out of order
    try tree.insert("b", 2); // 1
    try tree.insert("a", 1); // 0
    try tree.insert("d", 4); // 2
    try tree.insert("c", 3); // 3 (sorted: a, b, c, d?)
    // Wait, d > c.
    // Sorted: a (1), b (2), c (3), d (4).

    try testing.expectEqual(@as(?i32, 1), tree.getAtIndex(0));
    try testing.expectEqual(@as(?i32, 2), tree.getAtIndex(1));
    try testing.expectEqual(@as(?i32, 3), tree.getAtIndex(2));
    try testing.expectEqual(@as(?i32, 4), tree.getAtIndex(3));
    try testing.expectEqual(@as(?i32, null), tree.getAtIndex(4));

    // Test with prefix structure
    // "app" (10)
    // "apple" (20)
    // "b" (30)
    try tree.insert("app", 10);
    try tree.insert("apple", 20);

    // Sorted:
    // "a" (1)
    // "app" (10)
    // "apple" (20)
    // "b" (2)
    // "c" (3)
    // "d" (4)

    try testing.expectEqual(@as(?i32, 1), tree.getAtIndex(0));
    try testing.expectEqual(@as(?i32, 10), tree.getAtIndex(1));
    try testing.expectEqual(@as(?i32, 20), tree.getAtIndex(2));
    try testing.expectEqual(@as(?i32, 2), tree.getAtIndex(3));
    try testing.expectEqual(@as(?i32, 3), tree.getAtIndex(4));
    try testing.expectEqual(@as(?i32, 3), tree.getAtIndex(4));
    try testing.expectEqual(@as(?i32, 4), tree.getAtIndex(5));
}

test "radix iterator" {
    const testing = std.testing;
    var tree = try RadixTree([]const u8, i32).init(testing.allocator);
    defer tree.deinit();

    try tree.insert("apple", 1);
    try tree.insert("app", 2);
    try tree.insert("banana", 3);

    var it = tree.iterator();
    defer it.deinit();

    // Expected order: "app", "apple", "banana"
    const e1 = it.next();
    try testing.expect(e1 != null);
    try testing.expectEqualStrings("app", e1.?.key);
    try testing.expectEqual(@as(i32, 2), e1.?.value);

    const e2 = it.next();
    try testing.expect(e2 != null);
    try testing.expectEqualStrings("apple", e2.?.key);
    try testing.expectEqual(@as(i32, 1), e2.?.value);

    const e3 = it.next();
    try testing.expect(e3 != null);
    try testing.expectEqualStrings("banana", e3.?.key);
    try testing.expectEqual(@as(i32, 3), e3.?.value);

    try testing.expect(it.next() == null);
}

test "radix linked list" {
    const testing = std.testing;
    var tree = try RadixTree([]const u8, i32).init(testing.allocator);
    defer tree.deinit();

    try tree.insert("banana", 1);
    try tree.insert("apple", 2);
    try tree.insert("app", 3);
    try tree.insert("cherry", 4);

    // Verify forward list
    // Sorted: app (3), apple (2), banana (1), cherry (4)
    var curr = tree.root.min_leaf;
    try testing.expect(curr != null);
    try testing.expectEqualStrings("app", curr.?.key);
    try testing.expectEqual(@as(i32, 3), curr.?.val);

    curr = curr.?.next;
    try testing.expect(curr != null);
    try testing.expectEqualStrings("apple", curr.?.key);
    try testing.expectEqual(@as(i32, 2), curr.?.val);

    curr = curr.?.next;
    try testing.expect(curr != null);
    try testing.expectEqualStrings("banana", curr.?.key);
    try testing.expectEqual(@as(i32, 1), curr.?.val);

    curr = curr.?.next;
    try testing.expect(curr != null);
    try testing.expectEqualStrings("cherry", curr.?.key);
    try testing.expectEqual(@as(i32, 4), curr.?.val);

    try testing.expect(curr.?.next == null);

    // Verify backward list (starting from max_leaf)
    var back = tree.root.max_leaf;
    try testing.expect(back != null);
    try testing.expectEqualStrings("cherry", back.?.key);

    back = back.?.prev;
    try testing.expect(back != null);
    try testing.expectEqualStrings("banana", back.?.key);

    back = back.?.prev;
    try testing.expect(back != null);
    try testing.expectEqualStrings("apple", back.?.key);

    back = back.?.prev;
    try testing.expect(back != null);
    try testing.expectEqualStrings("app", back.?.key);

    try testing.expect(back.?.prev == null);

    // Delete middle node "apple"
    try testing.expect(tree.delete("apple"));
    // New list: app -> banana -> cherry

    curr = tree.root.min_leaf;
    try testing.expectEqualStrings("app", curr.?.key);

    curr = curr.?.next;
    try testing.expectEqualStrings("banana", curr.?.key);
    try testing.expectEqualStrings("app", curr.?.prev.?.key);

    curr = curr.?.next;
    try testing.expectEqualStrings("cherry", curr.?.key);
    try testing.expectEqualStrings("banana", curr.?.prev.?.key);

    try testing.expect(curr.?.next == null);
}
