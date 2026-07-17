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
        CGPoint point = CGPointMake(1.25, -2.5);
        CGPoint pointResult = [JSValue valueWithPoint:point inContext:context].toPoint;
        if (check(pointResult.x == point.x && pointResult.y == point.y, 35))
            return 35;
        NSRange range = NSMakeRange(3, 7);
        if (check(NSEqualRanges([JSValue valueWithRange:range inContext:context].toRange, range), 36))
            return 36;
        CGRect rect = CGRectMake(1, 2, 3, 4);
        CGRect rectResult = [JSValue valueWithRect:rect inContext:context].toRect;
        if (check(rectResult.origin.x == rect.origin.x && rectResult.origin.y == rect.origin.y &&
                      rectResult.size.width == rect.size.width && rectResult.size.height == rect.size.height,
                  37))
            return 37;
        CGSize size = CGSizeMake(8, 9);
        CGSize sizeResult = [JSValue valueWithSize:size inContext:context].toSize;
        if (check(sizeResult.width == size.width && sizeResult.height == size.height, 38))
            return 38;
        NSDictionary *foundation = @{
            @"name" : @"zig-js",
            @"values" : @[ @1, @2, NSNull.null ],
        };
        JSValue *foundationValue = [JSValue valueWithObject:foundation inContext:context];
        NSDictionary *foundationResult = foundationValue.toDictionary;
        if (check([foundationResult[@"name"] isEqualToString:@"zig-js"] &&
                      [foundationResult[@"values"] count] == 3 &&
                      [foundationResult[@"values"][2] isEqual:NSNull.null] &&
                      [foundationValue toObjectOfClass:NSDictionary.class] != nil,
                  39))
            return 39;
        NSMutableArray *cycle = [NSMutableArray array];
        [cycle addObject:cycle];
        JSValue *cycleValue = [JSValue valueWithObject:cycle inContext:context];
        if (check([[cycleValue valueAtIndex:0] isEqualToObject:cycleValue], 40))
            return 40;
        JSValue *descriptorTarget = [JSValue valueWithNewObjectInContext:context];
        [descriptorTarget defineProperty:@"fixed"
                              descriptor:@{
                                  JSPropertyDescriptorValueKey : @7,
                                  JSPropertyDescriptorWritableKey : @NO,
                              }];
        [descriptorTarget setValue:@9 forProperty:@"fixed"];
        if (check([[descriptorTarget valueForProperty:@"fixed"] toInt32] == 7, 41))
            return 41;
        JSValue *cyclicObject = [context evaluateScript:@"(() => { const o = {}; o.self = o; return o; })()"];
        NSMutableDictionary *cyclicResult = (NSMutableDictionary *)cyclicObject.toDictionary;
        if (check(cyclicResult[@"self"] == cyclicResult, 42))
            return 42;
        [cyclicResult removeObjectForKey:@"self"];
        if (check(JSContext.currentContext == nil && JSContext.currentCallee == nil &&
                      JSContext.currentThis == nil && JSContext.currentArguments == nil,
                  43))
            return 43;
        __block BOOL callbackStateMatches = NO;
        __block BOOL nestedStateRestored = NO;
        __block JSValue *outerThis = nil;
        JSValue *callbackPromise = [JSValue valueWithNewPromiseInContext:context
                                                            fromExecutor:^(JSValue *resolve, JSValue *reject) {
                                                                (void)reject;
                                                                outerThis = JSContext.currentThis;
                                                                callbackStateMatches = JSContext.currentContext == context &&
                                                                    JSContext.currentCallee == nil &&
                                                                    JSContext.currentArguments.count == 2;
                                                                [JSValue valueWithNewPromiseInContext:context
                                                                                         fromExecutor:^(JSValue *innerResolve, JSValue *innerReject) {
                                                                                             (void)innerResolve;
                                                                                             (void)innerReject;
                                                                                         }];
                                                                nestedStateRestored = JSContext.currentThis == outerThis;
                                                                [resolve callWithArguments:@[ @42 ]];
                                                            }];
        if (check(callbackStateMatches && nestedStateRestored &&
                      [outerThis isEqualToObject:callbackPromise],
                  44))
            return 44;
        context[@"callbackPromise"] = callbackPromise;
        [context evaluateScript:@"callbackPromise.then(value => { globalThis.callbackResult = value; })"];
        [context evaluateScript:@"0"];
        if (check([context[@"callbackResult"] toInt32] == 42, 45))
            return 45;
        context[@"resolvedPromise"] = [JSValue valueWithNewPromiseResolvedWithResult:@7
                                                                            inContext:context];
        context[@"rejectedPromise"] = [JSValue valueWithNewPromiseRejectedWithReason:@"no"
                                                                             inContext:context];
        [context evaluateScript:@"resolvedPromise.then(value => { globalThis.resolvedResult = value; }); rejectedPromise.catch(value => { globalThis.rejectedResult = value; })"];
        [context evaluateScript:@"0"];
        if (check([context[@"resolvedResult"] toInt32] == 7 &&
                      [[context[@"rejectedResult"] toString] isEqualToString:@"no"],
                  46))
            return 46;
        void (^defaultHandler)(JSContext *, JSValue *) = context.exceptionHandler;
        __block JSValue *handledException = nil;
        context.exception = nil;
        context.exceptionHandler = ^(JSContext *callbackContext, JSValue *exception) {
            if (callbackContext == context)
                handledException = exception;
        };
        [context evaluateScript:@"throw new Error('custom-handler')"];
        context.exceptionHandler = defaultHandler;
        if (check([handledException.toString containsString:@"custom-handler"] &&
                      context.exception == nil,
                  47))
            return 47;
        JSManagedValue *managedPrimitive = [JSManagedValue managedValueWithValue:
                                                               [JSValue valueWithInt32:9 inContext:context]];
        if (check(managedPrimitive.value.toInt32 == 9, 48))
            return 48;
        __block JSManagedValue *unrootedManaged = nil;
        @autoreleasepool {
            JSValue *collectible = [context evaluateScript:@"({ tag: 'unrooted' })"];
            unrootedManaged = [JSManagedValue managedValueWithValue:collectible];
            if (check([unrootedManaged.value[@"tag"].toString isEqualToString:@"unrooted"], 49))
                return 49;
        }
        JSGarbageCollect(context.JSGlobalContextRef);
        if (check([unrootedManaged.value[@"tag"].toString isEqualToString:@"unrooted"], 50))
            return 50;
        NSObject *owner = [NSObject new];
        __block JSManagedValue *ownedManaged = nil;
        @autoreleasepool {
            JSValue *collectible = [context evaluateScript:@"({ tag: 'owned' })"];
            ownedManaged = [JSManagedValue managedValueWithValue:collectible andOwner:owner];
        }
        JSGarbageCollect(context.JSGlobalContextRef);
        if (check([ownedManaged.value[@"tag"].toString isEqualToString:@"owned"], 51))
            return 51;
        [context.virtualMachine removeManagedReference:ownedManaged withOwner:owner];
        JSGarbageCollect(context.JSGlobalContextRef);
        if (check([ownedManaged.value[@"tag"].toString isEqualToString:@"owned"], 52))
            return 52;
        __weak NSObject *weakOwner = nil;
        @autoreleasepool {
            NSObject *temporaryOwner = [NSObject new];
            weakOwner = temporaryOwner;
            JSManagedValue *temporaryManaged = [JSManagedValue managedValueWithValue:
                                                                    [context evaluateScript:@"({ temporary: true })"]
                                                                                   andOwner:temporaryOwner];
            if (check(temporaryManaged.value != nil, 53))
                return 53;
        }
        if (check(weakOwner == nil, 54))
            return 54;
    }
    return 0;
}
