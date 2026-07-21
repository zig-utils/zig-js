#include <JavaScriptCore/JavaScript.h>

#include <cstdio>

// These definitions stand in for the pinned Bun/Home host objects. Their
// signatures are deliberately opaque here: the generated contract pins the
// exact declarations and provider sources, while this final-link witness proves
// zig-js does not publish a colliding definition from its monolithic archive.
extern "C" {
void BakeCreateProdGlobal() { }
void Bake__getAsyncLocalStorage() { }
void Bun__EventLoopTaskNoContext__createdInBunVm() { }
void Bun__EventLoopTaskNoContext__performTask() { }
void Bun__SecretsJobOptions__deinit() { }
void Bun__SecretsJobOptions__runFromJS() { }
void Bun__SecretsJobOptions__runTask() { }
void Bun__WebView__closeAllForTermination() { }
void Bun__closeAllSQLiteDatabasesForTermination() { }
void Bun__createJSDebugger() { }
void Bun__ensureDebugger() { }
void Bun__loadHTMLEntryPoint() { }
void Bun__onFulfillAsyncModule() { }
void Bun__runDeferredWork() { }
void Bun__runOnLoadPlugins() { }
void Bun__runOnResolvePlugins() { }
void Bun__startJSDebuggerThread() { }
void NodeModuleModule__callOverriddenRunMain() { }
void WebWorker__dispatchError() { }
void WebWorker__dispatchExit() { }
void WebWorker__dispatchOnline() { }
void WebWorker__fireEarlyMessages() { }
void WebWorker__teardownJSCVM() { }
void ZigGlobalObject__makeNapiEnvForFFI() { }
}

int main()
{
    JSGlobalContextRef context = JSGlobalContextCreate(nullptr);
    if (!context)
        return 1;
    JSGlobalContextRelease(context);
    std::fputs("Private ABI consumer providers: 24/24 host symbols linked without zig-js collisions\n", stderr);
    return 0;
}
