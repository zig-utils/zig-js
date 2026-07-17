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
        if (check([JSValue valueWithNewObjectInContext:context].isObject &&
                      [JSValue valueWithNewArrayInContext:context].isArray,
                  20))
            return 20;
        JSValue *regexp = [JSValue valueWithNewRegularExpressionFromPattern:@"a+"
                                                                      flags:@"gi"
                                                                  inContext:context];
        if (check([regexp.toString isEqualToString:@"/a+/gi"], 21))
            return 21;
        JSValue *error = [JSValue valueWithNewErrorFromMessage:@"failure" inContext:context];
        if (check([error.toString containsString:@"failure"], 22))
            return 22;
        if (check([JSValue valueWithNewSymbolFromDescription:@"key" inContext:context].isSymbol, 23))
            return 23;
        if (check([JSValue valueWithNewBigIntFromString:@"9007199254740993" inContext:context].isBigInt &&
                      [JSValue valueWithNewBigIntFromInt64:-42 inContext:context].isBigInt &&
                      [JSValue valueWithNewBigIntFromUInt64:42 inContext:context].isBigInt &&
                      [JSValue valueWithNewBigIntFromDouble:42 inContext:context].isBigInt,
                  24))
            return 24;
        if (check([JSValue valueWithNewBigIntFromDouble:1.5 inContext:context] == nil &&
                      context.exception != nil,
                  25))
            return 25;
        JSValue *three = [JSValue valueWithInt32:3 inContext:context];
        if (check([three compareInt64:4] == kJSRelationConditionLessThan &&
                      [three compareUInt64:3] == kJSRelationConditionEqual &&
                      [three compareDouble:2] == kJSRelationConditionGreaterThan &&
                      [three compareJSValue:[JSValue valueWithDouble:3 inContext:context]] ==
                          kJSRelationConditionEqual,
                  26))
            return 26;
        JSValue *wide = [context evaluateScript:@"4294967297"];
        if (check(wide.toInt32 == 1 && wide.toUInt32 == 1 &&
                      wide.toInt64 == 4294967297LL && wide.toUInt64 == 4294967297ULL &&
                      wide.toNumber.longLongValue == 4294967297LL,
                  27))
            return 27;
        JSValue *properties = [JSValue valueWithNewObjectInContext:context];
        properties[@"answer"] = @42;
        if (check([properties hasProperty:@"answer"] && [properties[@"answer"] toInt32] == 42, 28))
            return 28;
        if (check([properties deleteProperty:@"answer"] && ![properties hasProperty:@"answer"], 29))
            return 29;
        JSValue *indexed = [JSValue valueWithNewArrayInContext:context];
        indexed[0] = @"first";
        if (check([[indexed[0] toString] isEqualToString:@"first"], 30))
            return 30;
        JSValue *function = [context evaluateScript:@"(a, b) => a + b"];
        if (check([[function callWithArguments:@[ @20, @22 ]] toInt32] == 42, 31))
            return 31;
        JSValue *constructor = [context evaluateScript:@"(class Box { constructor(value) { this.value = value; } })"];
        JSValue *box = [constructor constructWithArguments:@[ @42 ]];
        if (check([box[@"value"] toInt32] == 42 && [box isInstanceOf:constructor], 32))
            return 32;
        JSValue *words = [context evaluateScript:@"['zig', 'js']"];
        if (check([[[words invokeMethod:@"join" withArguments:@[ @"-" ]] toString]
                      isEqualToString:@"zig-js"],
                  33))
            return 33;
        if (check([JSPropertyDescriptorWritableKey isEqualToString:@"writable"] &&
                      [JSPropertyDescriptorEnumerableKey isEqualToString:@"enumerable"] &&
                      [JSPropertyDescriptorConfigurableKey isEqualToString:@"configurable"] &&
                      [JSPropertyDescriptorValueKey isEqualToString:@"value"] &&
                      [JSPropertyDescriptorGetKey isEqualToString:@"get"] &&
                      [JSPropertyDescriptorSetKey isEqualToString:@"set"],
                  34))
            return 34;
    }
    return 0;
}
