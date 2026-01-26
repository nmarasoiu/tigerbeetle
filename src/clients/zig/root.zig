//! Resource Ledger Extensions for TigerBeetle
//!
//! This module provides two composable extensions on top of the TigerBeetle client:
//!
//! 1. **resource_ledger**: Domain-agnostic vocabulary (Container, Movement vs Account, Transfer)
//!    - Renames concepts for non-financial domains (inventory, loyalty, quotas)
//!    - Provides ID generation from business keys via hashing
//!    - Thin wrapper, no semantic changes
//!
//! 2. **multi_ledger**: Hierarchical account aggregation
//!    - One physical movement → N logical movements (linked, atomic)
//!    - Physical = the real thing (box moves from A to B)
//!    - Logical = accounting reflections at different aggregation levels
//!    - Write amplification is the feature: query at any level without app-side joins
//!
//! These can be used independently or composed together.

const std = @import("std");

pub const resource_ledger = @import("resource_ledger.zig");
pub const multi_ledger = @import("multi_ledger.zig");

// Re-export types from resource_ledger for convenience
pub const Container = resource_ledger.Container;
pub const Movement = resource_ledger.Movement;
pub const ContainerFlags = resource_ledger.ContainerFlags;
pub const MovementFlags = resource_ledger.MovementFlags;

test {
    std.testing.refAllDecls(@This());
}
