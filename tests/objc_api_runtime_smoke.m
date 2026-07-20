#import <JavaScriptCore/JavaScriptCore.h>
#import <zig-js/Extensions.h>

@interface ZJSTestObject : NSObject
@property (nonatomic, copy) NSString *name;
@end

@implementation ZJSTestObject
@end

static BOOL ZJSTestExportCallbackState = NO;

@protocol ZJSTestExports <JSExport>
@property (nonatomic, copy) NSString *title;
- (instancetype)initWithTitle:(NSString *)title;
- (int32_t)add:(int32_t)left to:(int32_t)right;
JSExportAs(product,
- (int32_t)multiply:(int32_t)left by:(int32_t)right
);
- (CGPoint)offset:(CGPoint)point;
- (NSString *)decorate:(NSString *)value;
- (void)throwNative;
+ (NSString *)classPrefix:(NSString *)value;
@end

@interface ZJSTestExportObject : NSObject <ZJSTestExports>
@property (nonatomic, copy) NSString *title;
- (NSString *)hiddenValue;
@end

@implementation ZJSTestExportObject
- (instancetype)initWithTitle:(NSString *)title
{
    self = [super init];
    if (self)
        _title = [title copy];
    return self;
}
+ (NSString *)classPrefix:(NSString *)value { return [@"class:" stringByAppendingString:value]; }
- (int32_t)add:(int32_t)left to:(int32_t)right
{
    ZJSTestExportCallbackState = JSContext.currentContext != nil &&
        JSContext.currentCallee != nil && JSContext.currentArguments.count == 2 &&
        JSContext.currentThis.toObject == self;
    return left + right;
}
- (int32_t)multiply:(int32_t)left by:(int32_t)right { return left * right; }
- (CGPoint)offset:(CGPoint)point { return CGPointMake(point.x + 2, point.y - 2); }
- (NSString *)decorate:(NSString *)value { return [@"[" stringByAppendingString:[value stringByAppendingString:@"]"]]; }
- (void)throwNative { [NSException raise:NSInvalidArgumentException format:@"export-native-failure"]; }
- (NSString *)hiddenValue { return @"hidden"; }
@end

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
        if (check(unrootedManaged.value == nil, 50))
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
        if (check(ownedManaged.value == nil, 52))
            return 52;
        JSValue *globalTarget = [context evaluateScript:@"({ tag: 'global' })"];
        JSManagedValue *globalManaged = [JSManagedValue managedValueWithValue:globalTarget];
        context[@"managedRoot"] = globalTarget;
        JSGarbageCollect(context.JSGlobalContextRef);
        if (check([globalManaged.value[@"tag"].toString isEqualToString:@"global"], 83))
            return 83;
        context[@"managedRoot"] = nil;
        JSGarbageCollect(context.JSGlobalContextRef);
        if (check(globalManaged.value == nil, 84))
            return 84;
        [context evaluateScript:@"globalThis.readManaged = (() => { const target = { tag: 'closure' }; return () => target; })()"];
        JSManagedValue *closureManaged = [JSManagedValue managedValueWithValue:
            [context evaluateScript:@"readManaged()"]];
        JSGarbageCollect(context.JSGlobalContextRef);
        if (check([closureManaged.value[@"tag"].toString isEqualToString:@"closure"], 85))
            return 85;
        context[@"readManaged"] = nil;
        JSGarbageCollect(context.JSGlobalContextRef);
        if (check(closureManaged.value == nil, 86))
            return 86;
        __weak NSObject *weakOwner = nil;
        __block JSManagedValue *ownerDeathManaged = nil;
        @autoreleasepool {
            NSObject *temporaryOwner = [NSObject new];
            weakOwner = temporaryOwner;
            ownerDeathManaged = [JSManagedValue managedValueWithValue:
                                              [context evaluateScript:@"({ temporary: true })"]
                                                             andOwner:temporaryOwner];
            if (check(ownerDeathManaged.value != nil, 53))
                return 53;
        }
        if (check(weakOwner == nil, 54))
            return 54;
        JSGarbageCollect(context.JSGlobalContextRef);
        if (check(ownerDeathManaged.value == nil, 87))
            return 87;
        ZJSTestObject *nativeObject = [ZJSTestObject new];
        nativeObject.name = @"native";
        JSValue *nativeWrapper = [JSValue valueWithObject:nativeObject inContext:context];
        if (check(nativeWrapper == [JSValue valueWithObject:nativeObject inContext:context] &&
                      nativeWrapper.toObject == nativeObject,
                  55))
            return 55;
        JSValue *identityHolder = [context evaluateScript:@"(() => { const child = {}; return { child }; })()"];
        if (check([identityHolder valueForProperty:@"child"] ==
                      [identityHolder valueForProperty:@"child"],
                  56))
            return 56;
        context[@"nativeA"] = nativeWrapper;
        context[@"nativeB"] = nativeObject;
        if (check([[context evaluateScript:@"nativeA === nativeB"] toBool], 57))
            return 57;
        __weak JSVirtualMachine *releasedVirtualMachine = nil;
        __weak JSContext *releasedContext = nil;
        __weak NSObject *releasedNativeObject = nil;
        @autoreleasepool {
            JSVirtualMachine *temporaryVirtualMachine = [JSVirtualMachine new];
            JSContext *temporaryContext = [[JSContext alloc]
                initWithVirtualMachine:temporaryVirtualMachine];
            NSObject *temporaryObject = [NSObject new];
            releasedVirtualMachine = temporaryVirtualMachine;
            releasedContext = temporaryContext;
            releasedNativeObject = temporaryObject;
            [JSValue valueWithObject:temporaryObject inContext:temporaryContext];
        }
        if (check(releasedVirtualMachine == nil && releasedContext == nil &&
                      releasedNativeObject == nil,
                  58))
            return 58;
        JSContext *foreignContext = [JSContext new];
        BOOL crossVMValueRejected = NO;
        @try {
            [JSValue valueWithObject:nativeWrapper inContext:foreignContext];
        } @catch (NSException *exception) {
            crossVMValueRejected = [exception.name isEqualToString:NSInvalidArgumentException];
        }
        BOOL crossVMManagedRejected = NO;
        @try {
            [foreignContext.virtualMachine addManagedReference:managedPrimitive
                                                     withOwner:owner];
        } @catch (NSException *exception) {
            crossVMManagedRejected = [exception.name isEqualToString:NSInvalidArgumentException];
        }
        if (check(crossVMValueRejected && crossVMManagedRejected, 59))
            return 59;
        JSContext *siblingContext = [[JSContext alloc]
            initWithVirtualMachine:context.virtualMachine];
        JSValue *siblingNativeWrapper = [JSValue valueWithObject:nativeObject
                                                       inContext:siblingContext];
        JSValue *sharedObject = [context evaluateScript:@"({ marker: 42 })"];
        siblingContext[@"sharedObject"] = sharedObject;
        JSValue *rewrappedObject = [JSValue valueWithObject:sharedObject
                                                  inContext:siblingContext];
        if (check(siblingNativeWrapper.toObject == nativeObject &&
                      [siblingContext[@"sharedObject"][@"marker"] toInt32] == 42 &&
                      rewrappedObject != sharedObject &&
                      rewrappedObject.context == siblingContext &&
                      [rewrappedObject isEqualToObject:sharedObject],
                  81))
            return 81;
        __block BOOL blockStateMatches = NO;
        int32_t (^adder)(int32_t, int32_t) = ^int32_t(int32_t left, int32_t right) {
            blockStateMatches = JSContext.currentContext == context &&
                JSContext.currentCallee != nil &&
                JSContext.currentArguments.count == 2 &&
                [JSContext.currentThis[@"marker"] toInt32] == 7;
            return left + right;
        };
        JSValue *adderValue = [JSValue valueWithObject:adder inContext:context];
        context[@"nativeAdder"] = adderValue;
        JSValue *adderResult = [context evaluateScript:@"nativeAdder.call({ marker: 7 }, 20, 22)"];
        if (check(adderResult.toInt32 == 42, 60))
            return 60;
        if (check(blockStateMatches, 66))
            return 66;
        if (check(adderValue.toObject == adder, 67))
            return 67;
        NSString *(^decorate)(NSString *) = ^NSString *(NSString *value) {
            return [@"<" stringByAppendingString:[value stringByAppendingString:@">"]];
        };
        if (check([[[JSValue valueWithObject:decorate inContext:context]
                       callWithArguments:@[ @"zig-js" ]]
                      .toString isEqualToString:@"<zig-js>"],
                  61))
            return 61;
        CGPoint (^offsetPoint)(CGPoint) = ^CGPoint(CGPoint point) {
            return CGPointMake(point.x + 1, point.y - 1);
        };
        CGPoint offsetResult = [[JSValue valueWithObject:offsetPoint inContext:context]
            callWithArguments:@[ [JSValue valueWithPoint:CGPointMake(2, 4) inContext:context] ]]
                                    .toPoint;
        if (check(offsetResult.x == 3 && offsetResult.y == 3, 62))
            return 62;
        __block BOOL voidBlockCalled = NO;
        void (^consume)(BOOL, double) = ^(BOOL flag, double number) {
            voidBlockCalled = flag && number == 4.5;
        };
        JSValue *voidResult = [[JSValue valueWithObject:consume inContext:context]
            callWithArguments:@[ @YES, @4.5 ]];
        if (check(voidBlockCalled && voidResult.isUndefined, 63))
            return 63;
        id (^throwingBlock)(void) = ^id {
            [NSException raise:NSInvalidArgumentException format:@"native-block-failure"];
            return nil;
        };
        context[@"throwingBlock"] = throwingBlock;
        JSValue *nativeFailure = [context evaluateScript:@"try { throwingBlock(); 'missed'; } catch (error) { String(error); }"];
        if (check([nativeFailure.toString containsString:@"native-block-failure"], 64))
            return 64;
        context.exception = nil;
        void (^exceptionBlock)(void) = ^{
            context.exception = [JSValue valueWithNewErrorFromMessage:@"context-block-failure"
                                                             inContext:context];
        };
        context[@"exceptionBlock"] = exceptionBlock;
        JSValue *contextFailure = [context evaluateScript:@"try { exceptionBlock(); 'missed'; } catch (error) { String(error); }"];
        if (check([contextFailure.toString containsString:@"context-block-failure"], 65))
            return 65;
        ZJSTestExportObject *exportObject = [ZJSTestExportObject new];
        exportObject.title = @"before";
        context[@"exported"] = exportObject;
        if (check([context evaluateScript:@"exported.title"].toString.length == 6, 68))
            return 68;
        [context evaluateScript:@"exported.title = 'after'"];
        if (check([exportObject.title isEqualToString:@"after"], 69))
            return 69;
        if (check([[context evaluateScript:@"exported.addTo(20, 22)"] toInt32] == 42 &&
                      ZJSTestExportCallbackState,
                  70))
            return 70;
        JSValue *exportedWrapper = context[@"exported"];
        if (check([exportedWrapper valueForProperty:@"addTo"] ==
                      [exportedWrapper valueForProperty:@"addTo"] &&
                      [[context evaluateScript:@"exported.decorate('zig-js')"] toString].length == 8,
                  71))
            return 71;
        JSValue *exportedPoint = [context evaluateScript:@"exported.offset({ x: 3, y: 5 })"];
        if (check(exportedPoint.toPoint.x == 5 && exportedPoint.toPoint.y == 3, 72))
            return 72;
        if (check([[[context evaluateScript:@"typeof exported.hiddenValue"] toString]
                      isEqualToString:@"undefined"],
                  73))
            return 73;
        JSValue *exportFailure = [context evaluateScript:@"try { exported.throwNative(); 'missed'; } catch (error) { String(error); }"];
        if (check([exportFailure.toString containsString:@"export-native-failure"], 74))
            return 74;
        if (check([[context evaluateScript:@"exported.product(6, 7)"] toInt32] == 42 &&
                      [[[context evaluateScript:@"typeof exported.multiplyBy"] toString]
                          isEqualToString:@"undefined"],
                  80))
            return 80;
        context[@"ExportClass"] = ZJSTestExportObject.class;
        if (check([[[context evaluateScript:@"ExportClass.classPrefix('zig-js')"] toString]
                      isEqualToString:@"class:zig-js"],
                  75))
            return 75;
        JSValue *constructedWrapper = [context evaluateScript:@"new ExportClass('made')"];
        ZJSTestExportObject *constructedObject = constructedWrapper.toObject;
        if (check([constructedObject.title isEqualToString:@"made"], 76))
            return 76;
        if (check([[context evaluateScript:@"Object.getPrototypeOf(new ExportClass('probe')) === ExportClass.prototype"] toBool], 78))
            return 78;
        context[@"constructed"] = constructedWrapper;
        if (check([[context evaluateScript:@"constructed instanceof ExportClass"] toBool], 79))
            return 79;
        if (check([constructedWrapper isInstanceOf:context[@"ExportClass"]], 77))
            return 77;
        ZJSTestExportObject *sharedExport = [[ZJSTestExportObject alloc]
            initWithTitle:@"shared"];
        context[@"sharedExport"] = sharedExport;
        siblingContext[@"sharedExport"] = sharedExport;
        siblingContext[@"ExportClass"] = ZJSTestExportObject.class;
        JSValue *siblingConstructed = [siblingContext evaluateScript:@"new ExportClass('sibling')"];
        if (check(context[@"sharedExport"] != siblingContext[@"sharedExport"] &&
                      context[@"sharedExport"].toObject == sharedExport &&
                      siblingContext[@"sharedExport"].toObject == sharedExport &&
                      [siblingContext evaluateScript:@"sharedExport.addTo(20, 22)"].toInt32 == 42 &&
                      [siblingContext evaluateScript:@"new ExportClass('probe') instanceof ExportClass"].toBool &&
                      [siblingConstructed isInstanceOf:siblingContext[@"ExportClass"]],
                  82))
            return 82;

        JSGlobalContextRef movingContextRef = ZJSGlobalContextCreateGarbageCollected(true);
        JSContext *movingContext = [JSContext contextWithJSGlobalContextRef:movingContextRef];
        JSGlobalContextRelease(movingContextRef);
        movingContextRef = movingContext.JSGlobalContextRef;
        JSVirtualMachine *movingVM = movingContext.virtualMachine;
        if (check(movingContext != nil && movingVM != nil, 88))
            return 88;
        NSObject *movingOwner = [NSObject new];
        __block JSManagedValue *movingManaged = nil;
        @autoreleasepool {
            [movingContext evaluateScript:
                               @"globalThis.__movingDiscard = []; "
                                @"for (let i = 0; i < 4096; i++) "
                                @"  __movingDiscard.push({ dead: i, child: { value: i + 1 } });"];
            JSValue *target = [movingContext evaluateScript:@"({ tag: 'moving-managed' })"];
            movingManaged = [JSManagedValue managedValueWithValue:target andOwner:movingOwner];
            [movingContext evaluateScript:@"__movingDiscard = null;"];
        }
        @autoreleasepool {
            JSValue *beforeMove = movingManaged.value;
            JSValueRef stableHandle = beforeMove.JSValueRef;
            size_t movedCells = 0;
            size_t movedBytes = 0;
            if (check(ZJSContextRequestGarbageCompaction(movingContextRef) &&
                          ZJSContextCompactGarbage(movingContextRef, &movedCells, &movedBytes) ==
                              kZJSGCCompactionCompacted &&
                          movedCells > 0 && movedBytes > 0 &&
                          movingManaged.value == beforeMove &&
                          movingManaged.value.JSValueRef == stableHandle &&
                          [movingManaged.value[@"tag"].toString isEqualToString:@"moving-managed"],
                      89))
                return 89;
        }
        [movingVM removeManagedReference:movingManaged withOwner:movingOwner];
        ZJSGCCompactionStatus finalStatus =
            ZJSContextCompactGarbage(movingContextRef, NULL, NULL);
        if (check((finalStatus == kZJSGCCompactionCompacted ||
                   finalStatus == kZJSGCCompactionNoCandidates) &&
                      movingManaged.value == nil,
                  90))
            return 90;
    }
    return 0;
}
