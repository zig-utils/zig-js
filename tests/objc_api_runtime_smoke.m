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

        JSContext *defaultContext = [JSContext new];
        if (check(defaultContext && defaultContext.virtualMachine && defaultContext.globalObject.isObject, 12))
            return 12;
        if (check([JSValue valueWithUndefinedInContext:context].isUndefined, 13))
            return 13;
        if (check([JSValue valueWithNullInContext:context].isNull, 14))
            return 14;
        JSValue *boolean = [JSValue valueWithBool:YES inContext:context];
        if (check(boolean.isBoolean && boolean.toBool && boolean.context == context, 15))
            return 15;
        if (check([JSValue valueWithDouble:1.5 inContext:context].isNumber, 16))
            return 16;
        if (check([JSValue valueWithInt32:-7 inContext:context].isNumber, 17))
            return 17;
        if (check([JSValue valueWithUInt32:7 inContext:context].isNumber, 18))
            return 18;
        if (check([[context evaluateScript:@"'s'"] isString] &&
                      [[context evaluateScript:@"[]"] isArray] &&
                      [[context evaluateScript:@"new Date(0)"] isDate] &&
                      [[context evaluateScript:@"Symbol('s')"] isSymbol] &&
                      [[context evaluateScript:@"1n"] isBigInt],
                  19))
            return 19;
    }
    return 0;
}
