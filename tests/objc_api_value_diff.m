#import <JavaScriptCore/JavaScriptCore.h>
#include <stdio.h>

static BOOL ZJSDiffExportCallbackState = NO;

@protocol ZJSDiffExports <JSExport>
@property (nonatomic, copy) NSString *title;
- (instancetype)initWithTitle:(NSString *)title;
- (int32_t)add:(int32_t)left to:(int32_t)right;
JSExportAs(product,
- (int32_t)multiply:(int32_t)left by:(int32_t)right
);
+ (NSString *)classPrefix:(NSString *)value;
@end

@interface ZJSDiffExportObject : NSObject <ZJSDiffExports>
@property (nonatomic, copy) NSString *title;
- (NSString *)hiddenValue;
@end

@implementation ZJSDiffExportObject
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
    ZJSDiffExportCallbackState = JSContext.currentContext != nil &&
        JSContext.currentCallee != nil && JSContext.currentArguments.count == 2 &&
        JSContext.currentThis.toObject == self;
    return left + right;
}
- (int32_t)multiply:(int32_t)left by:(int32_t)right { return left * right; }
- (NSString *)hiddenValue { return @"hidden"; }
@end

static void row(NSString *name, NSString *value)
{
    printf("%s=%s\n", name.UTF8String, value.UTF8String);
}

