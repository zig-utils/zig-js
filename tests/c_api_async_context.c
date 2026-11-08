#include <zig-js/Extensions.h>
#include <stdio.h>
#ifdef __cplusplus
#include <atomic>
#include <chrono>
#include <thread>
#include <pthread.h>
#endif

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "async context fixture failed at %d\n", __LINE__); return 1; } } while (0)

static JSValueRef evaluate(JSContextRef ctx, const char* source, JSValueRef* exception)
{
    JSStringRef text = JSStringCreateWithUTF8CString(source);
    JSValueRef result = JSEvaluateScript(ctx, text, NULL, NULL, 1, exception);
    JSStringRelease(text);
    return result;
}
static int truth(JSContextRef ctx, const char* source)
{
    JSValueRef exception = NULL;
    JSValueRef result = evaluate(ctx, source, &exception);
    if (exception) {
        JSStringRef text = JSValueToStringCopy(ctx, exception, NULL);
        char output[1024];
        JSStringGetUTF8CString(text, output, sizeof(output));
        fprintf(stderr, "async script: %s\n", output);
        JSStringRelease(text);
    }
    return result && !exception && JSValueToBoolean(ctx, result);
}
static JSValueRef get_context(JSContextRef ctx, JSObjectRef function, JSObjectRef this_object,
    size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)function; (void)this_object; (void)count; (void)arguments;
    return ZJSContextGetAsyncContext(ctx, exception);
}
static JSValueRef swap_context(JSContextRef ctx, JSObjectRef function, JSObjectRef this_object,
    size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)function; (void)this_object;
    return ZJSContextSwapAsyncContext(ctx, count ? arguments[0] : NULL, exception);
}
static JSValueRef nested(JSContextRef ctx, JSObjectRef function, JSObjectRef this_object,
    size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)function; (void)this_object;
    if (count != 1) return NULL;
    JSStringRef script = JSValueToStringCopy(ctx, arguments[0], exception);
    if (!script) return NULL;
    JSValueRef value = JSEvaluateScript(ctx, script, NULL, NULL, 1, exception);
    JSStringRelease(script);
    return value;
}
static JSValueRef invalid_swap(JSContextRef ctx, JSObjectRef function, JSObjectRef this_object,
    size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)function; (void)this_object; (void)count; (void)arguments; (void)exception;
    JSValueRef before = ZJSContextGetAsyncContext(ctx, NULL);
    JSValueRef thrown = NULL;
    JSValueRef invalid = ZJSContextSwapAsyncContext(ctx, NULL, &thrown);
    JSValueRef after = ZJSContextGetAsyncContext(ctx, NULL);
    return JSValueMakeBoolean(ctx, before && after && !invalid && thrown
        && JSValueIsStrictEqual(ctx, before, after));
}
static void install(JSContextRef ctx, const char* name, JSObjectCallAsFunctionCallback callback)
{
    JSStringRef key = JSStringCreateWithUTF8CString(name);
    JSObjectRef function = JSObjectMakeFunctionWithCallback(ctx, key, callback);
    JSObjectSetProperty(ctx, JSContextGetGlobalObject(ctx), key, function, 0, NULL);
    JSStringRelease(key);
}
static void install_all(JSContextRef ctx)
{
    install(ctx, "__getContext", get_context);
    install(ctx, "__swapContext", swap_context);
    install(ctx, "__nested", nested);
    install(ctx, "__invalidSwap", invalid_swap);
}

static JSValueRef foreign_realm(JSContextRef ctx, JSObjectRef function, JSObjectRef this_object,
    size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)function; (void)this_object; (void)count; (void)arguments; (void)exception;
    JSValueRef before = ZJSContextGetAsyncContext(ctx, NULL);
    if (!before) return NULL;
    JSValueProtect(ctx, before);
    JSGlobalContextRef other = JSGlobalContextCreateInGroup(JSContextGetGroup(ctx), NULL);
    if (!other) { JSValueUnprotect(ctx, before); return NULL; }
    install_all(other);
    int ok = truth(other, "__getContext()===undefined && __swapContext('other realm')===undefined && __getContext()==='other realm'");
    JSGlobalContextRelease(other);
    JSValueRef after = ZJSContextGetAsyncContext(ctx, NULL);
    ok = ok && after && JSValueIsStrictEqual(ctx, before, after);
    JSValueUnprotect(ctx, before);
    return JSValueMakeBoolean(ctx, ok);
}

#ifdef __cplusplus
static std::atomic<int> arrivals(0);
static JSValueRef barrier(JSContextRef ctx, JSObjectRef function, JSObjectRef this_object,
    size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)function; (void)this_object; (void)count; (void)arguments; (void)exception;
    arrivals.fetch_add(1);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    while (arrivals.load() != 2) {
        if (std::chrono::steady_clock::now() > deadline) return JSValueMakeBoolean(ctx, false);
        std::this_thread::yield();
    }
    return JSValueMakeBoolean(ctx, true);
}
struct WorkerInput { std::atomic<int>* failures; int token; };
static void* owner_thread(void* raw)
{
    WorkerInput* input = static_cast<WorkerInput*>(raw);
        JSGlobalContextRef local = ZJSGlobalContextCreateGarbageCollected(false);
        if (!local) { input->failures->fetch_add(1); arrivals.fetch_add(1); return NULL; }
        install_all(local);
        install(local, "__barrier", barrier);
        char script[512];
        snprintf(script, sizeof(script), "var observed; if(__getContext()!==undefined) throw 'thread leak'; __swapContext(%d); if(!__barrier()) throw 'barrier'; Promise.resolve().then(function(){observed=__getContext();}); true", input->token);
        if (!truth(local, script)) input->failures->fetch_add(1);
        snprintf(script, sizeof(script), "observed===%d && __getContext()===undefined", input->token);
        if (!truth(local, script)) input->failures->fetch_add(1);
        JSGlobalContextRelease(local);
    return NULL;
}
#endif

