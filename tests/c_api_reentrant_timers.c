#include "c_api_reentrant_support.h"
#include <time.h>

static JSValueRef delayed_script(JSContextRef context, JSObjectRef function,
    JSObjectRef receiver, size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    clock_t start = clock();
    if (start == (clock_t)-1) return NULL;
    while ((double)(clock() - start) / CLOCKS_PER_SEC < 0.01) {}
    return host_script(context, function, receiver, count, arguments, exception);
}

int main(void)
{
    JSGlobalContextRef context = JSGlobalContextCreate(NULL);
    if (!context || !install_script(context, "delayedScript", delayed_script)) return 1;
    unsigned passed = expect_script(context,
        "var trace=[];setTimeout(()=>trace.push('timer'),1);delayedScript(\"trace.push('inner')\");trace.push('after');trace.join(',')",
        "inner,after");
    passed += expect_script(context, "trace.join(',')", "inner,after,timer");
    JSGlobalContextRelease(context);
    printf("reentrant Script timer boundary: %u/2 checks passed\n", passed);
    return passed == 2 ? 0 : 1;
}