int main(void)
{
    @autoreleasepool {
        JSContext *context = [JSContext new];

        JSValue *nullValue = [JSValue valueWithObject:NSNull.null inContext:context];
        row(@"null", [NSString stringWithFormat:@"%d:%d", nullValue.isNull,
                                                 [nullValue.toObject isEqual:NSNull.null]]);

        NSArray *array = @[ @"zig", @42, @YES, NSNull.null ];
        JSValue *arrayValue = [JSValue valueWithObject:array inContext:context];
        NSArray *arrayResult = arrayValue.toArray;
        row(@"array", [NSString stringWithFormat:@"%d:%lu:%@:%@:%@:%d",
                                                  arrayValue.isArray,
                                                  (unsigned long)arrayResult.count,
                                                  arrayResult[0], arrayResult[1], arrayResult[2],
                                                  [arrayResult[3] isEqual:NSNull.null]]);

        NSDictionary *dictionary = @{
            @"name" : @"zig-js",
            @"nested" : @[ @1, @2 ],
        };
        JSValue *dictionaryValue = [JSValue valueWithObject:dictionary inContext:context];
        NSDictionary *dictionaryResult = dictionaryValue.toDictionary;
        row(@"dictionary", [NSString stringWithFormat:@"%@:%lu:%@",
                                                       dictionaryResult[@"name"],
                                                       (unsigned long)[dictionaryResult[@"nested"] count],
                                                       dictionaryResult[@"nested"][1]]);

        NSDate *date = [NSDate dateWithTimeIntervalSince1970:1234.5];
        JSValue *dateValue = [JSValue valueWithObject:date inContext:context];
        row(@"date", [NSString stringWithFormat:@"%d:%.1f", dateValue.isDate,
                                                 dateValue.toDate.timeIntervalSince1970]);

        JSValue *object = [context evaluateScript:@"({a: 1, b: 'two', c: null})"];
        NSDictionary *objectResult = object.toDictionary;
        row(@"object", [NSString stringWithFormat:@"%@:%@:%d", objectResult[@"a"],
                                                   objectResult[@"b"],
                                                   [objectResult[@"c"] isEqual:NSNull.null]]);

        JSValue *undefined = [JSValue valueWithUndefinedInContext:context];
        row(@"undefined", [NSString stringWithFormat:@"%d:%d", undefined.toObject == nil,
                                                      undefined.toArray == nil]);

        __block BOOL currentContextMatches = NO;
        __block BOOL currentCalleeIsNil = NO;
        __block BOOL currentThisIsPromise = NO;
        __block NSUInteger currentArgumentCount = NSUIntegerMax;
        __block JSValue *promiseFromCallback = nil;
        JSValue *promise = [JSValue valueWithNewPromiseInContext:context
                                                   fromExecutor:^(JSValue *resolve, JSValue *reject) {
                                                       currentContextMatches = JSContext.currentContext == context;
                                                       currentCalleeIsNil = JSContext.currentCallee == nil;
                                                       promiseFromCallback = JSContext.currentThis;
                                                       currentArgumentCount = JSContext.currentArguments.count;
                                                       [resolve callWithArguments:@[ @42 ]];
                                                   }];
        currentThisIsPromise = [promiseFromCallback isEqualToObject:promise];
        context[@"promise"] = promise;
        [context evaluateScript:@"promise.then(value => { globalThis.promiseResult = value; })"];
        [context evaluateScript:@"0"];
        row(@"promise", [NSString stringWithFormat:@"%d:%d:%d:%lu:%d",
                                                    currentContextMatches, currentCalleeIsNil,
                                                    currentThisIsPromise,
                                                    (unsigned long)currentArgumentCount,
                                                    [context[@"promiseResult"] toInt32] == 42]);

        NSObject *nativeObject = [NSObject new];
        JSValue *nativeA = [JSValue valueWithObject:nativeObject inContext:context];
        JSValue *nativeB = [JSValue valueWithObject:nativeObject inContext:context];
        JSValue *holder = [context evaluateScript:@"(() => { const child = {}; return { child }; })()"];
        row(@"identity", [NSString stringWithFormat:@"%d:%d:%d",
                                                     nativeA == nativeB,
                                                     nativeA.toObject == nativeObject,
                                                     holder[@"child"] == holder[@"child"]]);

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
        row(@"block", [NSString stringWithFormat:@"%d:%d:%d",
                                                  [[context evaluateScript:@"nativeAdder.call({ marker: 7 }, 20, 22)"] toInt32] == 42,
                                                  blockStateMatches,
                                                  adderValue.toObject == adder]);

        ZJSDiffExportObject *exportObject = [ZJSDiffExportObject new];
        exportObject.title = @"before";
        context[@"exported"] = exportObject;
        NSString *initialTitle = [context evaluateScript:@"exported.title"].toString;
        [context evaluateScript:@"exported.title = 'after'"];
        int32_t exportSum = [context evaluateScript:@"exported.addTo(20, 22)"].toInt32;
        row(@"export", [NSString stringWithFormat:@"%@:%@:%d:%d:%@",
                                                   initialTitle, exportObject.title,
                                                   exportSum,
                                                   ZJSDiffExportCallbackState,
                                                   [context evaluateScript:@"typeof exported.hiddenValue"].toString]);
        row(@"export-rename", [NSString stringWithFormat:@"%d:%@",
                                                          [context evaluateScript:@"exported.product(6, 7)"].toInt32,
                                                          [context evaluateScript:@"typeof exported.multiplyBy"].toString]);

        context[@"ExportClass"] = ZJSDiffExportObject.class;
        ZJSDiffExportObject *constructed =
            (ZJSDiffExportObject *)[context evaluateScript:@"new ExportClass('made')"].toObject;
        row(@"export-class", [NSString stringWithFormat:@"%@:%@",
                                                         [context evaluateScript:@"ExportClass.classPrefix('zig-js')"].toString,
                                                         constructed.title]);

        JSValue *symbolValue = [context evaluateScript:@"Symbol('edge')"];
        JSValue *bigIntValue = [context evaluateScript:@"9007199254740993n"];
        row(@"primitive-object", [NSString stringWithFormat:@"%d:%d",
                                                             symbolValue.toObject == symbolValue,
                                                             bigIntValue.toObject == bigIntValue]);

        NSError *nativeError = [NSError errorWithDomain:@"zig-js" code:42 userInfo:nil];
        JSValue *nativeErrorValue = [JSValue valueWithObject:nativeError inContext:context];
        id scriptErrorObject = [context evaluateScript:@"new Error('edge')"].toObject;
        row(@"errors", [NSString stringWithFormat:@"%d:%d:%lu",
                                                   nativeErrorValue.toObject == nativeError,
                                                   [scriptErrorObject isKindOfClass:NSDictionary.class],
                                                   (unsigned long)[scriptErrorObject count]]);

        NSDictionary *typedArray = [context evaluateScript:@"new Uint8Array([3, 4])"].toObject;
        NSDictionary *arrayBuffer = [context evaluateScript:@"new ArrayBuffer(4)"].toObject;
        row(@"buffers", [NSString stringWithFormat:@"%lu:%@:%@:%lu",
                                                    (unsigned long)typedArray.count,
                                                    typedArray[@"0"], typedArray[@"1"],
                                                    (unsigned long)arrayBuffer.count]);
    }
    return 0;
}
