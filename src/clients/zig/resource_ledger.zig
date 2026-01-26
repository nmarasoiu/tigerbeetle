//! Resource Ledger - Domain-agnostic vocabulary for TigerBeetle
//!
//! This module provides alternative naming for non-financial domains:
//! - Account → Container (holds a quantity of something)
//! - Transfer → Movement (moves quantity between containers)
//! - Ledger → Domain (grouping of related containers)
//!
//! The semantic model is identical to TigerBeetle - this is purely vocabulary.
//!
//! Use cases:
//! - Inventory: Container = (warehouse, SKU), Movement = stock transfer
//! - Loyalty: Container = member account, Movement = points earn/redeem
//! - Quotas: Container = user/service, Movement = allocation/consumption
//! - Tickets: Container = pool (available/held/sold), Movement = reservation

const std = @import("std");

// ============================================================================
// Type Definitions - Compatible with TigerBeetle's Account/Transfer
// ============================================================================

/// ContainerFlags control behavior (linking, balance constraints).
/// Binary-compatible with TigerBeetle's AccountFlags.
pub const ContainerFlags = packed struct(u16) {
    linked: bool = false,
    debits_must_not_exceed_credits: bool = false,
    credits_must_not_exceed_debits: bool = false,
    history: bool = false,
    imported: bool = false,
    closed: bool = false,
    padding: u10 = 0,
};

/// A Container holds a quantity of some resource at a logical location.
/// Binary-compatible with TigerBeetle's Account.
pub const Container = extern struct {
    id: u128,
    debits_pending: u128,
    debits_posted: u128,
    credits_pending: u128,
    credits_posted: u128,
    user_data_128: u128,
    user_data_64: u64,
    user_data_32: u32,
    reserved: u32,
    ledger: u32,
    code: u16,
    flags: ContainerFlags,
    timestamp: u64,

    comptime {
        std.debug.assert(@sizeOf(Container) == 128);
        std.debug.assert(@alignOf(Container) == 16);
    }
};

/// MovementFlags control behavior (linking, pending/post/void).
/// Binary-compatible with TigerBeetle's TransferFlags.
pub const MovementFlags = packed struct(u16) {
    linked: bool = false,
    pending: bool = false,
    post_pending_transfer: bool = false,
    void_pending_transfer: bool = false,
    balancing_debit: bool = false,
    balancing_credit: bool = false,
    closing_debit: bool = false,
    closing_credit: bool = false,
    imported: bool = false,
    padding: u7 = 0,
};

/// A Movement transfers quantity from one Container to another.
/// Binary-compatible with TigerBeetle's Transfer.
pub const Movement = extern struct {
    id: u128,
    debit_account_id: u128,
    credit_account_id: u128,
    amount: u128,
    pending_id: u128,
    user_data_128: u128,
    user_data_64: u64,
    user_data_32: u32,
    timeout: u32,
    ledger: u32,
    code: u16,
    flags: MovementFlags,
    timestamp: u64,

    comptime {
        std.debug.assert(@sizeOf(Movement) == 128);
        std.debug.assert(@alignOf(Movement) == 16);
    }
};

/// Container balance snapshot.
pub const ContainerBalance = extern struct {
    debits_pending: u128,
    debits_posted: u128,
    credits_pending: u128,
    credits_posted: u128,
    timestamp: u64,
    reserved: [56]u8 = @splat(0),

    comptime {
        std.debug.assert(@sizeOf(ContainerBalance) == 128);
        std.debug.assert(@alignOf(ContainerBalance) == 16);
    }
};

/// Result codes for container creation.
pub const CreateContainerResult = enum(u32) {
    ok = 0,
    linked_event_failed = 1,
    linked_event_chain_open = 2,
    // ... other error codes match TigerBeetle's CreateAccountResult
};

/// Result codes for movement creation.
pub const CreateMovementResult = enum(u32) {
    ok = 0,
    linked_event_failed = 1,
    linked_event_chain_open = 2,
    // ... other error codes match TigerBeetle's CreateTransferResult
};

// ============================================================================
// ID Generation - Hash business keys to 128-bit IDs
// ============================================================================

