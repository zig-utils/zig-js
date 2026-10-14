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
print("PASS owned Swift context, block callback, Promise checkpoint, function call")
