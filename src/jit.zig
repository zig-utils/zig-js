//! Architecture-neutral foundations for the baseline native tier.
//!
//! This module owns executable mappings and their write-to-execute transition.
//! Backends emit bytes through `writableBytes`, publish once, and thereafter
//! only retain the immutable `executableBytes` view. Unsupported targets return
//! `error.UnsupportedTarget`, leaving bytecode execution unchanged.

const std = @import("std");
const builtin = @import("builtin");

const aarch64 = @import("jit/aarch64.zig");

const is_darwin = switch (builtin.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
    else => false,
};

pub const supported = is_darwin and switch (builtin.cpu.arch) {
    .aarch64, .x86_64 => true,
    else => false,
};

pub const TierState = enum(u8) { cold, compiling, ready, rejected };

/// Coarse value categories collected per function for optimizer decisions.
/// Profiles are advisory: generated code must guard every assumption derived
/// from them and deoptimize when a guard fails.
pub const ProfileValueKind = enum(u3) {
    undefined,
    null,
    boolean,
    number,
    string,
    object,
};

/// Per-function optimizer profile. Mutators accumulate observations in a
/// thread-local `Delta` and merge once per VM entry, avoiding atomic traffic in
/// hot loops while still making snapshots race-free under shared-realm JS.
pub const OptimizerProfile = struct {
    entries: std.atomic.Value(u64) = .init(0),
    branches_taken: std.atomic.Value(u64) = .init(0),
    branches_not_taken: std.atomic.Value(u64) = .init(0),
    backedges: std.atomic.Value(u64) = .init(0),
    value_kinds: std.atomic.Value(u8) = .init(0),
    first_shape: std.atomic.Value(usize) = .init(0),
    polymorphic_shapes: std.atomic.Value(bool) = .init(false),

    pub const Delta = struct {
        branches_taken: u64 = 0,
        branches_not_taken: u64 = 0,
        backedges: u64 = 0,
        value_kinds: u8 = 0,
        first_shape: usize = 0,
        polymorphic_shapes: bool = false,

        pub fn observeBranch(self: *Delta, taken: bool) void {
            if (taken) self.branches_taken +%= 1 else self.branches_not_taken +%= 1;
        }

        pub fn observeBackedge(self: *Delta) void {
            self.backedges +%= 1;
        }

        pub fn observeValue(self: *Delta, kind: ProfileValueKind) void {
            self.value_kinds |= @as(u8, 1) << @backingInt(kind);
        }

        pub fn observeShape(self: *Delta, token: usize) void {
            if (token == 0) return;
            if (self.first_shape == 0) {
                self.first_shape = token;
            } else if (self.first_shape != token) {
                self.polymorphic_shapes = true;
            }
        }
    };

    pub const Snapshot = struct {
        entries: u64,
        branches_taken: u64,
        branches_not_taken: u64,
        backedges: u64,
        value_kinds: u8,
        first_shape: usize,
        polymorphic_shapes: bool,

        pub fn sawValue(self: Snapshot, kind: ProfileValueKind) bool {
            return self.value_kinds & (@as(u8, 1) << @backingInt(kind)) != 0;
        }
    };

    pub fn observeEntry(self: *OptimizerProfile) void {
        _ = self.entries.fetchAdd(1, .monotonic);
    }

    pub fn merge(self: *OptimizerProfile, delta: Delta) void {
        if (delta.branches_taken != 0) _ = self.branches_taken.fetchAdd(delta.branches_taken, .monotonic);
        if (delta.branches_not_taken != 0) _ = self.branches_not_taken.fetchAdd(delta.branches_not_taken, .monotonic);
        if (delta.backedges != 0) _ = self.backedges.fetchAdd(delta.backedges, .monotonic);
        if (delta.value_kinds != 0) _ = self.value_kinds.fetchOr(delta.value_kinds, .monotonic);
        if (delta.first_shape != 0) self.observeShape(delta.first_shape);
        if (delta.polymorphic_shapes) self.polymorphic_shapes.store(true, .release);
    }

    pub fn snapshot(self: *const OptimizerProfile) Snapshot {
        return .{
            .entries = self.entries.load(.acquire),
            .branches_taken = self.branches_taken.load(.acquire),
            .branches_not_taken = self.branches_not_taken.load(.acquire),
            .backedges = self.backedges.load(.acquire),
            .value_kinds = self.value_kinds.load(.acquire),
            .first_shape = self.first_shape.load(.acquire),
            .polymorphic_shapes = self.polymorphic_shapes.load(.acquire),
        };
    }

    fn observeShape(self: *OptimizerProfile, token: usize) void {
        if (self.first_shape.cmpxchgStrong(0, token, .acq_rel, .acquire)) |existing| {
            if (existing != token) self.polymorphic_shapes.store(true, .release);
        }
    }
};

pub const OptimizerTierState = enum(u8) {
    cold,
    profiling,
    compiling,
    ready,
    rejected,
    invalidating,
};