/// Generate a Container ID from business keys.
/// The hash is deterministic - same inputs always produce same ID.
///
/// Example for inventory:
///   containerId(.{ .warehouse = "BOSTON", .sku = "SKU-1234" })
///
/// Example for loyalty:
///   containerId(.{ .program = "GOLD", .member = "user@example.com" })
pub fn containerId(business_key: anytype) u128 {
    return hashBusinessKey(business_key);
}

/// Generate a Movement ID from business keys.
/// Typically includes a unique transaction reference.
///
/// Example:
///   movementId(.{ .order = "ORD-123", .line = 1 })
pub fn movementId(business_key: anytype) u128 {
    return hashBusinessKey(business_key);
}

/// Generate a deterministic 128-bit hash from any struct of business keys.
fn hashBusinessKey(key: anytype) u128 {
    var hasher = std.hash.Wyhash.init(0);

    const T = @TypeOf(key);
    const fields = std.meta.fields(T);

    inline for (fields) |field| {
        const value = @field(key, field.name);
        hashValue(&hasher, value);
    }

    const hash64 = hasher.final();

    // Extend to 128-bit by hashing again with different seed
    var hasher2 = std.hash.Wyhash.init(hash64);
    inline for (fields) |field| {
        const value = @field(key, field.name);
        hashValue(&hasher2, value);
    }
    const hash64_2 = hasher2.final();

    return (@as(u128, hash64) << 64) | @as(u128, hash64_2);
}

fn hashValue(hasher: *std.hash.Wyhash, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            const bytes = std.mem.asBytes(&value);
            hasher.update(bytes);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                // String slice
                hasher.update(value);
            } else if (ptr.size == .one) {
                // Pointer to single item - hash the item
                hashValue(hasher, value.*);
            } else {
                @compileError("Unsupported pointer type for hashing");
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                // Fixed-size string/bytes
                hasher.update(&value);
            } else {
                @compileError("Unsupported array type for hashing");
            }
        },
        else => @compileError("Unsupported type for business key hashing: " ++ @typeName(T)),
    }
}

// ============================================================================
// Builder Helpers - Ergonomic container/movement creation
// ============================================================================

/// Create a new Container with sensible defaults.
pub fn container(id: u128, domain: u32, code: u16) Container {
    return Container{
        .id = id,
        .debits_pending = 0,
        .debits_posted = 0,
        .credits_pending = 0,
        .credits_posted = 0,
        .user_data_128 = 0,
        .user_data_64 = 0,
        .user_data_32 = 0,
        .reserved = 0,
        .ledger = domain,
        .code = code,
        .flags = .{},
        .timestamp = 0,
    };
}

/// Create a new Movement with sensible defaults.
pub fn movement(
    id: u128,
    from: u128,
    to: u128,
    amount: u128,
    domain: u32,
    code: u16,
) Movement {
    return Movement{
        .id = id,
        .debit_account_id = from,
        .credit_account_id = to,
        .amount = amount,
        .pending_id = 0,
        .user_data_128 = 0,
        .user_data_64 = 0,
        .user_data_32 = 0,
        .timeout = 0,
        .ledger = domain,
        .code = code,
        .flags = .{},
        .timestamp = 0,
    };
}

/// Create a pending (reserved) movement that must be posted or voided later.
pub fn pendingMovement(
    id: u128,
    from: u128,
    to: u128,
    amount: u128,
    domain: u32,
    code: u16,
    timeout_seconds: u32,
) Movement {
    var m = movement(id, from, to, amount, domain, code);
    m.flags.pending = true;
    m.timeout = timeout_seconds;
    return m;
}

/// Create a movement that posts (confirms) a pending movement.
pub fn postMovement(id: u128, pending_movement_id: u128, domain: u32, code: u16) Movement {
    return Movement{
        .id = id,
        .debit_account_id = 0,
        .credit_account_id = 0,
        .amount = 0,
        .pending_id = pending_movement_id,
        .user_data_128 = 0,
        .user_data_64 = 0,
        .user_data_32 = 0,
        .timeout = 0,
        .ledger = domain,
        .code = code,
        .flags = .{ .post_pending_transfer = true },
        .timestamp = 0,
    };
}

