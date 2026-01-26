//! Multi-Ledger - Hierarchical account aggregation for TigerBeetle
//!
//! This module amplifies one physical movement into N logical movements,
//! enabling queries at any aggregation level (detail, zone, warehouse, global).
//!
//! Concept:
//! - Physical movement: The real thing (1 box moves from shelf A to shelf B)
//! - Logical movements: Accounting reflections at different hierarchy levels
//!
//! Example hierarchy for inventory:
//!   Level 0 (detail):    Zone-A:SKU-123 → Zone-B:SKU-123
//!   Level 1 (zone):      Zone-A:*       → Zone-B:*
//!   Level 2 (warehouse): Warehouse:*    → Warehouse:*
//!   Level 3 (global):    Global         → Global
//!
//! All logical movements are linked (TigerBeetle's atomic chain feature),
//! so they all succeed or all fail together.
//!
//! The write amplification is the feature: you can now query balances at
//! any level without application-side aggregation.

const std = @import("std");
const resource_ledger = @import("resource_ledger.zig");

pub const Container = resource_ledger.Container;
pub const Movement = resource_ledger.Movement;
pub const MovementFlags = resource_ledger.MovementFlags;

// ============================================================================
// Hierarchy Definition
// ============================================================================

/// Maximum depth of account hierarchy (detail + N aggregation levels).
pub const MAX_HIERARCHY_DEPTH = 8;

/// Defines how to derive ancestor container IDs from a detail container.
/// Each level represents a coarser aggregation.
///
/// Example for inventory (warehouse, zone, sku):
///   Level 0: hash(warehouse, zone, sku)     - detail
///   Level 1: hash(warehouse, zone, "ALL")   - zone total
///   Level 2: hash(warehouse, "ALL", "ALL")  - warehouse total
///   Level 3: hash("GLOBAL", "ALL", "ALL")   - global total
pub const HierarchyConfig = struct {
    /// Number of aggregation levels (not counting detail level).
    /// Total logical movements = levels + 1.
    levels: u8,

    /// Domain (ledger) ID for each level. Index 0 = detail level.
    /// Different ledgers allow TigerBeetle-native queries per level.
    ledgers: [MAX_HIERARCHY_DEPTH]u32,

    /// Function to compute ancestor container ID at each level.
    /// Returns null if the level doesn't apply (e.g., same-zone transfer
    /// doesn't need zone-level movement).
    ancestor_fn: *const fn (
        detail_container_id: u128,
        level: u8,
        user_context: ?*anyopaque,
    ) ?u128,

    /// Optional user context passed to ancestor_fn.
    user_context: ?*anyopaque,

    pub fn init(levels: u8, ledgers: [MAX_HIERARCHY_DEPTH]u32, ancestor_fn: anytype) HierarchyConfig {
        return .{
            .levels = levels,
            .ledgers = ledgers,
            .ancestor_fn = ancestor_fn,
            .user_context = null,
        };
    }
};

// ============================================================================
// Physical Movement - The input
// ============================================================================

/// A physical movement represents the real-world event.
/// This gets amplified into multiple logical movements.
pub const PhysicalMovement = struct {
    /// Unique ID for this physical movement (e.g., hash of order + line).
    id: u128,

    /// Source container at detail level.
    from_container: u128,

    /// Destination container at detail level.
    to_container: u128,

    /// Quantity being moved.
    amount: u128,

    /// Movement type code (e.g., pick, putaway, transfer).
    code: u16,

    /// Optional: make this a pending (reservable) movement.
    pending: bool = false,

    /// Timeout in seconds if pending.
    timeout: u32 = 0,

    /// User data fields (propagated to all logical movements).
    user_data_128: u128 = 0,
    user_data_64: u64 = 0,
    user_data_32: u32 = 0,
};

// ============================================================================
// Logical Movement Expansion
// ============================================================================

/// Result of expanding a physical movement into logical movements.
pub const ExpansionResult = struct {
    /// The logical movements to submit to TigerBeetle.
    /// All are linked except the last one.
    movements: []Movement,

    /// Number of movements generated.
    count: usize,
};