/// A publication state machine distinct from the baseline `Tier`. The artifact
/// pointer is opaque here so the architecture-neutral IR can evolve without a
/// bytecode ↔ optimizer import cycle. Its owner must retain the artifact for
/// every execution lease that can observe `ready`.
pub const OptimizerTier = struct {
    state: std.atomic.Value(OptimizerTierState) = .init(.cold),
    artifact: std.atomic.Value(usize) = .init(0),
    generation: std.atomic.Value(u64) = .init(0),
    installed_compiles: std.atomic.Value(u64) = .init(0),
    publication_lock: std.atomic.Mutex = .unlocked,

    pub const CompilationClaim = struct {
        generation: u64,
    };

    pub fn beginProfiling(self: *OptimizerTier) void {
        _ = self.state.cmpxchgStrong(.cold, .profiling, .acq_rel, .acquire);
    }

    pub fn claimCompilation(self: *OptimizerTier, profile: *const OptimizerProfile, threshold: u64) ?CompilationClaim {
        std.debug.assert(threshold > 0);
        self.beginProfiling();
        if (profile.entries.load(.acquire) < threshold) return null;
        self.acquirePublicationLock();
        defer self.publication_lock.unlock();
        if (self.state.load(.acquire) != .profiling) return null;
        const current_generation = self.generation.load(.acquire);
        self.state.store(.compiling, .release);
        return .{ .generation = current_generation };
    }

    pub fn publishReady(self: *OptimizerTier, claim: CompilationClaim, artifact: *const anyopaque) bool {
        self.acquirePublicationLock();
        defer self.publication_lock.unlock();
        if (self.state.load(.acquire) != .compiling or self.generation.load(.acquire) != claim.generation) return false;
        self.artifact.store(@intFromPtr(artifact), .monotonic);
        _ = self.installed_compiles.fetchAdd(1, .monotonic);
        self.state.store(.ready, .release);
        return true;
    }

    pub fn publishRejected(self: *OptimizerTier, claim: CompilationClaim) bool {
        self.acquirePublicationLock();
        defer self.publication_lock.unlock();
        if (self.state.load(.acquire) != .compiling or self.generation.load(.acquire) != claim.generation) return false;
        self.state.store(.rejected, .release);
        return true;
    }

    pub fn invalidate(self: *OptimizerTier) void {
        self.acquirePublicationLock();
        defer self.publication_lock.unlock();
        self.state.store(.invalidating, .release);
        _ = self.generation.fetchAdd(1, .acq_rel);
        self.artifact.store(0, .release);
        self.state.store(.profiling, .release);
    }

    pub fn loadArtifact(self: *const OptimizerTier, comptime T: type) ?*const T {
        if (self.state.load(.acquire) != .ready) return null;
        const address = self.artifact.load(.monotonic);
        if (address == 0) return null;
        return @ptrFromInt(address);
    }

    pub fn compileCount(self: *const OptimizerTier) u64 {
        return self.installed_compiles.load(.acquire);
    }

    fn acquirePublicationLock(self: *OptimizerTier) void {
        while (!self.publication_lock.tryLock()) std.atomic.spinLoopHint();
    }
};

/// Per-chunk hotness and single-writer compilation claim.
///
/// Entrants that lose the claim never wait: they continue in bytecode while
/// the winning thread compiles. Publishing `ready` or `rejected` releases all
/// compiler writes to later acquire readers.
pub const Tier = struct {
    state: std.atomic.Value(TierState) = .init(.cold),
    entries: std.atomic.Value(u32) = .init(0),
    code: ?*CompiledCode = null,

    pub fn observeEntry(self: *Tier, threshold: u32) bool {
        std.debug.assert(threshold > 0);
        if (self.state.load(.monotonic) != .cold) return false;
        const previous = self.entries.fetchAdd(1, .monotonic);
        if (previous < threshold - 1) return false;
        return self.state.cmpxchgStrong(.cold, .compiling, .acq_rel, .monotonic) == null;
    }

    pub fn loadState(self: *const Tier) TierState {
        return self.state.load(.acquire);
    }

    pub fn publishReady(self: *Tier, code: *CompiledCode) void {
        std.debug.assert(self.state.load(.monotonic) == .compiling);
        self.code = code;
        self.state.store(.ready, .release);
    }

    pub fn loadCode(self: *const Tier) ?*const CompiledCode {
        if (self.state.load(.acquire) != .ready) return null;
        return self.code.?;
    }

    pub fn publishRejected(self: *Tier) void {
        std.debug.assert(self.state.load(.monotonic) == .compiling);
        self.state.store(.rejected, .release);
    }

    /// Return this tier to bytecode-only cold state. The owning executable-code
    /// registry calls this only while new native leases are blocked and every
    /// prior lease has retired, so clearing the non-atomic code pointer cannot
    /// race a native entrant.
    pub fn invalidate(self: *Tier) void {
        self.code = null;
        self.entries.store(0, .monotonic);
        self.state.store(.cold, .release);
    }
};

pub const ExitStatus = enum(u32) { complete, side_exit, throw, stop };
pub const numeric_scratch_capacity = 64;

