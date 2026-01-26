//! Resource Ledger Extensions for TigerBeetle
//!
//! Domain-agnostic vocabulary (Container, Movement vs Account, Transfer)
//! - Renames concepts for non-financial domains (inventory, loyalty, quotas)
//! - Provides ID generation from business keys via hashing
//! - Thin wrapper, no semantic changes

const std = @import("std");

pub const resource_ledger = @import("resource_ledger.zig");

// Re-export types from resource_ledger for convenience
pub const Container = resource_ledger.Container;
pub const Movement = resource_ledger.Movement;
pub const ContainerFlags = resource_ledger.ContainerFlags;
pub const MovementFlags = resource_ledger.MovementFlags;

test {
    std.testing.refAllDecls(@This());
}
