#include <zig-js/Extensions.h>
#include <stdio.h>

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "value brand fixture failed at line %d\n", __LINE__); return 1; } } while (0)

static JSValueRef eval(JSContextRef ctx, const char* source)
{
    JSStringRef script = JSStringCreateWithUTF8CString(source);
    JSValueRef exception = NULL;
    JSValueRef result = JSEvaluateScript(ctx, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);
    return exception ? NULL : result;
}

static int inspect(JSContextRef ctx, const char* source, bool promise, bool proxy)
{
    JSValueRef value = eval(ctx, source);
    if (!value) return 0;
    JSValueProtect(ctx, value);
    bool matches = ZJSValueIsPromise(ctx, value) == promise &&
        ZJSValueIsProxy(ctx, value) == proxy;
    JSValueUnprotect(ctx, value);
    return matches;
}

int main(void)
{
    JSContextGroupRef group = JSContextGroupCreate();
    JSGlobalContextRef ctx = JSGlobalContextCreateInGroup(group, NULL);
    JSGlobalContextRef sibling = JSGlobalContextCreateInGroup(group, NULL);
    JSGlobalContextRef foreign = JSGlobalContextCreate(NULL);
    CHECK(group && ctx && sibling && foreign);
    CHECK(!ZJSValueIsPromise(NULL, NULL) && !ZJSValueIsProxy(NULL, NULL));
    CHECK(!ZJSValueIsPromise(ctx, NULL) && !ZJSValueIsProxy(ctx, NULL));
    CHECK(eval(ctx,
        "globalThis.touched = 0;"
        "globalThis.handler = new Proxy({}, { get() { touched++; throw 'trap'; } });"
        "globalThis.live = new Proxy({}, handler);"
        "globalThis.callable = new Proxy(function() {}, handler);"
        "globalThis.revoked = Proxy.revocable({}, handler); revoked.revoke();"
        "globalThis.real = Promise.resolve(42);"
        "globalThis.proxied = new Proxy(real, handler);"
        "globalThis.fake = Object.create(Promise.prototype);"
        "Object.defineProperty(fake, 'then', { get() { touched++; throw 'then'; } });"
        "Object.defineProperty(fake, Symbol.toStringTag, { get() { touched++; throw 'tag'; } });"
        "globalThis.thenable = { get then() { touched++; throw 'thenable'; } };") != NULL);
    const char* ordinary[] = { "undefined", "null", "true", "1", "'x'", "1n", "Symbol('x')", "({})", "[]", "(function() {})", "Promise.prototype", "fake", "thenable" };
    for (size_t i = 0; i < sizeof(ordinary) / sizeof(ordinary[0]); ++i)
        CHECK(inspect(ctx, ordinary[i], false, false));
    CHECK(inspect(ctx, "real", true, false));
    CHECK(inspect(ctx, "new Promise(function() {})", true, false));
    CHECK(inspect(ctx, "(async function() { return 1; })()", true, false));
    CHECK(inspect(ctx, "new (class extends Promise {})(function(resolve) { resolve(1); })", true, false));
    CHECK(inspect(ctx, "live", false, true));
    CHECK(inspect(ctx, "callable", false, true));
    CHECK(inspect(ctx, "revoked.proxy", false, true));
    CHECK(inspect(ctx, "proxied", false, true));
    CHECK(JSValueToNumber(ctx, eval(ctx, "touched"), NULL) == 0);

    JSValueRef other_promise = eval(sibling, "Promise.resolve('sibling')");
    JSValueRef other_proxy = eval(sibling, "Proxy.revocable({}, {}).proxy");
    CHECK(other_promise && other_proxy);
    JSValueProtect(sibling, other_promise);
    JSValueProtect(sibling, other_proxy);
    CHECK(ZJSValueIsPromise(ctx, other_promise) && ZJSValueIsProxy(ctx, other_proxy));
    CHECK(!ZJSValueIsPromise(foreign, other_promise) && !ZJSValueIsProxy(foreign, other_proxy));
    JSValueUnprotect(sibling, other_proxy);
    JSValueUnprotect(sibling, other_promise);

    JSValueRef reason = NULL, rejected = NULL, exception = NULL;
    CHECK(!ZJSContextTakeUnhandledRejection(ctx, &reason, &rejected, &exception));
    JSValueRef failure = eval(ctx, "globalThis.failure = Promise.reject('still unhandled'); failure");
    CHECK(failure && ZJSValueIsPromise(ctx, failure) && !ZJSValueIsProxy(ctx, failure));
    CHECK(ZJSContextTakeUnhandledRejection(ctx, &reason, &rejected, &exception));
    CHECK(!exception && JSValueIsStrictEqual(ctx, rejected, failure));
    CHECK(JSValueIsStrictEqual(ctx, reason, eval(ctx, "'still unhandled'")));
    CHECK(!ZJSContextTakeUnhandledRejection(ctx, &reason, &rejected, &exception));
    CHECK(eval(ctx, "failure.catch(function() {});") != NULL);
    JSGlobalContextRelease(foreign);
    JSGlobalContextRelease(sibling);
    JSGlobalContextRelease(ctx);
    JSContextGroupRelease(group);

    ctx = ZJSGlobalContextCreateGarbageCollected(false);
    CHECK(ctx);
    JSValueRef promise = eval(ctx, "Promise.resolve(73)");
    JSValueProtect(ctx, promise);
    JSValueRef proxy = eval(ctx, "var pair = Proxy.revocable({}, {}); pair.revoke(); pair.proxy");
    JSValueProtect(ctx, proxy);
    CHECK(ZJSValueIsPromise(ctx, promise) && ZJSValueIsProxy(ctx, proxy));
    /* Host private storage must not erase the original native Promise slot. */
    int host_data = 42;
    CHECK(JSObjectSetPrivate(JSValueToObject(ctx, promise, NULL), &host_data));
    CHECK(ZJSValueIsPromise(ctx, promise));
    CHECK(eval(ctx, "delete globalThis.pair;") != NULL);
    JSGarbageCollect(ctx);
    CHECK(ZJSValueIsPromise(ctx, promise) && ZJSValueIsProxy(ctx, proxy));
    JSValueUnprotect(ctx, proxy);
    JSValueUnprotect(ctx, promise);
    JSGlobalContextRelease(ctx);
    puts("OK native value brands, zero traps, realm ownership, unhandled rejection and protected GC lifetime");
    return 0;
}