/// Stable C-compatible boundary between generated code and the Zig runtime.
/// More fields are appended as lowering grows; generated code only addresses
/// fields through backend constants derived with `@offsetOf`.
pub const NativeFrame = extern struct {
    result_bits: u64 = 0,
    exit_ip: usize = 0,
    /// Raw NaN-boxed function slots. The VM keeps the owning activation rooted
    /// for the entire native call; generated code may only access indexes that
    /// the chunk's immutable frame metadata proves in bounds.
    slots: ?[*]u64 = null,
    /// Caller-owned spill storage for the native operand stack. The first
    /// numeric tier permits no GC pointer here, so precise tracing needs no
    /// backend-specific stack map.
    scratch: ?[*]u64 = null,
    /// Exact interpreter step counter, updated before every native safepoint
    /// and on every exit.
    steps: ?*u64 = null,
    runtime_context: ?*anyopaque = null,
    /// Returns zero to continue or a non-zero `ExitStatus` value to leave
    /// native code after servicing budget, termination, GIL, and GC work.
    checkpoint: ?*const fn (*NativeFrame) callconv(.c) u32 = null,
    /// Full Number remainder semantics for operands outside the generated
    /// positive-small-integer fast path.
    remainder: ?*const fn (f64, f64) callconv(.c) f64 = null,
    steps_until_checkpoint: u64 = 0,
    steps_until_budget: u64 = 0,
    /// Index into the published artifact's immutable deoptimization table.
    /// Generated code sets this together with `exit_ip` before `side_exit`.
    deopt_index: usize = std.math.maxInt(usize),
};

pub const NativeEntry = *const fn (*NativeFrame) callconv(.c) u32;

pub const CodeKind = enum(u8) { baseline, optimizer };

pub const RecoverySource = enum(u8) { frame_slot, scratch_slot, constant };

pub const RecoveryValue = struct {
    source: RecoverySource,
    index: u8 = 0,
    bits: u64 = 0,

    pub fn materialize(self: RecoveryValue, frame_slots: []const u64, scratch_slots: []const u64) ?u64 {
        return switch (self.source) {
            .frame_slot => if (self.index < frame_slots.len) frame_slots[self.index] else null,
            .scratch_slot => if (self.index < scratch_slots.len) scratch_slots[self.index] else null,
            .constant => self.bits,
        };
    }
};

pub const DeoptPointKind = enum(u8) { block_entry, branch, return_, edge };

pub const DeoptPoint = struct {
    kind: DeoptPointKind,
    exit_ip: u32,
    first_value: u32,
    local_count: u16,
    stack_count: u16,
    handler_count: u16 = 0,
    accumulator: RecoveryValue,
};

/// Immutable reconstruction table owned by one published native artifact.
/// Values are stored in locals-then-operand-stack order for each point.
pub const DeoptMetadata = struct {
    allocator: std.mem.Allocator,
    points: []DeoptPoint,
    values: []RecoveryValue,

    pub fn create(
        allocator: std.mem.Allocator,
        points: []const DeoptPoint,
        values: []const RecoveryValue,
    ) std.mem.Allocator.Error!*DeoptMetadata {
        const metadata = try allocator.create(DeoptMetadata);
        errdefer allocator.destroy(metadata);
        const owned_points = try allocator.dupe(DeoptPoint, points);
        errdefer allocator.free(owned_points);
        const owned_values = try allocator.dupe(RecoveryValue, values);
        metadata.* = .{ .allocator = allocator, .points = owned_points, .values = owned_values };
        return metadata;
    }

    pub fn destroy(self: *DeoptMetadata) void {
        const allocator = self.allocator;
        allocator.free(self.points);
        allocator.free(self.values);
        allocator.destroy(self);
    }
};

pub const OsrImportSource = enum(u8) { frame_slot, stack_slot };

/// One exact VM value imported into an optimizer SSA scratch slot on OSR entry.
pub const OsrImport = struct {
    source: OsrImportSource,
    source_index: u16,
    destination: u8,
};

/// Eligibility is intentionally exact. A different IP, stack shape, handler
/// depth, or accumulator must continue in bytecode rather than guessing state.
pub const OsrEntry = struct {
    entry_ip: u32,
    first_import: u32,
    local_count: u16,
    stack_count: u16,
    handler_count: u16 = 0,
    accumulator_bits: u64,
};