/// Expand a physical movement into N logical movements across the hierarchy.
///
/// Returns a slice of Movement structs ready to submit to TigerBeetle.
/// The caller must provide a buffer large enough for (hierarchy.levels + 1) movements.
///
/// All movements except the last have flags.linked = true, creating an
/// atomic chain that succeeds or fails together.
pub fn expandMovement(
    physical: PhysicalMovement,
    hierarchy: HierarchyConfig,
    buffer: []Movement,
) ExpansionResult {
    std.debug.assert(buffer.len >= hierarchy.levels + 1);

    var count: usize = 0;

    // Level 0: Detail level (always included)
    buffer[count] = createLogicalMovement(
        physical,
        physical.from_container,
        physical.to_container,
        hierarchy.ledgers[0],
        0, // level
        true, // linked (will unlink last one at the end)
    );
    count += 1;

    // Levels 1..N: Aggregation levels
    var level: u8 = 1;
    while (level <= hierarchy.levels) : (level += 1) {
        const from_ancestor = hierarchy.ancestor_fn(
            physical.from_container,
            level,
            hierarchy.user_context,
        );
        const to_ancestor = hierarchy.ancestor_fn(
            physical.to_container,
            level,
            hierarchy.user_context,
        );

        // Skip this level if ancestors are the same (e.g., same-zone transfer)
        // or if ancestor_fn returns null (level doesn't apply)
        if (from_ancestor) |from| {
            if (to_ancestor) |to| {
                if (from != to) {
                    buffer[count] = createLogicalMovement(
                        physical,
                        from,
                        to,
                        hierarchy.ledgers[level],
                        level,
                        true, // linked
                    );
                    count += 1;
                }
            }
        }
    }

    // Unlink the last movement (end of chain)
    if (count > 0) {
        buffer[count - 1].flags.linked = false;
    }

    return .{
        .movements = buffer[0..count],
        .count = count,
    };
}

fn createLogicalMovement(
    physical: PhysicalMovement,
    from: u128,
    to: u128,
    ledger: u32,
    level: u8,
    linked: bool,
) Movement {
    // Generate unique ID for this logical movement by combining
    // physical ID with level (so each level has unique ID)
    const logical_id = deriveLogicalId(physical.id, level);

    const m = Movement{
        .id = logical_id,
        .debit_account_id = from,
        .credit_account_id = to,
        .amount = physical.amount,
        .pending_id = 0,
        .user_data_128 = physical.user_data_128,
        .user_data_64 = physical.user_data_64,
        .user_data_32 = physical.user_data_32,
        .timeout = physical.timeout,
        .ledger = ledger,
        .code = physical.code,
        .flags = .{
            .linked = linked,
            .pending = physical.pending,
        },
        .timestamp = 0,
    };

    return m;
}

/// Derive a unique logical movement ID from physical ID + level.
/// This ensures each level has a distinct ID while being deterministic.
pub fn deriveLogicalId(physical_id: u128, level: u8) u128 {
    // XOR the level into the high bits to create unique but related IDs
    return physical_id ^ (@as(u128, level) << 120);
}

/// Reverse: extract physical ID from logical ID.
pub fn extractPhysicalId(logical_id: u128, level: u8) u128 {
    return logical_id ^ (@as(u128, level) << 120);
}

// ============================================================================
// Batch Expansion
// ============================================================================

/// Expand multiple physical movements into logical movements.
/// Useful for batch operations (e.g., entire shipment).
///
/// Each physical movement becomes its own linked chain.
/// Different physical movements are independent (can partially succeed).
pub fn expandBatch(
    physicals: []const PhysicalMovement,
    hierarchy: HierarchyConfig,
    buffer: []Movement,
) struct { movements: []Movement, count: usize } {
    var total_count: usize = 0;
    const max_per_physical = hierarchy.levels + 1;

    for (physicals) |physical| {
        if (total_count + max_per_physical > buffer.len) {
            break; // Buffer full
        }

        const result = expandMovement(
            physical,
            hierarchy,
            buffer[total_count..],
        );
        total_count += result.count;
    }

    return .{
        .movements = buffer[0..total_count],
        .count = total_count,
    };
}

// ============================================================================
// Pre-built Hierarchy Helpers
// ============================================================================

/// Create containers for a full hierarchy.
/// Returns containers at all levels that need to exist.
pub fn createHierarchyContainers(
    detail_container_id: u128,
    hierarchy: HierarchyConfig,
    code: u16,
    buffer: []Container,
) []Container {
    std.debug.assert(buffer.len >= hierarchy.levels + 1);

    var count: usize = 0;

    // Detail level
    buffer[count] = resource_ledger.container(
        detail_container_id,
        hierarchy.ledgers[0],
        code,
    );
    count += 1;

    // Aggregate levels
    var level: u8 = 1;
    while (level <= hierarchy.levels) : (level += 1) {
        if (hierarchy.ancestor_fn(detail_container_id, level, hierarchy.user_context)) |ancestor_id| {
            buffer[count] = resource_ledger.container(
                ancestor_id,
                hierarchy.ledgers[level],
                code,
            );
            count += 1;
        }
    }

    return buffer[0..count];
}

// ============================================================================
// Tests
// ============================================================================

