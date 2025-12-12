//! Swiss Table implementation in Zig.
//! https://github.com/google/cwisstable
//!
//!
//! DESIGN & LOGIC:
//!
//! 0. Definitions:
//!    - **Slot**: A single logical bucket in the map, indexed by `i` (0 <= i < capacity).
//!      In our SoA (Structure of Arrays) layout, "Slot `i`" consists of:
//!      - `Metadata[i]` (Control Byte)
//!      - `Keys[i]`
//!      - `Values[i]`
//!
//! 1. Control Bytes (metadata):
//!    - We use 1 byte of metadata per slot.
//!    - The top 1 bit serves as a "full/empty" flag.
//!    - If the high bit is 0, the slot is FULL, and the lower 7 bits contain the "H2" hash (secondary hash).
//!      - H2 is derived from the top 7 bits of the 64-bit hash.
//!    - If the high bit is 1, the slot is EMPTY, DELETED, or SENTINEL.
//!      - Empty (-128, 0b10000000): Slot is empty and fresh.
//!      - Deleted (-2,  0b11111110): Slot was valid but removed (tombstone).
//!      - Sentinel (-1, 0b11111111): Used at the probing boundary to stop runaway scans.
//!
//! 2. Probing (SIMD Groups):
//!    - The table is probed in groups of 16 slots (GroupWidth).
//!    - We load 16 bytes of metadata at once into a @Vector(16, i8).
//!    - Comparisons are done in parallel:
//!      - `match_h2`: `group == splat(h2)` identifies potential key matches.
//!      - `match_empty`: `group == splat(Empty)` identifies true empty slots.
//!    - These boolean vectors are compressed into integer bitmasks using `@bitCast`.
//!    - We iterate through the set bits using Count Trailing Zeros (@ctz) to find the exact index.
//!    - If a group yields no match, we skip forward by GroupWidth (16) and mask with `capacity - 1`.
//!
//! 3. Layout (SoA) & "Clones":
//!    - Memory layout: [Header] [Metadata] [Clones] [Keys] [Values]
//!    - `Metadata` has size `capacity`.
//!    - `Clones` has size `GroupWidth - 1` (15 bytes).
//!    - The `Clones` region mirrors the *first* 15 bytes of the metadata array.
//!      - `Metadata[capacity + i] == Metadata[i]` for i in 0..14.
//!    - **Purpose**: This allows us to perform a 16-byte unaligned load from *any* valid index `i` (where `i < capacity`)
//!      without performing a modulo check for every probe step.
//!      - If we probe at `capacity - 1`, we load 1 byte from Metadata and 15 bytes from Clones.
//!      - This makes the inner probing loop significantly tighter (no branching/modulo).
//!
//! 4. DefaultContext Logic:
//!    - Internally, `DefaultContext` optimizes hash generation:
//!    - For `[]const u8` (strings), it explicitly uses `std.hash.Wyhash` and `std.mem.eql`.
//!    - For "Unique Representation" types (e.g., u64, i32, structs without padding), it uses
//!      `std.mem.asBytes` + `Wyhash` to hash the raw bytes directly.
//!      - This bypasses the overhead of the generic `autoHash` visitor pattern.
//!    - A compile-time check ensures we don't accidentally try to "autoHash" a slice (which is unsafe/ambiguous).
//!
//!
//!
//! 5. Lookup Logic (Get):
//!    - Hash(key) -> H1 (lower bits) & H2 (top 7 bits).
//!    - H1 determines the starting group.
//!    - Loop (probing):
//!      - Load Group Metadata.
//!      - Match Group against H2 (SIMD comparison).
//!      - For each match in mask:
//!        - Verify key equality (Context.eql).
//!        - If equal, return value.
//!      - Match Group against Empty (SIMD comparison).
//!      - If any Empty slot is found in the group -> Stop, key not found.
//!      - If no Empty slot -> Probe next group (index + GroupWidth) & mask.
//!
//! 6. Insertion Logic (Put):
//!    - Ensure capacity (grow if size >= max_load).
//!    - Hash(key) -> H1, H2.
//!    - Probe for existing key (same steps as Get).
//!      - If found, overwrite value (or return error depending on function).
//!    - If not found, we need a refined probe to find an insertion slot.
//!    - We look for the *first* available slot (Empty or Deleted) that was seen during the probe sequence.
//!    - Write H2 to that Metadata slot.
//!    - Write Key and Value to their respective arrays.
//!    - Update `size`. If slot was Empty, update `available` (Deleted slots are already "unavailable").
//!
//! 7. Safety & Invariants:
//!    - `pointer_stability`: We track if iteration is active. Resizing while iterating is illegal and detected in Safety builds.
//!    - `capacity` is always a power of 2.
//!    - `max_load_percentage` limits how full the table gets (default 80%) to maintain probe sequence short.
//!    - `Sentinel` bytes are not strictly used in this specific Zig port's probing loop (we rely on mask & capacity),
//!      but are reserved for potential future compatibility or distinct termination states.