/// Immutable loop-entry table prepared from optimizer SSA. Backends may only
/// advertise an entry after they can consume every import in its selected row.
pub const OsrMetadata = struct {
    allocator: std.mem.Allocator,
    entries: []OsrEntry,
    imports: []OsrImport,

    pub fn create(
        allocator: std.mem.Allocator,
        entries: []const OsrEntry,
        imports: []const OsrImport,
    ) std.mem.Allocator.Error!*OsrMetadata {
        const metadata = try allocator.create(OsrMetadata);
        errdefer allocator.destroy(metadata);
        const owned_entries = try allocator.dupe(OsrEntry, entries);
        errdefer allocator.free(owned_entries);
        const owned_imports = try allocator.dupe(OsrImport, imports);
        metadata.* = .{ .allocator = allocator, .entries = owned_entries, .imports = owned_imports };
        return metadata;
    }

    pub fn destroy(self: *OsrMetadata) void {
        const allocator = self.allocator;
        allocator.free(self.entries);
        allocator.free(self.imports);
        allocator.destroy(self);
    }

    pub fn findEntry(
        self: *const OsrMetadata,
        entry_ip: usize,
        local_count: usize,
        stack_count: usize,
        handler_count: usize,
        accumulator_bits: u64,
    ) ?usize {
        for (self.entries, 0..) |entry, index| {
            if (entry.entry_ip == entry_ip and entry.local_count == local_count and
                entry.stack_count == stack_count and entry.handler_count == handler_count and
                entry.accumulator_bits == accumulator_bits)
                return index;
        }
        return null;
    }

    pub fn prepareScratch(
        self: *const OsrMetadata,
        entry_index: usize,
        frame_slots: []const u64,
        operand_stack: []const u64,
        scratch: []u64,
    ) bool {
        if (entry_index >= self.entries.len) return false;
        const entry = self.entries[entry_index];
        if (frame_slots.len != entry.local_count or operand_stack.len != entry.stack_count) return false;
        const first: usize = entry.first_import;
        const count: usize = entry.local_count + entry.stack_count;
        if (first > self.imports.len or count > self.imports.len - first) return false;
        for (self.imports[first .. first + count]) |import| {
            if (import.destination >= scratch.len) return false;
            switch (import.source) {
                .frame_slot => if (import.source_index >= frame_slots.len) return false,
                .stack_slot => if (import.source_index >= operand_stack.len) return false,
            }
        }
        for (self.imports[first .. first + count]) |import| {
            scratch[import.destination] = switch (import.source) {
                .frame_slot => frame_slots[import.source_index],
                .stack_slot => operand_stack[import.source_index],
            };
        }
        return true;
    }
};

pub const CompiledCode = struct {
    memory: CodeMemory,
    entry: NativeEntry,
    kind: CodeKind = .baseline,
    /// Number of bytecode dispatches represented by a successful native entry.
    /// Used to preserve the interpreter's step-budget/checkpoint accounting.
    bytecode_steps: u32 = 0,
    /// Numeric/control entries update the interpreter counter themselves and
    /// call the runtime exactly at bytecode checkpoint boundaries.
    manages_steps: bool = false,
    frame_slots: u32 = 0,
    required_numeric_slots: u64 = 0,
    /// Parameter slots that must contain canonical non-negative u32 Numbers.
    /// The VM checks this before native step accounting or slot mutation, so a
    /// failed speculative integer entry restarts safely at bytecode IP zero.
    required_u32_slots: u64 = 0,
    max_stack_depth: u8 = 0,
    deopt: ?*DeoptMetadata = null,
    osr: ?*OsrMetadata = null,
    /// False for an artifact that may only be entered through an exact OSR row.
    entry_enabled: bool = true,
    /// A side exit may have executed observable bytecode and must resume from
    /// `deopt`; direct/restart-only entry paths reject such artifacts.
    has_side_exits: bool = false,

    pub fn deinit(self: *CompiledCode) void {
        self.memory.deinit();
        if (self.deopt) |metadata| metadata.destroy();
        if (self.osr) |metadata| metadata.destroy();
        self.* = undefined;
    }

    pub fn run(self: *const CompiledCode, frame: *NativeFrame) ExitStatus {
        return @enumFromInt(self.entry(frame));
    }
};

