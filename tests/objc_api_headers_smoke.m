#import <JavaScriptCore/JavaScriptCore.h>

@protocol ZJSHeaderExport <JSExport>
JSExportAs(add,
- (double)add:(double)left to:(double)right
);
@property (nonatomic) NSString *name;
@end

static void require_bridge_declarations(JSContext *context, JSValue *value,
                                        JSVirtualMachine *virtualMachine,
                                        JSManagedValue *managed)
{
    context[@"value"] = value;
    value[@"answer"] = @42;
    (void)[value callWithArguments:@[@1, @2]];
    (void)[JSValue valueWithNewPromiseInContext:context
                                    fromExecutor:^(JSValue *resolve, JSValue *reject) {
                                        (void)resolve;
                                        (void)reject;
                                    }];
    [virtualMachine addManagedReference:managed withOwner:context];
    [virtualMachine removeManagedReference:managed withOwner:context];
}

int main(void)
{
    require_bridge_declarations(nil, nil, nil, nil);
    return 0;
}
