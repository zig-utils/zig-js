#import <JavaScriptCore/JavaScriptCore.h>
#include <stdio.h>

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
    }
    return 0;
}