/// Context-owned lifetime registry for immutable compiled mappings. Adoption is
/// serialized because different shared-realm chunks can tier concurrently;
/// teardown runs only after all JavaScript threads have joined.
pub const Owner = struct {
    allocator: ?std.mem.Allocator = null,
    lock: std.atomic.Mutex = .unlocked,
    codes: std.ArrayListUnmanaged(*CompiledCode) = .empty,
    tiers: std.ArrayListUnmanaged(*Tier) = .empty,
    optimizer_tiers: std.ArrayListUnmanaged(*OptimizerTier) = .empty,
    active_leases: std.atomic.Value(usize) = .init(0),
    invalidating: std.atomic.Value(bool) = .init(false),

    pub const AdoptError = std.mem.Allocator.Error || error{Invalidated};

    pub const Compilation = struct {
        owner: *Owner,

        pub fn release(self: *Compilation) void {
            _ = self.owner.active_leases.fetchSub(1, .release);
            self.* = undefined;
        }
    };

    pub const OptimizerCompilation = struct {
        owner: *Owner,
        claim: OptimizerTier.CompilationClaim,

        pub fn release(self: *OptimizerCompilation) void {
            _ = self.owner.active_leases.fetchSub(1, .release);
            self.* = undefined;
        }
    };

    pub const Execution = struct {
        owner: *Owner,

        pub fn release(self: *Execution) void {
            _ = self.owner.active_leases.fetchSub(1, .release);
            self.* = undefined;
        }
    };

    pub fn init(allocator: std.mem.Allocator) Owner {
        return .{ .allocator = allocator };
    }

    /// Atomically adopt a mapping, register its tier for later invalidation,
    /// and publish the ready entry. Publication under the owner lock closes the
    /// race where code deletion could otherwise miss a just-compiled tier.
    pub fn adoptAndPublish(self: *Owner, tier: *Tier, compiled: CompiledCode) AdoptError!*CompiledCode {
        const allocator = self.allocator orelse return error.OutOfMemory;
        const owned = try allocator.create(CompiledCode);
        errdefer allocator.destroy(owned);

        self.acquireLock();
        defer self.lock.unlock();
        if (self.invalidating.load(.acquire)) return error.Invalidated;
        try self.codes.ensureUnusedCapacity(allocator, 1);
        try self.tiers.ensureUnusedCapacity(allocator, 1);
        owned.* = compiled;
        self.codes.appendAssumeCapacity(owned);
        self.tiers.appendAssumeCapacity(tier);
        tier.publishReady(owned);
        return owned;
    }

    /// Adopt and publish one immutable optimizer artifact under the same owner
    /// lease as baseline code. Owner→tier lock ordering is shared with `clear`,
    /// so deletion cannot miss or overtake a successful publication.
    pub fn adoptOptimizerAndPublish(
        self: *Owner,
        tier: *OptimizerTier,
        claim: OptimizerTier.CompilationClaim,
        compiled: CompiledCode,
    ) AdoptError!*CompiledCode {
        const allocator = self.allocator orelse return error.OutOfMemory;
        const owned = try allocator.create(CompiledCode);
        errdefer allocator.destroy(owned);

        self.acquireLock();
        defer self.lock.unlock();
        if (self.invalidating.load(.acquire)) return error.Invalidated;
        try self.codes.ensureUnusedCapacity(allocator, 1);
        try self.optimizer_tiers.ensureUnusedCapacity(allocator, 1);
        owned.* = compiled;
        if (!tier.publishReady(claim, owned)) return error.Invalidated;
        self.codes.appendAssumeCapacity(owned);
        self.optimizer_tiers.appendAssumeCapacity(tier);
        return owned;
    }

    /// Protect one outer VM execution, amortizing invalidation synchronization
    /// across every native entry it performs. Nested VM calls inherit the same
    /// lease through `Interpreter.jit_execution_depth`.
    pub fn enterExecution(self: *Owner) ?Execution {
        if (self.invalidating.load(.acquire)) return null;
        _ = self.active_leases.fetchAdd(1, .acquire);
        if (self.invalidating.load(.acquire)) {
            _ = self.active_leases.fetchSub(1, .release);
            return null;
        }
        return .{ .owner = self };
    }

    /// Claim compilation as an owner operation so invalidation cannot finish
    /// while a pre-existing compiler is still capable of publishing code.
    pub fn claimCompilation(self: *Owner, tier: *Tier, threshold: u32) ?Compilation {
        if (self.invalidating.load(.acquire)) return null;
        _ = self.active_leases.fetchAdd(1, .acquire);
        if (self.invalidating.load(.acquire) or !tier.observeEntry(threshold)) {
            _ = self.active_leases.fetchSub(1, .release);
            return null;
        }
        return .{ .owner = self };
    }

    pub fn claimOptimizerCompilation(
        self: *Owner,
        tier: *OptimizerTier,
        profile: *const OptimizerProfile,
        threshold: u64,
    ) ?OptimizerCompilation {
        if (self.invalidating.load(.acquire)) return null;
        _ = self.active_leases.fetchAdd(1, .acquire);
        if (self.invalidating.load(.acquire)) {
            _ = self.active_leases.fetchSub(1, .release);
            return null;
        }
        const claim = tier.claimCompilation(profile, threshold) orelse {
            _ = self.active_leases.fetchSub(1, .release);
            return null;
        };
        return .{ .owner = self, .claim = claim };
    }

    /// Invalidate every published tier before releasing executable mappings.
    /// A later entry observes `.cold` and may compile a fresh mapping.
    pub fn clear(self: *Owner) void {
        if (self.allocator == null) return;
        self.beginInvalidation();
        while (self.active_leases.load(.acquire) != 0) std.Thread.yield() catch {};

        self.acquireLock();
        for (self.tiers.items) |tier| tier.invalidate();
        self.tiers.clearRetainingCapacity();
        for (self.optimizer_tiers.items) |tier| tier.invalidate();
        self.optimizer_tiers.clearRetainingCapacity();
        const allocator = self.allocator.?;
        for (self.codes.items) |code| {
            code.deinit();
            allocator.destroy(code);
        }
        self.codes.clearRetainingCapacity();
        self.lock.unlock();
        self.invalidating.store(false, .release);
    }

    pub fn deinit(self: *Owner) void {
        const allocator = self.allocator orelse return;
        self.beginInvalidation();
        while (self.active_leases.load(.acquire) != 0) std.Thread.yield() catch {};
        self.acquireLock();
        for (self.tiers.items) |tier| tier.invalidate();
        for (self.optimizer_tiers.items) |tier| tier.invalidate();
        for (self.codes.items) |code| {
            code.deinit();
            allocator.destroy(code);
        }
        self.codes.deinit(allocator);
        self.tiers.deinit(allocator);
        self.optimizer_tiers.deinit(allocator);
        self.lock.unlock();
        self.* = .{};
    }

    fn acquireLock(self: *Owner) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn beginInvalidation(self: *Owner) void {
        while (self.invalidating.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
            while (self.invalidating.load(.acquire)) std.Thread.yield() catch {};
        }
    }
};

