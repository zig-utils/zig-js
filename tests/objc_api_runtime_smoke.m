#import <JavaScriptCore/JavaScriptCore.h>

static int check(BOOL condition, int code)
{
    return condition ? 0 : code;
}

int main(void)
{
    @autoreleasepool {
        JSVirtualMachine *virtualMachine = [JSVirtualMachine new];
        JSContext *context = [[JSContext alloc] initWithVirtualMachine:virtualMachine];
        if (!virtualMachine || !context)
            return 1;
        if (check(context.virtualMachine == virtualMachine, 2))
            return 2;
        context.name = @"zig-js Objective-C smoke";
        if (check([context.name isEqualToString:@"zig-js Objective-C smoke"], 3))
            return 3;
        context.inspectable = YES;
        if (check(context.isInspectable, 4))
            return 4;
        JSValue *sum = [context evaluateScript:@"20 + 22" withSourceURL:[NSURL URLWithString:@"objc-smoke.js"]];
        if (check(sum.isNumber && sum.toDouble == 42, 5))
            return 5;
        context[@"base"] = @40;
        if (check([context[@"base"] toInt32] == 40, 6))
            return 6;
        if (check([[context evaluateScript:@"base + 2"] toInt32] == 42, 7))
            return 7;
        if (check([JSContext contextWithJSGlobalContextRef:context.JSGlobalContextRef] == context, 8))
            return 8;
        if (check([JSValue valueWithJSValueRef:sum.JSValueRef inContext:context] == sum, 9))
            return 9;
        if (check([[JSValue valueWithObject:@"hello" inContext:context].toString isEqualToString:@"hello"], 10))
            return 10;
        if (check([context evaluateScript:@"throw new Error('bridge-smoke')"] == nil &&
                      [context.exception.toString containsString:@"bridge-smoke"],
                  11))
            return 11;
    }
    return 0;
}
