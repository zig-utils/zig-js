const js = @import("js");

pub const Profile = struct {
    workload: []const u8,
    entry_path: []const u8,
    entry_source: []const u8,
    modules: []const Module,

    const Module = struct {
        path: []const u8,
        source: []const u8,
    };

    fn load(raw: *anyopaque, _: []const u8, specifier: []const u8, out_path: *[]const u8) ?[]const u8 {
        const self: *const Profile = @ptrCast(@alignCast(raw));
        const name = if (specifier.len >= 2 and specifier[0] == '.' and specifier[1] == '/') specifier[2..] else specifier;
        for (self.modules) |module| {
            if (std.mem.eql(u8, module.path, name)) {
                out_path.* = module.path;
                return module.source;
            }
        }
        return null;
    }

    pub fn host(self: *const Profile) js.Context.ModuleHost {
        return .{ .ctx = @constCast(self), .load = load };
    }
};

const std = @import("std");

const base_modules = [_]Profile.Module{
    .{
        .path = "ops.js",
        .source =
        \\export function transform(value, index) {
        \\  return (value * 17 + index * 13 + 7) % 1000003;
        \\}
        ,
    },
    .{
        .path = "data.js",
        .source =
        \\export const values = [3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 610, 987, 1597, 2584, 4181];
        ,
    },
    .{
        .path = "dynamic.js",
        .source =
        \\import { transform } from "./ops.js";
        \\export function finish(total, lane) {
        \\  return total + transform(lane + 19, 23);
        \\}
        ,
    },
};

const variant_modules = [_]Profile.Module{
    .{
        .path = "math.js",
        .source =
        \\export function remap(input, position) {
        \\  return (input * 17 + position * 13 + 7) % 1000003;
        \\}
        ,
    },
    .{
        .path = "records.js",
        .source =
        \\export const records = [4181, 2584, 1597, 987, 610, 377, 233, 144, 89, 55, 34, 21, 13, 8, 5, 3];
        ,
    },
    .{
        .path = "late.js",
        .source =
        \\import { remap } from "./math.js";
        \\export function complete(accumulator, worker) {
        \\  return accumulator + remap(worker + 19, 23);
        \\}
        ,
    },
};

const base = Profile{
    .workload = "representative_modules_dynamic",
    .entry_path = "entry.js",
    .entry_source =
    \\import { transform } from "./ops.js";
    \\import { values } from "./data.js";
    \\var total = 0;
    \\for (var job = 0; job < globalThis.__benchmarkJobs; job = job + 1) {
    \\  for (var index = 0; index < values.length; index = index + 1)
    \\    total = total + transform(values[index] + job + globalThis.__benchmarkLane, index);
    \\}
    \\const dynamic = await import("./dynamic.js");
    \\globalThis.__representativeModuleChecksum = dynamic.finish(total, globalThis.__benchmarkLane);
    ,
    .modules = &base_modules,
};

const variant = Profile{
    .workload = "representative_modules_dynamic_variant",
    .entry_path = "main.js",
    .entry_source =
    \\import { records } from "./records.js";
    \\import { remap } from "./math.js";
    \\var accumulator = 0;
    \\for (var task = 0; task < globalThis.__benchmarkJobs; task = task + 1) {
    \\  for (var cursor = records.length - 1; cursor >= 0; cursor = cursor - 1)
    \\    accumulator = accumulator + remap(records[cursor] + task + globalThis.__benchmarkLane, records.length - 1 - cursor);
    \\}
    \\const late = await import("./late.js");
    \\globalThis.__representativeModuleChecksum = late.complete(accumulator, globalThis.__benchmarkLane);
    ,
    .modules = &variant_modules,
};

pub fn profile(workload: []const u8) ?*const Profile {
    if (std.mem.eql(u8, workload, base.workload)) return &base;
    if (std.mem.eql(u8, workload, variant.workload)) return &variant;
    return null;
}