const State = enum { writable, executable };

/// One immutable-after-publication native-code mapping.
///
/// Darwin's JIT write protection is thread-local. Consequently allocation,
/// emission, and `publish` must happen on the compilation-claiming thread with
/// no call into untrusted code between them. The tier state machine guarantees
/// that only one thread owns a mapping before publication.
pub const CodeMemory = struct {
    mapping: []align(std.heap.page_size_min) u8,
    used: usize = 0,
    state: State = .writable,

    pub fn init(min_capacity: usize) !CodeMemory {
        if (!supported) return error.UnsupportedTarget;
        if (min_capacity == 0) return error.InvalidCapacity;

        const capacity = std.mem.alignForward(usize, min_capacity, std.heap.page_size_min);
        const protection: std.posix.PROT = .{ .READ = true, .WRITE = true, .EXEC = true };
        var flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        flags.JIT = true;
        const mapping = try std.posix.mmap(null, capacity, protection, flags, -1, 0);

        // MAP_JIT pages are executable to other threads while this thread gets
        // the writable view. Re-enable protection in publish/deinit.
        pthread_jit_write_protect_np(0);
        return .{ .mapping = mapping };
    }

    pub fn deinit(self: *CodeMemory) void {
        if (self.state == .writable and supported) pthread_jit_write_protect_np(1);
        std.posix.munmap(self.mapping);
        self.* = undefined;
    }

    pub fn writableBytes(self: *CodeMemory) []u8 {
        std.debug.assert(self.state == .writable);
        return self.mapping;
    }

    /// Flush the emitted range and make it immutable on the compiling thread.
    /// The caller may publish the returned entry pointer only after this call.
    pub fn publish(self: *CodeMemory, used: usize) error{InvalidCodeSize}!void {
        if (used == 0 or used > self.mapping.len) return error.InvalidCodeSize;
        std.debug.assert(self.state == .writable);

        self.used = used;
        sys_icache_invalidate(self.mapping.ptr, used);
        pthread_jit_write_protect_np(1);
        self.state = .executable;
    }

    pub fn executableBytes(self: *const CodeMemory) []const u8 {
        std.debug.assert(self.state == .executable);
        return self.mapping[0..self.used];
    }
};

/// Compile the smallest real native entry: publish one exact NaN-boxed word as
/// a completed result. This is the backend/ABI bring-up primitive used before
/// bytecode lowering; it deliberately knows nothing about source text.
pub fn compileConstantEntry(result_bits: u64) !CompiledCode {
    if (!supported or builtin.cpu.arch != .aarch64) return error.UnsupportedTarget;

    var memory = try CodeMemory.init(32);
    errdefer memory.deinit();
    var assembler = aarch64.Assembler.init(memory.writableBytes());
    try assembler.movImmediate64(1, result_bits);
    try assembler.store64(1, 0, @offsetOf(NativeFrame, "result_bits"));
    try assembler.movImmediate32(0, @intFromEnum(ExitStatus.complete));
    try assembler.ret();
    try memory.publish(assembler.bytes().len);

    const entry: NativeEntry = @ptrCast(@alignCast(memory.executableBytes().ptr));
    return .{ .memory = memory, .entry = entry };
}

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

test "CodeMemory rejects empty mappings" {
    if (!supported) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, CodeMemory.init(0));
}

test "Tier claims compilation exactly at its hot threshold" {
    var tier = Tier{};
    try std.testing.expect(!tier.observeEntry(3));
    try std.testing.expect(!tier.observeEntry(3));
    try std.testing.expect(tier.observeEntry(3));
    try std.testing.expectEqual(TierState.compiling, tier.loadState());
    try std.testing.expect(!tier.observeEntry(3));
    var code: CompiledCode = undefined;
    tier.publishReady(&code);
    try std.testing.expectEqual(TierState.ready, tier.loadState());
    try std.testing.expectEqual(&code, tier.loadCode().?);
}

test "Tier caches an unsupported compilation" {
    var tier = Tier{};
    try std.testing.expect(tier.observeEntry(1));
    tier.publishRejected();
    try std.testing.expectEqual(TierState.rejected, tier.loadState());
    try std.testing.expect(!tier.observeEntry(1));
}