test "expandMovement creates linked chain" {
    // Simple hierarchy: detail (ledger 1) + aggregate (ledger 2)
    // from_ancestor and to_ancestor are DIFFERENT
    const hierarchy = HierarchyConfig{
        .levels = 1,
        .ledgers = .{ 1, 2, 0, 0, 0, 0, 0, 0 },
        .ancestor_fn = struct {
            fn f(detail_id: u128, level: u8, _: ?*anyopaque) ?u128 {
                if (level == 1) {
                    // Map 100 → 1000, 200 → 2000 (different ancestors)
                    return detail_id * 10;
                }
                return null;
            }
        }.f,
        .user_context = null,
    };

    const physical = PhysicalMovement{
        .id = 1,
        .from_container = 100,
        .to_container = 200,
        .amount = 50,
        .code = 1,
    };

    var buffer: [8]Movement = undefined;
    const result = expandMovement(physical, hierarchy, &buffer);

    // Should have 2 movements: detail + aggregate
    try std.testing.expectEqual(@as(usize, 2), result.count);

    // First is linked, second is not (end of chain)
    try std.testing.expect(result.movements[0].flags.linked);
    try std.testing.expect(!result.movements[1].flags.linked);

    // Check detail level
    try std.testing.expectEqual(@as(u128, 100), result.movements[0].debit_account_id);
    try std.testing.expectEqual(@as(u128, 200), result.movements[0].credit_account_id);
    try std.testing.expectEqual(@as(u32, 1), result.movements[0].ledger);

    // Check aggregate level
    try std.testing.expectEqual(@as(u128, 1000), result.movements[1].debit_account_id);
    try std.testing.expectEqual(@as(u128, 2000), result.movements[1].credit_account_id);
    try std.testing.expectEqual(@as(u32, 2), result.movements[1].ledger);
}

test "expandMovement skips same-ancestor levels" {
    // If from and to have the same ancestor, skip that level
    const hierarchy = HierarchyConfig{
        .levels = 1,
        .ledgers = .{ 1, 2, 0, 0, 0, 0, 0, 0 },
        .ancestor_fn = struct {
            fn f(_: u128, level: u8, _: ?*anyopaque) ?u128 {
                if (level == 1) return 999; // Same ancestor for all
                return null;
            }
        }.f,
        .user_context = null,
    };

    const physical = PhysicalMovement{
        .id = 1,
        .from_container = 100,
        .to_container = 200,
        .amount = 50,
        .code = 1,
    };

    var buffer: [8]Movement = undefined;
    const result = expandMovement(physical, hierarchy, &buffer);

    // Aggregate level skipped because from_ancestor == to_ancestor (999 == 999)
    // So we only get the detail level movement
    try std.testing.expectEqual(@as(usize, 1), result.count);
    try std.testing.expect(!result.movements[0].flags.linked); // Single item, not linked
}

test "deriveLogicalId is reversible" {
    const physical_id: u128 = 0x123456789ABCDEF0123456789ABCDEF0;
    const level: u8 = 3;

    const logical_id = deriveLogicalId(physical_id, level);
    const recovered = extractPhysicalId(logical_id, level);

    try std.testing.expectEqual(physical_id, recovered);
    try std.testing.expect(logical_id != physical_id); // Should be different
}

test "three level hierarchy" {
    // Simulate: detail → zone → warehouse
    const hierarchy = HierarchyConfig{
        .levels = 2,
        .ledgers = .{ 1, 2, 3, 0, 0, 0, 0, 0 },
        .ancestor_fn = struct {
            fn f(detail_id: u128, level: u8, _: ?*anyopaque) ?u128 {
                return switch (level) {
                    1 => detail_id / 10, // Zone level: 100,101,102 → 10; 200,201 → 20
                    2 => detail_id / 100, // Warehouse: 100-199 → 1; 200-299 → 2
                    else => null,
                };
            }
        }.f,
        .user_context = null,
    };

    const physical = PhysicalMovement{
        .id = 1,
        .from_container = 100, // Warehouse 1, Zone 10
        .to_container = 250, // Warehouse 2, Zone 25
        .amount = 10,
        .code = 1,
    };

    var buffer: [8]Movement = undefined;
    const result = expandMovement(physical, hierarchy, &buffer);

    // 3 levels: detail + zone + warehouse
    try std.testing.expectEqual(@as(usize, 3), result.count);

    // Detail: 100 → 250
    try std.testing.expectEqual(@as(u128, 100), result.movements[0].debit_account_id);
    try std.testing.expectEqual(@as(u128, 250), result.movements[0].credit_account_id);

    // Zone: 10 → 25
    try std.testing.expectEqual(@as(u128, 10), result.movements[1].debit_account_id);
    try std.testing.expectEqual(@as(u128, 25), result.movements[1].credit_account_id);

    // Warehouse: 1 → 2
    try std.testing.expectEqual(@as(u128, 1), result.movements[2].debit_account_id);
    try std.testing.expectEqual(@as(u128, 2), result.movements[2].credit_account_id);

    // Linking: first two linked, last not
    try std.testing.expect(result.movements[0].flags.linked);
    try std.testing.expect(result.movements[1].flags.linked);
    try std.testing.expect(!result.movements[2].flags.linked);
}