const std = @import("std");
const builtin = @import("builtin");
const math = std.math;
const assert = std.debug.assert;
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;

pub fn SwissMap(comptime K: type, comptime V: type) type {
    const DefaultContext = struct {
        pub fn hash(self: @This(), key: anytype) u64 {
            _ = self;
            const KeyT = @TypeOf(key);
            if (KeyT == []const u8) {
                return std.hash.Wyhash.hash(0, key);
            }
            if (std.meta.hasUniqueRepresentation(KeyT)) {
                return std.hash.Wyhash.hash(0, std.mem.asBytes(&key));
            }
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, key);
            return hasher.final();
        }
        pub fn eql(self: @This(), a: anytype, b: anytype) bool {
            _ = self;
            if (@TypeOf(a) == []const u8) {
                return std.mem.eql(u8, a, b);
            }
            return std.meta.eql(a, b);
        }
    };
    return SwissMapWithOptions(K, V, DefaultContext, 80);
}

pub fn SwissMapWithOptions(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime max_load_percentage: u64,
) type {
    if (max_load_percentage <= 0 or max_load_percentage >= 100)
        @compileError("max_load_percentage must be between 0 and 100.");
    return struct {
        const Self = @This();

        pub const Size = u32;

        pub const GroupWidth = 16;

        const BitMask = std.meta.Int(.unsigned, GroupWidth);

        pub const Ctrl = struct {
            // Special control byte values.
            // All special values have the high bit set (negative in i8).
            pub const Empty: i8 = -128; // 0b10000000 - Slot is empty
            pub const Deleted: i8 = -2; // 0b11111110 - Slot was used but key removed (tombstone)
            pub const Sentinel: i8 = -1; // 0b11111111 - End of probe sequence (guard)

            // Check if a slot is FULL (contains a valid key).
            // Full slots have the high bit CLEARED (positive or zero i8).
            // The value is the 7-bit H2 hash.
            pub inline fn isFull(byte: i8) bool {
                return byte >= 0;
            }

            pub inline fn isEmpty(byte: i8) bool {
                return byte == Empty;
            }

            pub inline fn isDeleted(byte: i8) bool {
                return byte == Deleted;
            }

            // Calculate H2 (secondary hash) from the full 64-bit hash.
            // H2 is the top 7 bits. We use this for fast SIMD filtering.
            // H1 (lower bits) is used for the index.
            pub inline fn h2(hash: u64) i8 {
                return @as(i8, @intCast(hash >> 57));
            }
        };

        // DefaultContext moved to SwissMap API.
        // SwissMapWithOptions now expects a valid Context type (not void) if you want hashing.

        allocator: Allocator,

        metadata: ?[*]i8 = null,

        size: Size = 0,

        available: Size = 0,

        pointer_stability: std.debug.SafetyLock = .{},

        const minimal_capacity = 8;

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .metadata = null,
                .size = 0,
                .available = 0,
            };
        }

        pub const Hash = u64;

        pub const Entry = struct {
            key_ptr: *K,
            value_ptr: *V,
        };

        pub const KV = struct {
            key: K,
            value: V,
        };

        const Header = struct {
            values: [*]V,
            keys: [*]K,
            capacity: Size,
        };

        pub const GetOrPutResult = struct {
            key_ptr: *K,
            value_ptr: *V,
            found_existing: bool,
        };

        pub fn getOrPutAssumeCapacityAdapted(self: *Self, key: anytype, ctx: anytype) GetOrPutResult {
            const eff_ctx = ctx;
            const hash = eff_ctx.hash(key);

            // H2: Top 7 bits of hash, used for fast fingerprint comparison.
            const h2 = Ctrl.h2(hash);

            const mask = self.capacity() - 1;
            const keys_base = self.keys();
            const vals_base = self.values();

            // H1: Primary hash determines the start group index.
            var idx = @as(usize, @truncate(hash & mask));

            // Track the *first* Tombstone (Deleted slot) encountered.
            // If the key is not found, we will reuse this slot for insertion to keep the probe chain compact.
            var first_tombstone_idx: ?usize = null;

            while (true) {
                // 1. Load SIMD group of metadata.
                const ptr = self.metadata.? + idx;
                const group: @Vector(GroupWidth, i8) = @as(*align(1) const @Vector(GroupWidth, i8), @ptrCast(ptr)).*;

                // 2. Parallel comparisons.
                const match_h2 = group == @as(@Vector(GroupWidth, i8), @splat(h2));
                const match_empty = group == @as(@Vector(GroupWidth, i8), @splat(Ctrl.Empty));
                const match_available = group < @as(@Vector(GroupWidth, i8), @splat(Ctrl.Sentinel));

                // 3. Bitmasks for iteration.
                var h2_mask: BitMask = @bitCast(match_h2);
                const empty_mask: BitMask = @bitCast(match_empty);
                const avaiable_mask: BitMask = @bitCast(match_available);

                // Deleted = Available (Empty/Deleted) AND NOT Empty.
                const deleted_mask: BitMask = avaiable_mask & ~empty_mask;

                // 4. Capture the first tombstone if we haven't seen one yet.
                if (first_tombstone_idx == null and deleted_mask != 0) {
                    const offset = @ctz(deleted_mask);
                    first_tombstone_idx = (idx + offset) & mask;
                }

                // 5. Check H2 matches for key equality.
                while (h2_mask != 0) {
                    const offset = @ctz(h2_mask);
                    const check_idx = (idx + offset) & mask;
                    const test_key = &keys_base[check_idx];

                    if (eff_ctx.eql(key, test_key.*)) {
                        return GetOrPutResult{
                            .key_ptr = test_key,
                            .value_ptr = &vals_base[check_idx],
                            .found_existing = true,
                        };
                    }
                    h2_mask &= h2_mask - 1;
                }

                // 6. If we hit an Empty slot, the key doesn't exist. Insert it.
                if (empty_mask != 0) {
                    var insert_idx: usize = 0;

                    if (first_tombstone_idx) |t_idx| {
                        // Reuse first tombstone if available (preferred).
                        insert_idx = t_idx;
                    } else {
                        // Otherwise use the first available Empty slot in this group.
                        const offset = @ctz(empty_mask);
                        insert_idx = (idx + offset) & mask;

                        assert(self.available > 0);
                        self.available -= 1; // Decrease available count only if consuming a fresh Empty slot.
                    }

                    // Write Metadata (H2), Key, and Value.
                    self.metadata.?[insert_idx] = h2;
                    if (insert_idx < GroupWidth - 1) {
                        // Mirror writes to the "Clones" area at the end of the array.
                        self.metadata.?[self.capacity() + insert_idx] = h2;
                    }

                    keys_base[insert_idx] = undefined; // caller fills
                    vals_base[insert_idx] = undefined; // caller fills
                    self.size += 1;

                    return GetOrPutResult{
                        .key_ptr = &keys_base[insert_idx],
                        .value_ptr = &vals_base[insert_idx],
                        .found_existing = false,
                    };
                }

                // 7. Probe next group.
                idx = (idx + GroupWidth) & mask;
            }
        }

        fn removeByIndex(self: *Self, idx: usize) void {
            self.metadata.?[idx] = Ctrl.Deleted;
            if (idx < GroupWidth - 1) {
                self.metadata.?[self.capacity() + idx] = Ctrl.Deleted;
            }
            self.keys()[idx] = undefined;
            self.values()[idx] = undefined;
            self.size -= 1;
        }

        pub fn remove(self: *Self, key: K) bool {
            if (@sizeOf(Context) != 0) {
                // Context is not void/empty, but user called remove(key).
                // We can only allow this if Context was indeed expected to be inferred or default?
                // But wait, if Context is NOT void, then remove(key) implies we use a default context?
                // If Context has state, we can't.
                // The original error "Cannot infer context" is correct if Context has size.
                // If Context is void, it's size 0.
                // So we keep the check.
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call removeContext instead.");
            }
            return self.removeContext(key, undefined);
        }

        pub fn removeContext(self: *Self, key: K, ctx: Context) bool {
            return self.removeAdapted(key, ctx);
        }

        pub fn removeAdapted(self: *Self, key: anytype, ctx: anytype) bool {
            if (self.getIndex(key, ctx)) |idx| {
                self.removeByIndex(idx);
                return true;
            }
            return false;
        }

        pub const Iterator = struct {
            hm: *const Self,
            index: Size = 0,

            pub fn next(it: *Iterator) ?Entry {
                assert(it.index <= it.hm.capacity());
                if (it.hm.size == 0) return null;

                const cap = it.hm.capacity();
                const meta = it.hm.metadata.?;

                while (it.index < cap) {
                    const byte = meta[it.index];
                    if (Ctrl.isFull(byte)) {
                        const key = &it.hm.keys()[it.index];
                        const value = &it.hm.values()[it.index];
                        it.index += 1;
                        return Entry{ .key_ptr = key, .value_ptr = value };
                    }
                    it.index += 1;
                }
                return null;
            }
        };

        pub const KeyIterator = FieldIterator(K);
        pub const ValueIterator = FieldIterator(V);

        fn FieldIterator(comptime T: type) type {
            return struct {
                len: usize,
                index: usize,
                capacity: usize,
                metadata: [*]const i8,
                items: [*]T,

                pub fn next(self: *@This()) ?*T {
                    while (self.index < self.capacity) {
                        const byte = self.metadata[self.index];
                        const item = &self.items[self.index];
                        self.index += 1;
                        if (Ctrl.isFull(byte)) {
                            return item;
                        }
                    }
                    return null;
                }
            };
        }

        pub fn keyIterator(self: Self) KeyIterator {
            if (self.metadata) |meta| {
                return .{
                    .index = 0,
                    .capacity = self.capacity(),
                    .metadata = meta,
                    .items = self.keys(),
                    .len = 0, // unused
                };
            } else {
                return .{ .index = 0, .capacity = 0, .metadata = undefined, .items = undefined, .len = 0 };
            }
        }

        pub fn valueIterator(self: Self) ValueIterator {
            if (self.metadata) |meta| {
                return .{
                    .index = 0,
                    .capacity = self.capacity(),
                    .metadata = meta,
                    .items = self.values(),
                    .len = 0,
                };
            } else {
                return .{ .index = 0, .capacity = 0, .metadata = undefined, .items = undefined, .len = 0 };
            }
        }

        fn isUnderMaxLoadPercentage(size: Size, cap: Size) bool {
            return size * 100 < max_load_percentage * cap;
        }

        pub fn deinit(self: *Self) void {
            self.pointer_stability.assertUnlocked();
            self.deallocate();
            self.* = undefined;
        }

        fn capacityForSize(size: Size) Size {
            var new_cap: u32 = @intCast((@as(u64, size) * 100) / max_load_percentage + 1);
            new_cap = math.ceilPowerOfTwo(u32, new_cap) catch unreachable;
            return new_cap;
        }

        pub fn ensureTotalCapacity(self: *Self, new_size: Size) Allocator.Error!void {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call ensureTotalCapacityContext instead.");
            return ensureTotalCapacityContext(self, new_size, undefined);
        }

        pub fn ensureTotalCapacityContext(self: *Self, new_size: Size, ctx: Context) Allocator.Error!void {
            self.pointer_stability.lock();
            defer self.pointer_stability.unlock();
            if (new_size > self.size)
                try self.growIfNeeded(new_size - self.size, ctx);
        }

        pub fn ensureUnusedCapacity(self: *Self, additional_size: Size) Allocator.Error!void {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call ensureUnusedCapacityContext instead.");
            return ensureUnusedCapacityContext(self, additional_size, undefined);
        }

        pub fn ensureUnusedCapacityContext(self: *Self, additional_size: Size, ctx: Context) Allocator.Error!void {
            return ensureTotalCapacityContext(self, self.count() + additional_size, ctx);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.pointer_stability.lock();
            defer self.pointer_stability.unlock();
            if (self.metadata) |_| {
                self.initMetadatas();
                self.size = 0;
                self.available = @truncate((self.capacity() * max_load_percentage) / 100);
            }
        }

        pub fn clearAndFree(self: *Self) void {
            self.pointer_stability.lock();
            defer self.pointer_stability.unlock();
            self.deallocate();
            self.size = 0;
            self.available = 0;
        }

        pub fn count(self: Self) Size {
            return self.size;
        }

        fn header(self: Self) *Header {
            return @ptrCast(@as([*]Header, @ptrCast(@alignCast(self.metadata.?))) - 1);
        }

        fn keys(self: Self) [*]K {
            return self.header().keys;
        }

        fn values(self: Self) [*]V {
            return self.header().values;
        }

        pub fn capacity(self: Self) Size {
            if (self.metadata == null) return 0;
            return self.header().capacity;
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{ .hm = self };
        }

        pub fn putNoClobber(self: *Self, key: K, value: V) Allocator.Error!void {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call putNoClobberContext instead.");
            return self.putNoClobberContext(key, value, undefined);
        }
        pub fn putNoClobberContext(self: *Self, key: K, value: V, ctx: Context) Allocator.Error!void {
            {
                self.pointer_stability.lock();
                defer self.pointer_stability.unlock();
                try self.growIfNeeded(1, ctx);
            }
            self.putAssumeCapacityNoClobberContext(key, value, ctx);
        }

        pub fn putAssumeCapacity(self: *Self, key: K, value: V) void {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call putAssumeCapacityContext instead.");
            return self.putAssumeCapacityContext(key, value, undefined);
        }
        pub fn putAssumeCapacityContext(self: *Self, key: K, value: V, ctx: Context) void {
            const gop = self.getOrPutAssumeCapacityContext(key, ctx);
            gop.value_ptr.* = value;
        }

        pub fn putAssumeCapacityNoClobber(self: *Self, key: K, value: V) void {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call putAssumeCapacityNoClobberContext instead.");
            return self.putAssumeCapacityNoClobberContext(key, value, undefined);
        }

        inline fn loadVector(ptr: [*]i8) @Vector(GroupWidth, i8) {
            return @as(*align(1) const @Vector(GroupWidth, i8), @ptrCast(ptr)).*;
        }

        fn getIndex(self: Self, key: K, ctx: Context) ?usize {
            if (self.size == 0) return null;

            const eff_ctx = ctx;
            const hash = eff_ctx.hash(key);

            // H2: Secondary hash (top 7 bits) stored in metadata for fast filtering.
            const h2 = Ctrl.h2(hash);

            const mask = self.capacity() - 1;
            const keys_base = self.keys();

            // H1: Primary hash determines the start index.
            var idx = @as(usize, @truncate(hash & mask));

            var limit = self.capacity();

            // PROBING LOOP:
            // We probe in groups of 16 slots (GroupWidth) using SIMD.
            while (limit > 0) {
                // 1. Load 16 bytes of metadata at once.
                //    Thanks to "Clones" (metadata mirroring), this never reads out of bounds
                //    even near the end of the array, avoiding modulo arithmetic here.
                const group = loadVector(self.metadata.? + idx);

                // 2. Compare group against H2 (potential matches) and Empty (stop condition).
                const match_h2 = group == @as(@Vector(GroupWidth, i8), @splat(h2));
                const match_empty = group == @as(@Vector(GroupWidth, i8), @splat(Ctrl.Empty));

                // 3. Convert vectors to integer bitmasks for iteration.
                var h2_mask: BitMask = @bitCast(match_h2);
                const empty_mask: BitMask = @bitCast(match_empty);

                // 4. Iterate over potential matches (where metadata == h2).
                while (h2_mask != 0) {
                    const trailing = @ctz(h2_mask);
                    const offset = trailing;
                    // Reconstruct full index (wrapping handled by mask if needed, though clones usually handle linear scan).
                    const check_idx = (idx + offset) & mask;

                    // 5. Verify the key (scalar equality check).
                    if (eff_ctx.eql(key, keys_base[check_idx])) {
                        return check_idx;
                    }

                    // Clear the bit to process the next match.
                    h2_mask &= h2_mask - 1;
                }

                // 6. Stop if we hit an EMPTY slot.
                //    This means the key cannot exist in the table (probing chain broken).
                if (empty_mask != 0) {
                    return null;
                }

                // 7. Advance to the next group.
                limit -= GroupWidth;
                idx = (idx + GroupWidth) & mask;
            }
            return null;
        }

        pub fn putAssumeCapacityNoClobberContext(self: *Self, key: K, value: V, ctx: Context) void {
            // INSERTION LOGIC:
            // Find the *first* available slot (Empty or Deleted) to insert the new key.
            // Since we know the key doesn't exist (NoClobber), we just need a spot.

            const eff_ctx = ctx;
            const hash = eff_ctx.hash(key);
            const h2 = Ctrl.h2(hash);
            const cap_mask = self.capacity() - 1;
            var idx = @as(usize, @truncate(hash & cap_mask));

            const keys_base = self.keys();
            const vals_base = self.values();

            while (true) {
                const group = loadVector(self.metadata.? + idx);

                // Look for ANY slot that is "Available" (Empty or Deleted).
                // Sentinel is -1, so anything < -1 is Empty (-128) or Deleted (-2).
                const match_available = group < @as(@Vector(GroupWidth, i8), @splat(Ctrl.Sentinel));

                const combined_mask: BitMask = @bitCast(match_available);

                if (combined_mask != 0) {
                    // Found an available slot!
                    const offset = @ctz(combined_mask);
                    const final_idx = (idx + offset) & cap_mask;

                    // 1. Write Control Byte (H2)
                    self.metadata.?[final_idx] = h2;

                    // 2. Clone metadata if we are in the "Clones" region (wrapping).
                    if (final_idx < GroupWidth - 1) {
                        self.metadata.?[self.capacity() + final_idx] = h2;
                    }

                    // 3. Write Key and Value
                    keys_base[final_idx] = key;
                    vals_base[final_idx] = value;
                    self.size += 1;
                    self.available -= 1;
                    return;
                }

                // Probe next group
                idx = (idx + GroupWidth) & cap_mask;
            }
        }

        pub fn getEntry(self: Self, key: K) ?Entry {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getEntryContext instead.");
            return self.getEntryContext(key, undefined);
        }
        pub fn getEntryContext(self: Self, key: K, ctx: Context) ?Entry {
            return self.getEntryAdapted(key, ctx);
        }
        pub fn getEntryAdapted(self: Self, key: anytype, ctx: anytype) ?Entry {
            if (self.getIndex(key, ctx)) |idx| {
                return Entry{
                    .key_ptr = &self.keys()[idx],
                    .value_ptr = &self.values()[idx],
                };
            }
            return null;
        }
        pub fn put(self: *Self, key: K, value: V) Allocator.Error!void {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call putContext instead.");
            return self.putContext(key, value, undefined);
        }
        pub fn putContext(self: *Self, key: K, value: V, ctx: Context) Allocator.Error!void {
            const result = try self.getOrPutContext(key, ctx);
            result.value_ptr.* = value;
        }
        pub fn getKeyPtr(self: Self, key: K) ?*K {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getKeyPtrContext instead.");
            return self.getKeyPtrContext(key, undefined);
        }
        pub fn getKeyPtrContext(self: Self, key: K, ctx: Context) ?*K {
            return self.getKeyPtrAdapted(key, ctx);
        }
        pub fn getKeyPtrAdapted(self: Self, key: anytype, ctx: anytype) ?*K {
            if (self.getIndex(key, ctx)) |idx| {
                return &self.keys()[idx];
            }
            return null;
        }

        pub fn getKey(self: Self, key: K) ?K {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getKeyContext instead.");
            return self.getKeyContext(key, undefined);
        }
        pub fn getKeyContext(self: Self, key: K, ctx: Context) ?K {
            return self.getKeyAdapted(key, ctx);
        }
        pub fn getKeyAdapted(self: Self, key: anytype, ctx: anytype) ?K {
            if (self.getIndex(key, ctx)) |idx| {
                return self.keys()[idx];
            }
            return null;
        }

        pub fn getPtr(self: Self, key: K) ?*V {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getPtrContext instead.");
            return self.getPtrContext(key, undefined);
        }
        pub fn getPtrContext(self: Self, key: K, ctx: Context) ?*V {
            return self.getPtrAdapted(key, ctx);
        }
        pub fn getPtrAdapted(self: Self, key: anytype, ctx: anytype) ?*V {
            if (self.getIndex(key, ctx)) |idx| {
                return &self.values()[idx];
            }
            return null;
        }

        pub fn get(self: Self, key: K) ?V {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getContext instead.");
            return self.getContext(key, undefined);
        }
        pub fn getContext(self: Self, key: K, ctx: Context) ?V {
            return self.getAdapted(key, ctx);
        }
        pub fn getAdapted(self: Self, key: anytype, ctx: anytype) ?V {
            if (self.getIndex(key, ctx)) |idx| {
                return self.values()[idx];
            }
            return null;
        }

        pub fn getOrPut(self: *Self, key: K) Allocator.Error!GetOrPutResult {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getOrPutContext instead.");
            return self.getOrPutContext(key, undefined);
        }
        pub fn getOrPutContext(self: *Self, key: K, ctx: Context) Allocator.Error!GetOrPutResult {
            const gop = try self.getOrPutContextAdapted(key, ctx, ctx);
            if (!gop.found_existing) {
                gop.key_ptr.* = key;
            }
            return gop;
        }
        pub fn getOrPutAdapted(self: *Self, key: anytype, key_ctx: anytype) Allocator.Error!GetOrPutResult {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getOrPutContextAdapted instead.");
            return self.getOrPutContextAdapted(key, key_ctx, undefined);
        }
        pub fn getOrPutContextAdapted(self: *Self, key: anytype, key_ctx: anytype, ctx: Context) Allocator.Error!GetOrPutResult {
            {
                self.pointer_stability.lock();
                defer self.pointer_stability.unlock();
                self.growIfNeeded(1, ctx) catch |err| {
                    // If allocation fails, try to do the lookup anyway.
                    // If we find an existing item, we can return it.
                    // Otherwise return the error, we could not add another.
                    const index = self.getIndex(key, key_ctx) orelse return err;
                    return GetOrPutResult{
                        .key_ptr = &self.keys()[index],
                        .value_ptr = &self.values()[index],
                        .found_existing = true,
                    };
                };
            }
            return self.getOrPutAssumeCapacityAdapted(key, key_ctx);
        }

        pub fn getOrPutAssumeCapacity(self: *Self, key: K) GetOrPutResult {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getOrPutAssumeCapacityContext instead.");
            return self.getOrPutAssumeCapacityContext(key, undefined);
        }
        pub fn getOrPutAssumeCapacityContext(self: *Self, key: K, ctx: Context) GetOrPutResult {
            const result = self.getOrPutAssumeCapacityAdapted(key, ctx);
            if (!result.found_existing) {
                result.key_ptr.* = key;
            }
            return result;
        }
        fn load(self: Self) Size {
            const max_load = (self.capacity() * max_load_percentage) / 100;
            return @as(Size, @truncate(max_load - self.available));
        }

        fn growIfNeeded(self: *Self, new_count: Size, ctx: Context) Allocator.Error!void {
            if (new_count > self.available) {
                var new_cap = self.capacity();
                const needed_cap = capacityForSize(self.size + new_count);
                if (needed_cap > new_cap) {
                    new_cap = needed_cap;
                }
                try self.rehash(new_cap, ctx);
            }
        }

        pub fn clone(self: Self) Allocator.Error!Self {
            var new_map = Self.init(self.allocator);
            try new_map.ensureTotalCapacityContext(self.count(), undefined);
            var it = self.iterator();
            while (it.next()) |entry| {
                new_map.putAssumeCapacityNoClobberContext(entry.key_ptr.*, entry.value_ptr.*, undefined);
            }
            return new_map;
        }

        fn rehash(self: *Self, new_capacity: Size, ctx: Context) Allocator.Error!void {
            const new_cap = @max(new_capacity, minimal_capacity);
            assert(std.math.isPowerOfTwo(new_cap));

            var map = Self.init(self.allocator);
            try map.allocate(new_cap);
            errdefer comptime unreachable;
            map.pointer_stability.lock();
            map.initMetadatas();
            map.available = @truncate((new_cap * max_load_percentage) / 100);

            if (self.size != 0) {
                const old_capacity = self.capacity();
                const meta = self.metadata.?;
                const keys_ptr = self.keys();
                const values_ptr = self.values();

                var i: usize = 0;
                while (i < old_capacity) : (i += 1) {
                    const m = meta[i];
                    if (Ctrl.isFull(m)) {
                        map.putAssumeCapacityNoClobberContext(keys_ptr[i], values_ptr[i], ctx);
                    }
                }
            }

            self.size = 0;
            self.pointer_stability = .{};
            std.mem.swap(Self, self, &map);
            map.deinit();
        }

        fn allocate(self: *Self, new_capacity: Size) Allocator.Error!void {
            const header_align = @alignOf(Header);
            const key_align = if (@sizeOf(K) == 0) 1 else @alignOf(K);
            const val_align = if (@sizeOf(V) == 0) 1 else @alignOf(V);
            const max_align: Alignment = comptime .fromByteUnits(@max(header_align, key_align, val_align));

            const new_cap: usize = new_capacity;

            const ctrl_size = new_cap + (GroupWidth - 1); // Capacity + Clones
            const meta_size = @sizeOf(Header) + ctrl_size;

            const keys_start = std.mem.alignForward(usize, meta_size, key_align);
            const keys_end = keys_start + new_cap * @sizeOf(K);

            const vals_start = std.mem.alignForward(usize, keys_end, val_align);
            const vals_end = vals_start + new_cap * @sizeOf(V);

            const total_size = max_align.forward(vals_end);

            const slice = try self.allocator.alignedAlloc(u8, max_align, total_size);
            const ptr: [*]u8 = @ptrCast(slice.ptr);

            const metadata = ptr + @sizeOf(Header);

            const hdr = @as(*Header, @ptrCast(@alignCast(ptr)));

            if (@sizeOf([*]V) != 0) {
                hdr.values = @ptrCast(@alignCast((ptr + vals_start)));
            }
            if (@sizeOf([*]K) != 0) {
                hdr.keys = @ptrCast(@alignCast((ptr + keys_start)));
            }
            hdr.capacity = new_capacity;
            self.metadata = @ptrCast(@alignCast(metadata));
        }

        fn deallocate(self: *Self) void {
            if (self.metadata == null) return;

            const header_align = @alignOf(Header);
            const key_align = if (@sizeOf(K) == 0) 1 else @alignOf(K);
            const val_align = if (@sizeOf(V) == 0) 1 else @alignOf(V);
            const max_align: Alignment = comptime .fromByteUnits(@max(header_align, key_align, val_align));

            const cap = self.capacity();
            const ctrl_size = cap + GroupWidth - 1;
            // Re-calculate layout to get total size
            // Note: allocate uses new_cap for ctrl_size calculation

            // Layout reconstruction must match allocate
            const keys_start = std.mem.alignForward(usize, @sizeOf(Header) + ctrl_size, key_align);
            const keys_end = keys_start + cap * @sizeOf(K);
            const vals_start = std.mem.alignForward(usize, keys_end, val_align);
            const vals_end = vals_start + cap * @sizeOf(V);
            const total_size = std.mem.alignForward(usize, vals_end, max_align.toByteUnits());

            // We must start at the Header to free the whole block
            const hdr_ptr = @as([*]Header, @ptrCast(@alignCast(self.metadata.?))) - 1;
            const slice = @as([*]align(max_align.toByteUnits()) u8, @ptrCast(@alignCast(hdr_ptr)))[0..total_size];
            self.allocator.free(slice);

            self.metadata = null;
            self.available = 0;
        }

        fn initMetadatas(self: *Self) void {
            const cap = self.capacity();
            const meta = self.metadata.?;

            // 1. Fill all slots with Empty
            @memset(meta[0..cap], Ctrl.Empty);

            // 2. Clones will just be Empty (copied from start) initially.
            @memset(meta[cap .. cap + GroupWidth - 1], Ctrl.Empty);
        }

        fn dbHelper(self: *Self, hdr: *Header, entry: *Entry) void {
            _ = self;
            _ = hdr;
            _ = entry;
        }

        comptime {
            if (!builtin.strip_debug_info) _ = switch (builtin.zig_backend) {
                .stage2_llvm => &dbHelper,
                .stage2_x86_64 => KV,
                else => {},
            };
        }
    };
}