test "Tier permits one concurrent compiler" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const Shared = struct {
        tier: Tier = .{},
        claims: std.atomic.Value(u32) = .init(0),

        fn enter(shared: *@This()) void {
            var i: u32 = 0;
            while (i < 1000) : (i += 1) {
                if (shared.tier.observeEntry(32)) _ = shared.claims.fetchAdd(1, .monotonic);
            }
        }
    };

    var shared = Shared{};
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Shared.enter, .{&shared});
    for (&threads) |*thread| thread.join();

    try std.testing.expectEqual(@as(u32, 1), shared.claims.load(.monotonic));
    try std.testing.expectEqual(TierState.compiling, shared.tier.loadState());
    shared.tier.publishRejected();
}

test "optimizer profiles merge race-free per-entry deltas" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const Shared = struct {
        profile: OptimizerProfile = .{},

        fn observe(shared: *@This(), shape: usize) void {
            for (0..1000) |_| {
                shared.profile.observeEntry();
                var delta = OptimizerProfile.Delta{};
                delta.observeBranch(true);
                delta.observeBranch(false);
                delta.observeBackedge();
                delta.observeValue(.number);
                delta.observeShape(shape);
                shared.profile.merge(delta);
            }
        }
    };

    var shared = Shared{};
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Shared.observe, .{ &shared, index + 1 });
    }
    for (&threads) |*thread| thread.join();

    const snapshot = shared.profile.snapshot();
    try std.testing.expectEqual(@as(u64, 4000), snapshot.entries);
    try std.testing.expectEqual(@as(u64, 4000), snapshot.branches_taken);
    try std.testing.expectEqual(@as(u64, 4000), snapshot.branches_not_taken);
    try std.testing.expectEqual(@as(u64, 4000), snapshot.backedges);
    try std.testing.expect(snapshot.sawValue(.number));
    try std.testing.expect(snapshot.polymorphic_shapes);
}

