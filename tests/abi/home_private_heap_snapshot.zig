const std = @import("std");
const support = @import("heap_snapshot_fixture_support.zig");

extern fn Bun__generateHeapProfile(vm: *support.VM) *support.WTFStringImpl;
extern fn Bun__generateHeapSnapshotV8(vm: *support.VM) *support.WTFStringImpl;

pub fn main() !void {
    const fixture = try support.createFixtureVM();
    defer support.destroyFixtureVM(fixture.vm, fixture.global, fixture.sibling);
    try support.validateGCDebugging(fixture.global);

    const first_impl = Bun__generateHeapSnapshotV8(fixture.vm);
    defer support.Bun__WTFStringImpl__deref(first_impl);
    const first_bytes = try support.ownedImplBytes(std.heap.page_allocator, first_impl);
    defer std.heap.page_allocator.free(first_bytes);
    const first_id = try support.validateV8Snapshot(first_bytes);

    const second_impl = Bun__generateHeapSnapshotV8(fixture.vm);
    defer support.Bun__WTFStringImpl__deref(second_impl);
    const second_bytes = try support.ownedImplBytes(std.heap.page_allocator, second_impl);
    defer std.heap.page_allocator.free(second_bytes);
    try std.testing.expectEqual(first_id, try support.validateV8Snapshot(second_bytes));

    const profile_impl = Bun__generateHeapProfile(fixture.vm);
    defer support.Bun__WTFStringImpl__deref(profile_impl);
    const profile = try support.ownedImplBytes(std.heap.page_allocator, profile_impl);
    defer std.heap.page_allocator.free(profile);
    try support.validateProfile(profile);

    const gc_fixture = try support.createGcFixture();
    defer support.destroyGcFixture(gc_fixture.global);
    const before_impl = Bun__generateHeapSnapshotV8(gc_fixture.vm);
    defer support.Bun__WTFStringImpl__deref(before_impl);
    const before = try support.ownedImplBytes(std.heap.page_allocator, before_impl);
    defer std.heap.page_allocator.free(before);
    const before_id = try support.validateV8Snapshot(before);
    try support.compactGcFixture(gc_fixture.global);
    const after_impl = Bun__generateHeapSnapshotV8(gc_fixture.vm);
    defer support.Bun__WTFStringImpl__deref(after_impl);
    const after = try support.ownedImplBytes(std.heap.page_allocator, after_impl);
    defer std.heap.page_allocator.free(after);
    try std.testing.expectEqual(before_id, try support.validateV8Snapshot(after));
}