/// Create a movement that voids (cancels) a pending movement.
pub fn voidMovement(id: u128, pending_movement_id: u128, domain: u32, code: u16) Movement {
    return Movement{
        .id = id,
        .debit_account_id = 0,
        .credit_account_id = 0,
        .amount = 0,
        .pending_id = pending_movement_id,
        .user_data_128 = 0,
        .user_data_64 = 0,
        .user_data_32 = 0,
        .timeout = 0,
        .ledger = domain,
        .code = code,
        .flags = .{ .void_pending_transfer = true },
        .timestamp = 0,
    };
}

// ============================================================================
// Domain Constants - Common codes for different use cases
// ============================================================================

/// Common container type codes for inventory domain
pub const InventoryCodes = struct {
    pub const storage: u16 = 1; // Regular storage location
    pub const receiving: u16 = 2; // Inbound staging
    pub const shipping: u16 = 3; // Outbound staging
    pub const quarantine: u16 = 4; // Held for inspection
    pub const external_supplier: u16 = 10; // Supplier (boundary)
    pub const external_customer: u16 = 11; // Customer (boundary)
};

/// Common movement type codes for inventory domain
pub const InventoryMovementCodes = struct {
    pub const receive: u16 = 1; // Goods received from supplier
    pub const putaway: u16 = 2; // Move to storage
    pub const pick: u16 = 3; // Pick for order
    pub const ship: u16 = 4; // Ship to customer
    pub const transfer: u16 = 5; // Internal transfer
    pub const adjust: u16 = 6; // Inventory adjustment
    pub const genesis: u16 = 100; // Initial balance load
};

// ============================================================================
// Balance Helpers
// ============================================================================

/// Get the available balance (can be moved out without going negative).
/// For inventory: this is "available to promise" quantity.
pub fn availableBalance(c: *const Container) u128 {
    const total_credits = c.credits_posted;
    const committed_debits = c.debits_posted + c.debits_pending;
    if (total_credits >= committed_debits) {
        return total_credits - committed_debits;
    }
    return 0;
}

/// Get the total balance (ignoring pending).
pub fn totalBalance(c: *const Container) i128 {
    return @as(i128, c.credits_posted) - @as(i128, c.debits_posted);
}

/// Get pending inbound quantity.
pub fn pendingInbound(c: *const Container) u128 {
    return c.credits_pending;
}

/// Get pending outbound quantity.
pub fn pendingOutbound(c: *const Container) u128 {
    return c.debits_pending;
}

// ============================================================================
// Tests
// ============================================================================

test "containerId generates consistent IDs" {
    const id1 = containerId(.{ .warehouse = "BOSTON", .sku = "SKU-1234" });
    const id2 = containerId(.{ .warehouse = "BOSTON", .sku = "SKU-1234" });
    const id3 = containerId(.{ .warehouse = "CHICAGO", .sku = "SKU-1234" });

    try std.testing.expectEqual(id1, id2);
    try std.testing.expect(id1 != id3);
    try std.testing.expect(id1 != 0);
}

test "container builder creates valid container" {
    const c = container(12345, 1, InventoryCodes.storage);
    try std.testing.expectEqual(@as(u128, 12345), c.id);
    try std.testing.expectEqual(@as(u32, 1), c.ledger);
    try std.testing.expectEqual(InventoryCodes.storage, c.code);
}

test "movement builder creates valid movement" {
    const m = movement(1, 100, 200, 50, 1, InventoryMovementCodes.transfer);
    try std.testing.expectEqual(@as(u128, 1), m.id);
    try std.testing.expectEqual(@as(u128, 100), m.debit_account_id);
    try std.testing.expectEqual(@as(u128, 200), m.credit_account_id);
    try std.testing.expectEqual(@as(u128, 50), m.amount);
}

test "pending movement sets flags correctly" {
    const m = pendingMovement(1, 100, 200, 50, 1, 1, 3600);
    try std.testing.expect(m.flags.pending);
    try std.testing.expectEqual(@as(u32, 3600), m.timeout);
}

test "Container is binary compatible size" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Container));
}

test "Movement is binary compatible size" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Movement));
}
