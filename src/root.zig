//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
pub const SwissMap = @import("swissmap.zig").SwissMap;
pub const SwissMapWithOptions = @import("swissmap.zig").SwissMapWithOptions;
pub const RBTree = @import("rbtree.zig").RBTree;
pub const RBTreeWithOptions = @import("rbtree.zig").RBTreeWithOptions;
pub const RadixTree = @import("radix.zig").RadixTree;
pub const LRUCache = @import("lru.zig").LRUCache;
pub const BTree = @import("btree.zig").BTree;
pub const BTreeWithOptions = @import("btree.zig").BTreeWithOptions;

test {
    _ = @import("swissmap.zig");
    _ = @import("rbtree.zig");
    _ = @import("radix.zig");
    _ = @import("lru.zig");
    _ = @import("btree.zig");
}