test "SwissMap basic operations" {
    // Top-level test: validates the generic implementation with concrete types.
    const testing = std.testing;
    const allocator = testing.allocator;
    const Map = SwissMap(u32, u32); // Uses defaults

    var map = Map.init(allocator);
    defer map.deinit();

    try testing.expectEqual(@as(Map.Size, 0), map.count());

    try map.put(1, 10);
    try map.put(2, 20);
    try map.put(3, 30);

    try testing.expectEqual(@as(Map.Size, 3), map.count());
    try testing.expectEqual(@as(?u32, 10), map.get(1));
    try testing.expectEqual(@as(?u32, 20), map.get(2));
    try testing.expectEqual(@as(?u32, 30), map.get(3));
    try testing.expect(map.get(4) == null);

    // Overwrite
    try map.put(2, 22);
    try testing.expectEqual(@as(?u32, 22), map.get(2));

    // Remove
    try testing.expect(map.remove(2));
    try testing.expectEqual(@as(Map.Size, 2), map.count());
    try testing.expect(map.get(2) == null);
    try testing.expect(!map.remove(2));
}

test "SwissMap ensure capacity" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Map = SwissMap(u32, u32);

    var map = Map.init(allocator);
    defer map.deinit();

    try map.ensureTotalCapacity(100);
    try testing.expect(map.capacity() >= 100);
}

test "SwissMap iterator" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Map = SwissMap(u32, u32);

    var map = Map.init(allocator);
    defer map.deinit();

    try map.put(1, 10);
    try map.put(2, 20);
    try map.put(3, 30);

    var it = map.iterator();
    var sum_keys: u32 = 0;
    var sum_values: u32 = 0;
    while (it.next()) |entry| {
        sum_keys += entry.key_ptr.*;
        sum_values += entry.value_ptr.*;
    }
    try testing.expectEqual(@as(u32, 6), sum_keys);
    try testing.expectEqual(@as(u32, 60), sum_values);
}