test "optimizer tier publishes only installed artifacts and counts recompiles" {
    var profile = OptimizerProfile{};
    var tier = OptimizerTier{};
    var first_plan: u8 = 1;
    var second_plan: u8 = 2;

    profile.observeEntry();
    try std.testing.expect(tier.claimCompilation(&profile, 2) == null);
    profile.observeEntry();
    const stale_claim = tier.claimCompilation(&profile, 2) orelse return error.TestUnexpectedResult;
    tier.invalidate();
    try std.testing.expect(!tier.publishReady(stale_claim, &first_plan));
    try std.testing.expectEqual(@as(u64, 0), tier.compileCount());

    const first_claim = tier.claimCompilation(&profile, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(tier.publishReady(first_claim, &first_plan));
    try std.testing.expectEqual(&first_plan, tier.loadArtifact(u8).?);
    try std.testing.expectEqual(@as(u64, 1), tier.compileCount());

    tier.invalidate();
    try std.testing.expect(tier.loadArtifact(u8) == null);
    const second_claim = tier.claimCompilation(&profile, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(tier.publishReady(second_claim, &second_plan));
    try std.testing.expectEqual(&second_plan, tier.loadArtifact(u8).?);
    try std.testing.expectEqual(@as(u64, 2), tier.compileCount());

    tier.invalidate();
    const rejected_claim = tier.claimCompilation(&profile, 2) orelse return error.TestUnexpectedResult;
    try std.testing.expect(tier.publishRejected(rejected_claim));
    try std.testing.expect(tier.claimCompilation(&profile, 2) == null);
    try std.testing.expectEqual(OptimizerTierState.rejected, tier.state.load(.acquire));
    try std.testing.expectEqual(@as(u64, 3), tier.generation.load(.acquire));
    try std.testing.expectEqual(@as(u64, 2), tier.compileCount());
}

test "optimizer publication and invalidation races converge" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var profile = OptimizerProfile{};
    profile.observeEntry();
    var tier = OptimizerTier{};
    const claim = tier.claimCompilation(&profile, 1) orelse return error.TestUnexpectedResult;
    var plan: u8 = 1;
    const Shared = struct {
        tier: *OptimizerTier,
        claim: OptimizerTier.CompilationClaim,
        plan: *u8,
        start: std.atomic.Value(bool) = .init(false),
        published: std.atomic.Value(bool) = .init(false),

        fn awaitStart(shared: *@This()) void {
            while (!shared.start.load(.acquire)) std.atomic.spinLoopHint();
        }

        fn publish(shared: *@This()) void {
            shared.awaitStart();
            shared.published.store(shared.tier.publishReady(shared.claim, shared.plan), .release);
        }

        fn invalidate(shared: *@This()) void {
            shared.awaitStart();
            shared.tier.invalidate();
        }
    };
    var shared = Shared{ .tier = &tier, .claim = claim, .plan = &plan };
    var publisher = try std.Thread.spawn(.{}, Shared.publish, .{&shared});
    var invalidator = try std.Thread.spawn(.{}, Shared.invalidate, .{&shared});
    shared.start.store(true, .release);
    publisher.join();
    invalidator.join();

    try std.testing.expectEqual(OptimizerTierState.profiling, tier.state.load(.acquire));
    try std.testing.expect(tier.loadArtifact(u8) == null);
    try std.testing.expect(tier.compileCount() == 0 or tier.compileCount() == 1);
    try std.testing.expectEqual(shared.published.load(.acquire), tier.compileCount() == 1);
}

test "native entry publishes an exact result word through the stable ABI" {
    if (!supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const expected: u64 = 0x7ff8_1234_5678_9abc;
    var compiled = try compileConstantEntry(expected);
    defer compiled.deinit();
    var frame = NativeFrame{};
    try std.testing.expectEqual(ExitStatus.complete, compiled.run(&frame));
    try std.testing.expectEqual(expected, frame.result_bits);
    try std.testing.expectEqual(@as(usize, 0), frame.exit_ip);
}

test "Owner releases adopted executable mappings" {
    if (!supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var owner = Owner.init(std.testing.allocator);
    defer owner.deinit();
    var tier = Tier{};
    var compilation = owner.claimCompilation(&tier, 1) orelse return error.TestUnexpectedResult;
    _ = try owner.adoptAndPublish(&tier, try compileConstantEntry(0x1234));
    compilation.release();
    var execution = owner.enterExecution() orelse return error.TestUnexpectedResult;
    defer execution.release();
    const code = tier.loadCode() orelse return error.TestUnexpectedResult;
    var frame = NativeFrame{};
    try std.testing.expectEqual(ExitStatus.complete, code.run(&frame));
    try std.testing.expectEqual(@as(u64, 0x1234), frame.result_bits);
}

test "Owner adopts and invalidates optimizer artifacts under one lease" {
    if (!supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var owner = Owner.init(std.testing.allocator);
    defer owner.deinit();
    var profile = OptimizerProfile{};
    profile.observeEntry();
    var tier = OptimizerTier{};
    var compilation = owner.claimOptimizerCompilation(&tier, &profile, 1) orelse return error.TestUnexpectedResult;
    var compiled = try compileConstantEntry(0x4321);
    compiled.kind = .optimizer;
    _ = try owner.adoptOptimizerAndPublish(&tier, compilation.claim, compiled);
    compilation.release();
    try std.testing.expectEqual(CodeKind.optimizer, tier.loadArtifact(CompiledCode).?.kind);
    try std.testing.expectEqual(@as(u64, 1), tier.compileCount());

    owner.clear();
    try std.testing.expectEqual(OptimizerTierState.profiling, tier.state.load(.acquire));
    try std.testing.expect(tier.loadArtifact(CompiledCode) == null);
    try std.testing.expectEqual(@as(usize, 0), owner.codes.items.len);
    try std.testing.expectEqual(@as(usize, 0), owner.optimizer_tiers.items.len);
}

test "Owner invalidates tiers only after active native leases retire" {
    if (!supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var owner = Owner.init(std.testing.allocator);
    defer owner.deinit();
    var tier = Tier{};
    var compilation = owner.claimCompilation(&tier, 1) orelse return error.TestUnexpectedResult;
    _ = try owner.adoptAndPublish(&tier, try compileConstantEntry(0x5678));
    compilation.release();
    var execution = owner.enterExecution() orelse return error.TestUnexpectedResult;
    const code = tier.loadCode() orelse return error.TestUnexpectedResult;
    var frame = NativeFrame{};
    try std.testing.expectEqual(ExitStatus.complete, code.run(&frame));
    try std.testing.expectEqual(@as(u64, 0x5678), frame.result_bits);

    const Shared = struct {
        owner: *Owner,
        started: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(bool) = .init(false),

        fn clear(shared: *@This()) void {
            shared.started.store(true, .release);
            shared.owner.clear();
            shared.finished.store(true, .release);
        }
    };
    var shared = Shared{ .owner = &owner };
    var thread = try std.Thread.spawn(.{}, Shared.clear, .{&shared});
    while (!shared.started.load(.acquire)) std.atomic.spinLoopHint();
    for (0..32) |_| std.Thread.yield() catch {};
    try std.testing.expect(!shared.finished.load(.acquire));
    execution.release();
    thread.join();

    try std.testing.expect(shared.finished.load(.acquire));
    try std.testing.expectEqual(TierState.cold, tier.loadState());
    try std.testing.expect(tier.loadCode() == null);
    try std.testing.expectEqual(@as(usize, 0), owner.codes.items.len);
    try std.testing.expectEqual(@as(usize, 0), owner.tiers.items.len);
}

test "CodeMemory publishes and executes native code" {
    if (!supported) return error.SkipZigTest;

    const machine_code = switch (builtin.cpu.arch) {
        // mov w0, #42; ret
        .aarch64 => [_]u8{ 0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6 },
        // mov eax, 42; ret
        .x86_64 => [_]u8{ 0xb8, 0x2a, 0x00, 0x00, 0x00, 0x00, 0xc3 },
        else => unreachable,
    };

    var memory = try CodeMemory.init(machine_code.len);
    defer memory.deinit();
    @memcpy(memory.writableBytes()[0..machine_code.len], &machine_code);
    try memory.publish(machine_code.len);

    const NativeFn = *const fn () callconv(.c) u32;
    const entry: NativeFn = @ptrCast(@alignCast(memory.executableBytes().ptr));
    try std.testing.expectEqual(@as(u32, 42), entry());
}
