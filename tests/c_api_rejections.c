#include <zig-js/Extensions.h>
#include <stdio.h>

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "rejections fixture failed at line %d\n", __LINE__); return 1; } } while (0)

static JSValueRef eval(JSContextRef ctx, const char* source)
{
    JSStringRef script = JSStringCreateWithUTF8CString(source);
    JSValueRef exception = NULL;
    JSValueRef result = JSEvaluateScript(ctx, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);
    return exception ? NULL : result;
}

static JSValueRef property(JSContextRef ctx, JSObjectRef object, const char* name)
{
    JSStringRef key = JSStringCreateWithUTF8CString(name);
    JSValueRef value = JSObjectGetProperty(ctx, object, key, NULL);
    JSStringRelease(key);
    return value;
}

int main(void)
{
    JSContextGroupRef group = JSContextGroupCreate();
    JSGlobalContextRef ctx = JSGlobalContextCreateInGroup(group, NULL);
    JSGlobalContextRef sibling = JSGlobalContextCreateInGroup(group, NULL);
    CHECK(group && ctx && sibling);
    JSValueRef reason = NULL, rejected = NULL, exception = NULL;
    CHECK(!ZJSContextTakeUnhandledRejection(ctx, &reason, &rejected, &exception));
    CHECK(!reason && !rejected && !exception);
    CHECK(eval(ctx,
        "globalThis.first = Promise.reject({ marker: 42 });"
        "globalThis.second = Promise.reject(undefined);"
        "globalThis.handled = Promise.reject('handled'); handled.catch(function() {});"
        "globalThis.third = Promise.resolve().then(function() { throw 'last'; });") != NULL);

    /* Invalid outputs must not consume the queued notification. */
    CHECK(!ZJSContextTakeUnhandledRejection(ctx, NULL, &rejected, &exception));
    CHECK(exception != NULL);
    exception = NULL;
    CHECK(!ZJSContextTakeUnhandledRejection(ctx, &reason, &reason, &exception));
    CHECK(exception != NULL);
    exception = NULL;
    /* The queue belongs to the realm, even when realms share a group. */
    CHECK(!ZJSContextTakeUnhandledRejection(sibling, &reason, &rejected, &exception));
    CHECK(!reason && !rejected && !exception);

    CHECK(ZJSContextTakeUnhandledRejection(ctx, &reason, &rejected, &exception));
    CHECK(reason && rejected && !exception);
    CHECK(JSValueIsStrictEqual(ctx, rejected, eval(ctx, "first")));
    JSValueProtect(ctx, reason);
    JSValueProtect(ctx, rejected);
    CHECK(eval(ctx, "delete globalThis.first;") != NULL);
    JSGarbageCollect(ctx);
    CHECK(JSValueToNumber(ctx, property(ctx, JSValueToObject(ctx, reason, NULL), "marker"), NULL) == 42);
    CHECK(JSValueIsObject(ctx, rejected));
    JSValueUnprotect(ctx, rejected);
    JSValueUnprotect(ctx, reason);

    CHECK(ZJSContextTakeUnhandledRejection(ctx, &reason, &rejected, &exception));
    CHECK(reason && JSValueIsUndefined(ctx, reason) && !exception);
    CHECK(JSValueIsStrictEqual(ctx, rejected, eval(ctx, "second")));
    CHECK(ZJSContextTakeUnhandledRejection(ctx, &reason, &rejected, &exception));
    CHECK(JSValueIsStrictEqual(ctx, reason, eval(ctx, "'last'")));
    CHECK(JSValueIsStrictEqual(ctx, rejected, eval(ctx, "third")));
    CHECK(!ZJSContextTakeUnhandledRejection(ctx, &reason, &rejected, &exception));
    CHECK(!reason && !rejected && !exception);
    CHECK(!ZJSContextTakeUnhandledRejection(NULL, &reason, &rejected, &exception));
    CHECK(!reason && !rejected && !exception);

    JSGlobalContextRelease(sibling);
    JSGlobalContextRelease(ctx);
    JSContextGroupRelease(group);
    /* Exercise physical collection as well as an arena-backed group's epoch. */
    ctx = ZJSGlobalContextCreateGarbageCollected(false);
    CHECK(ctx != NULL);
    CHECK(eval(ctx, "Promise.reject({ marker: 73 });") != NULL);
    CHECK(ZJSContextTakeUnhandledRejection(ctx, &reason, &rejected, &exception));
    CHECK(reason && rejected && !exception);
    JSValueProtect(ctx, reason);
    JSValueProtect(ctx, rejected);
    JSGarbageCollect(ctx);
    CHECK(JSValueIsObject(ctx, rejected));
    CHECK(JSValueToNumber(ctx, property(ctx, JSValueToObject(ctx, reason, NULL), "marker"), NULL) == 73);
    CHECK(ZJSValueIsReachable(ctx, reason));
    JSValueUnprotect(ctx, rejected);
    JSValueUnprotect(ctx, reason);
    JSGlobalContextRelease(ctx);
    puts("OK rejection FIFO, identity, handled filtering, undefined, realm isolation and precise GC lifetime");
    return 0;
}