int main(void)
{
    JSGlobalContextRef ctx = ZJSGlobalContextCreateGarbageCollected(false);
    CHECK(ctx);
    install_all(ctx);
    install(ctx, "__foreignRealm", foreign_realm);
    JSValueRef exception = NULL;
    CHECK(!ZJSContextGetAsyncContext(ctx, &exception) && exception);
    exception = NULL;
    CHECK(!ZJSContextSwapAsyncContext(ctx, JSValueMakeNumber(ctx, 1), &exception) && exception);
    CHECK(truth(ctx,
        "var errors=[]; var seen=[];"
        "function scoped(value, body) { var old=__swapContext(value); try { return body(); } finally { __swapContext(old); } }"
        "function check(ok, label) { if(!ok) throw new Error(label); }"
        "check(__getContext()===undefined,'initial');"
        "var marker={id:7}; check(__swapContext(marker)===undefined,'previous undefined');"
        "check(__getContext()===marker,'identity'); check(__invalidSwap(),'invalid swap must preserve');"
        "check(__nested('__getContext()')===marker,'nested inherit');"
        "__nested('__swapContext(19)'); check(__getContext()===19,'nested write');"
        "__swapContext(marker);"
        "queueMicrotask(function(){seen.push(__getContext().id); __swapContext('must restore');});"
        "check(__foreignRealm(),'separate realm');"
        "var abruptSeen=false; var failedJob=scoped('throwing',function(){return Promise.resolve().then(function(){check(__getContext()==='throwing','abrupt job context');__swapContext('abrupt');throw new Error('expected callback failure');});});"
        "failedJob.catch(function(error){abruptSeen=error.message==='expected callback failure' && __getContext()===marker;});"
        "__swapContext(undefined);"
        "var release; var gate=new Promise(function(resolve){release=resolve;});"
        "scoped({id:41},function(){gate.then(function(){seen.push(__getContext().id);}).catch(function(e){errors.push(String(e));});});"
        "scoped({id:88},function(){(async function(){await gate; seen.push(__getContext().id); await Promise.resolve(); check(__getContext().id===88,'second await');})().catch(function(e){errors.push(String(e));});});"
        "__getContext()===undefined"));
    CHECK(truth(ctx, "abruptSeen && seen.length===1 && seen[0]===7"));

    /* Marker objects are now held only by pending reactions/async continuations. */
    size_t moved_cells = 0, moved_bytes = 0;
    CHECK(ZJSContextCompactGarbage(ctx, &moved_cells, &moved_bytes) == kZJSGCCompactionCompacted);
    CHECK(moved_cells && moved_bytes);
    CHECK(truth(ctx, "release(1); true"));
    CHECK(truth(ctx, "errors.length===0 && seen.join(',')==='7,41,88' && __getContext()===undefined"));
    CHECK(truth(ctx,
        "var laterResolve; var output=[];"
        "scoped('create',function(){var p=new Promise(function(r){laterResolve=r;});"
        "scoped('register',function(){p.then(function(){output.push(__getContext());}).catch(function(e){errors.push(String(e));});});});"
        "scoped('resolve',function(){laterResolve({then:function(done){output.push(__getContext());done(1);}});}); true"));
    CHECK(truth(ctx, "errors.length===0 && output.join(',')==='resolve,register'"));
    CHECK(truth(ctx,
        "var source=Promise.resolve(1);"
        "Object.defineProperty(source,'constructor',{value:{[Symbol.species]:function(executor){return scoped('species',function(){return new Promise(executor);});}}});"
        "scoped('register-species',function(){source.then(function(){output.push(__getContext());}).catch(function(e){errors.push(String(e));});}); true"));
    CHECK(truth(ctx, "errors.length===0 && output.join(',')==='resolve,register,register-species'"));
    JSValueRef reason = NULL, promise = NULL;
    exception = NULL;
    CHECK(!ZJSContextTakeUnhandledRejection(ctx, &reason, &promise, &exception) && !exception);
    JSGlobalContextRelease(ctx);
#ifdef __cplusplus
    std::atomic<int> failures(0);
    WorkerInput first_input = { &failures, 101 }, second_input = { &failures, 202 };
    pthread_attr_t attributes;
    CHECK(pthread_attr_init(&attributes) == 0);
    /* TSan's frames exceed libc++'s small default stack on macOS. Use an explicit
     * 8 MiB owner-thread stack without relaxing the engine stack guard. */
    CHECK(pthread_attr_setstacksize(&attributes, 8 * 1024 * 1024) == 0);
    pthread_t first, second;
    CHECK(pthread_create(&first, &attributes, owner_thread, &first_input) == 0);
    CHECK(pthread_create(&second, &attributes, owner_thread, &second_input) == 0);
    CHECK(pthread_attr_destroy(&attributes) == 0);
    CHECK(pthread_join(first, NULL) == 0 && pthread_join(second, NULL) == 0);
    CHECK(failures.load() == 0);
    puts("OK independent owner-thread execution contexts");
#endif
    puts("OK async context identity, nested scopes, abrupt jobs, await, thenables, species and precise compaction");
    return 0;
}
