#import <JavaScriptCore/JavaScriptCore.h>

extern void ZJSObjectiveCBridgeSetFailureCountdown(NSInteger countdown);

@protocol ZJSFaultExports <JSExport>
@property (nonatomic, copy, getter=exportedTitle) NSString *title;
- (int32_t)add:(int32_t)left to:(int32_t)right;
@end

@interface ZJSFaultObject : NSObject <ZJSFaultExports>
@property (nonatomic, copy, getter=exportedTitle) NSString *title;
@end

@implementation ZJSFaultObject
- (int32_t)add:(int32_t)left to:(int32_t)right { return left + right; }
@end

static int require(BOOL condition, int code)
{
    return condition ? 0 : code;
}

int main(void)
{
    @autoreleasepool {
        JSContext *context = [JSContext new];
        ZJSObjectiveCBridgeSetFailureCountdown(0);
        if (require([context evaluateScript:@"20 + 22"] == nil, 1)) return 1;
        ZJSObjectiveCBridgeSetFailureCountdown(-1);
        if (require([context evaluateScript:@"20 + 22"].toInt32 == 42, 2)) return 2;
        context.name = @"before-fault";
        ZJSObjectiveCBridgeSetFailureCountdown(0);
        context.name = @"after-fault";
        if (require([context.name isEqualToString:@"before-fault"], 15)) return 15;
        ZJSObjectiveCBridgeSetFailureCountdown(0);
        context[@"failedKey"] = @42;
        ZJSObjectiveCBridgeSetFailureCountdown(-1);
        if (require(context[@"failedKey"].isUndefined, 16)) return 16;

        NSDictionary *dictionary = @{ @"answer": @42 };
        ZJSObjectiveCBridgeSetFailureCountdown(0);
        if (require([JSValue valueWithObject:dictionary inContext:context] == nil, 17)) return 17;
        ZJSObjectiveCBridgeSetFailureCountdown(-1);
        if (require([JSValue valueWithObject:dictionary inContext:context][@"answer"].toInt32 == 42, 18)) return 18;

        NSObject *native = [NSObject new];
        ZJSObjectiveCBridgeSetFailureCountdown(0);
        if (require([JSValue valueWithObject:native inContext:context] == nil, 3)) return 3;
        ZJSObjectiveCBridgeSetFailureCountdown(-1);
        if (require([JSValue valueWithObject:native inContext:context].toObject == native, 4)) return 4;

        JSValue *function = [context evaluateScript:@"(a, b) => a + b"];
        BOOL argumentFailure = NO;
        ZJSObjectiveCBridgeSetFailureCountdown(0);
        @try {
            [function callWithArguments:@[ @20, @22 ]];
        } @catch (NSException *exception) {
            argumentFailure = [exception.name isEqualToString:NSMallocException];
        }
        if (require(argumentFailure, 5)) return 5;
        ZJSObjectiveCBridgeSetFailureCountdown(-1);
        if (require([function callWithArguments:@[ @20, @22 ]].toInt32 == 42, 6)) return 6;

        int32_t (^block)(int32_t, int32_t) = ^int32_t(int32_t left, int32_t right) {
            return left + right;
        };
        JSValue *blockValue = [JSValue valueWithObject:block inContext:context];
        for (NSInteger countdown = 1; countdown <= 3; ++countdown) {
            ZJSObjectiveCBridgeSetFailureCountdown(countdown);
            if (require([blockValue callWithArguments:@[ @20, @22 ]] == nil, 7)) return 7;
        }
        ZJSObjectiveCBridgeSetFailureCountdown(-1);
        if (require([blockValue callWithArguments:@[ @20, @22 ]].toInt32 == 42, 8)) return 8;

        ZJSFaultObject *exported = [ZJSFaultObject new];
        exported.title = @"fault";
        context[@"exported"] = exported;
        JSValue *exportedValue = context[@"exported"];
        ZJSObjectiveCBridgeSetFailureCountdown(0);
        JSValue *failedMethod = [exportedValue valueForProperty:@"addTo"];
        if (require(failedMethod == nil || failedMethod.isUndefined, 9)) return 9;
        ZJSObjectiveCBridgeSetFailureCountdown(-1);
        JSValue *method = [exportedValue valueForProperty:@"addTo"];
        if (require(method.isObject, 10)) return 10;
        for (NSInteger countdown = 1; countdown <= 3; ++countdown) {
            ZJSObjectiveCBridgeSetFailureCountdown(countdown);
            if (require([method callWithArguments:@[ @20, @22 ]] == nil, 11)) return 11;
        }
        ZJSObjectiveCBridgeSetFailureCountdown(-1);
        if (require([method callWithArguments:@[ @20, @22 ]].toInt32 == 42, 12)) return 12;

        ZJSObjectiveCBridgeSetFailureCountdown(0);
        JSValue *failedProperty = [exportedValue valueForProperty:@"title"];
        if (require(failedProperty == nil || failedProperty.isUndefined, 13)) return 13;
        ZJSObjectiveCBridgeSetFailureCountdown(-1);
        if (require([[exportedValue valueForProperty:@"title"].toString isEqualToString:@"fault"], 14)) return 14;
    }
    return 0;
}
