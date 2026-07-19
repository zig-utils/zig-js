const std = @import("std");

const JSContextRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;

const EncodedValue = enum(i64) {
    empty = 0,
    _,

    fn fromRef(value: JSValueRef) EncodedValue {
        return @enumFromInt(@as(i64, @bitCast(@as(u64, @intFromPtr(value.?)))));
    }
};

const AbortSignal = opaque {};
const TimerState = enum(u8) { pending = 0, active = 1, cancelled = 2, fired = 3 };
const TimerTag = enum(u8) { abort_signal_timeout = 17, _ };
const TimerInHeap = enum(u8) { none = 0, regular = 1, fake = 2 };
const Timespec = extern struct { sec: i64, nsec: i64 };
const EventLoopTimer = extern struct {
    next: Timespec,
    heap: extern struct {
        child: ?*EventLoopTimer,
        prev: ?*EventLoopTimer,
        next: ?*EventLoopTimer,
    },
    state: TimerState,
    tag: TimerTag,
    in_heap: TimerInHeap,
};
const AbortSignalTimeout = extern struct {
    event_loop_timer: EventLoopTimer,
    signal: ?*AbortSignal,
    flags: u32,
    generation: u32,
};

comptime {
    if (@sizeOf(AbortSignalTimeout) != 64 or
        @offsetOf(AbortSignalTimeout, "signal") != 48 or
        @offsetOf(AbortSignalTimeout, "flags") != 56 or
        @offsetOf(AbortSignalTimeout, "generation") != 60)
        @compileError("Bun AbortSignal.Timeout fixture layout drifted");
}

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSEvaluateScript(JSContextRef, JSStringRef, JSObjectRef, JSStringRef, c_int, [*c]JSValueRef) JSValueRef;
extern "c" fn JSValueToBoolean(JSContextRef, JSValueRef) bool;
extern "c" fn WebCore__AbortSignal__fromJS(EncodedValue) ?*AbortSignal;
extern "c" fn WebCore__AbortSignal__aborted(?*AbortSignal) bool;
extern "c" fn WebCore__AbortSignal__signal(?*AbortSignal, JSContextRef, u8) void;
extern "c" fn WebCore__AbortSignal__addListener(
    ?*AbortSignal,
    ?*anyopaque,
    ?*const fn (?*anyopaque, EncodedValue) callconv(.c) void,
) ?*AbortSignal;
extern "c" fn WebCore__AbortSignal__getTimeout(?*AbortSignal) ?*AbortSignalTimeout;
extern "c" fn usleep(c_uint) c_int;

fn fail(message: []const u8) noreturn {
    std.debug.panic("{s}", .{message});
}

fn evaluate(context: JSContextRef, source: [*:0]const u8) JSValueRef {
    const script = JSStringCreateWithUTF8CString(source) orelse fail("script string creation failed");
    defer JSStringRelease(script);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(context, script, null, null, 1, &exception);
    if (exception != null or result == null) fail("script evaluation failed");
    return result;
}

const CallbackState = struct {
    signal: ?*AbortSignal,
    calls: usize = 0,
    saw_invalidated_timeout: bool = false,

    fn run(raw: ?*anyopaque, _: EncodedValue) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse return));
        self.calls += 1;
        self.saw_invalidated_timeout = WebCore__AbortSignal__getTimeout(self.signal) == null;
    }
};

pub fn main() void {
    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);

    // Creation is asynchronous even at zero delay: the expression observes
    // false, and only the evaluation-tail checkpoint may fire the timer.
    if (JSValueToBoolean(context, evaluate(context, "(() => { const signal = AbortSignal.timeout(0); return signal.aborted; })()")))
        fail("zero-delay timeout fired synchronously");

    const early_value = evaluate(context, "globalThis.__bun_timeout_early_330 = AbortSignal.timeout(60000); __bun_timeout_early_330");
    const early = WebCore__AbortSignal__fromJS(EncodedValue.fromRef(early_value)) orelse
        fail("early timeout signal downcast failed");
    const early_timeout = WebCore__AbortSignal__getTimeout(early) orelse fail("missing active timeout handle");
    if (early_timeout.event_loop_timer.state != .active or
        early_timeout.event_loop_timer.tag != .abort_signal_timeout or
        early_timeout.signal != early or early_timeout.flags != 1 << 30 or early_timeout.generation == 0)
        fail("active Bun timeout record mismatch");
    var early_callback = CallbackState{ .signal = early };
    _ = WebCore__AbortSignal__addListener(early, &early_callback, CallbackState.run) orelse
        fail("early timeout listener registration failed");
    WebCore__AbortSignal__signal(early, context, 1);
    if (!WebCore__AbortSignal__aborted(early) or early_callback.calls != 1 or
        !early_callback.saw_invalidated_timeout or WebCore__AbortSignal__getTimeout(early) != null)
        fail("early timeout cancellation ordering mismatch");

    const natural_value = evaluate(context, "globalThis.__bun_timeout_natural_330 = AbortSignal.timeout(1); __bun_timeout_natural_330");
    const natural = WebCore__AbortSignal__fromJS(EncodedValue.fromRef(natural_value)) orelse
        fail("natural timeout signal downcast failed");
    if (WebCore__AbortSignal__getTimeout(natural) == null) fail("natural timeout was not scheduled");
    var natural_callback = CallbackState{ .signal = natural };
    _ = WebCore__AbortSignal__addListener(natural, &natural_callback, CallbackState.run) orelse
        fail("natural timeout listener registration failed");
    _ = usleep(5000);
    _ = evaluate(context, "0");
    if (!WebCore__AbortSignal__aborted(natural) or natural_callback.calls != 1 or
        !natural_callback.saw_invalidated_timeout or WebCore__AbortSignal__getTimeout(natural) != null)
        fail("natural timeout firing mismatch");
}
