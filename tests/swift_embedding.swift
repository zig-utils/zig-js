import Foundation
import ZigJS

let context = ZigJSContext()!
var delivered: [String] = []
let callback: @convention(block) (String) -> Void = { delivered.append($0) }
context.setObject(callback, forKeyedSubscript: "deliver" as NSString)
context.evaluateScript("Promise.resolve(40).then(value => deliver(String(value + 2))); globalThis.answer = 7;")
ZJSContextRunMicrotasks(context)
precondition(delivered == ["42"], "Promise jobs must reach the native callback")
precondition(context.objectForKeyedSubscript("answer")?.toInt32() == 7)
let value = context.evaluateScript("(function(a, b) { return a + b; })")!
precondition(value.call(withArguments: [20, 22])?.toInt32() == 42)
precondition(NSStringFromClass(type(of: context)) == "ZigJSContext")

// A precise-GC context, as a long-lived host wants one: the arena default frees
// nothing until the context goes. Native blocks and values survive collection,
// and garbage does not keep the heap growing.
let created = ZJSGlobalContextCreateGarbageCollected(true)!
let collected = ZigJSContext(jsGlobalContextRef: created)!
JSGlobalContextRelease(created)
var heard: [String] = []
let hear: @convention(block) (String) -> Void = { heard.append($0) }
collected.setObject(hear, forKeyedSubscript: "hear" as NSString)
let kept = collected.evaluateScript("globalThis.kept = { label: 'kept' }; const head = ['x', 'y']; [...head, " + (0..<120).map { "'k\($0)'" }.joined(separator: ",") + "]")!
for _ in 0..<20 {
    collected.evaluateScript("for (let i = 0; i < 2000; i++) { const garbage = { i, text: 'g' + i, list: [i, i + 1] } }")
    JSGarbageCollect(collected.jsGlobalContextRef)
}
let epoch = ZJSContextGetCollectionEpoch(collected.jsGlobalContextRef)
precondition(epoch >= 20, "Explicit collections must reach the context")
precondition(kept.objectAtIndexedSubscript(121)?.toString() == "k119", "An array a native host holds must survive collection")
collected.evaluateScript("Promise.resolve(kept.label).then(hear)")
ZJSContextRunMicrotasks(collected)
precondition(heard == ["kept"], "A native block must survive collection")
print("PASS owned Swift context, block callback, Promise checkpoint, function call, precise-GC context")
