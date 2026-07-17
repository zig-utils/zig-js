#import <JavaScriptCore/JavaScriptCore.h>

@protocol ZJSLifetimeExports <JSExport>
@property (nonatomic, copy) NSString *name;
- (int32_t)add:(int32_t)left to:(int32_t)right;
@end

@interface ZJSLifetimeObject : NSObject <ZJSLifetimeExports>
@property (nonatomic, copy) NSString *name;
@end

@implementation ZJSLifetimeObject
- (int32_t)add:(int32_t)left to:(int32_t)right { return left + right; }
@end

static int fail(int code)
{
    return code;
}

int main(void)
{
    for (NSUInteger iteration = 0; iteration < 200; ++iteration) {
        __weak JSVirtualMachine *releasedVM = nil;
        __weak JSContext *releasedContext = nil;
        __weak ZJSLifetimeObject *releasedObject = nil;
        @autoreleasepool {
            JSVirtualMachine *virtualMachine = [JSVirtualMachine new];
            JSContext *context = [[JSContext alloc] initWithVirtualMachine:virtualMachine];
            JSContext *sibling = [[JSContext alloc] initWithVirtualMachine:virtualMachine];
            ZJSLifetimeObject *object = [ZJSLifetimeObject new];
            object.name = [NSString stringWithFormat:@"object-%lu", (unsigned long)iteration];
            releasedVM = virtualMachine;
            releasedContext = context;
            releasedObject = object;

            context[@"exported"] = object;
            sibling[@"exported"] = object;
            if ([context evaluateScript:@"exported.addTo(20, 22)"].toInt32 != 42)
                return fail(1);
            if (context[@"exported"].toObject != object ||
                sibling[@"exported"].toObject != object)
                return fail(2);

            JSManagedValue *managed = [JSManagedValue managedValueWithValue:
                [context evaluateScript:@"({ marker: 42 })"]];
            NSObject *owner = [NSObject new];
            [virtualMachine addManagedReference:managed withOwner:owner];
            [virtualMachine addManagedReference:managed withOwner:owner];
            if (managed.value[@"marker"].toInt32 != 42)
                return fail(3);
            [virtualMachine removeManagedReference:managed withOwner:owner];
            [virtualMachine removeManagedReference:managed withOwner:owner];

            int32_t (^adder)(int32_t, int32_t) =
                ^int32_t(int32_t left, int32_t right) { return left + right; };
            JSValue *block = [JSValue valueWithObject:adder inContext:context];
            if ([block callWithArguments:@[ @20, @22 ]].toInt32 != 42)
                return fail(4);

            NSMutableArray *cycle = [NSMutableArray array];
            [cycle addObject:cycle];
            JSValue *cycleValue = [JSValue valueWithObject:cycle inContext:context];
            if (![cycleValue[0] isEqualToObject:cycleValue])
                return fail(5);
            [cycle removeAllObjects];
            cycleValue = nil;
            cycle = nil;
            block = nil;
            adder = nil;
            managed = nil;
            owner = nil;
            context = nil;
            sibling = nil;
            virtualMachine = nil;
            object = nil;
        }
        if (releasedVM)
            return fail(6);
        if (releasedContext)
            return fail(7);
        if (releasedObject)
            return fail(8);
    }
    return 0;
}
