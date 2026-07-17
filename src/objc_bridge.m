#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/runtime.h>
#import <zig-js/Extensions.h>
#include <stdlib.h>
#include <string.h>

@interface ZJSVirtualMachineState : NSObject
@property (nonatomic) JSContextGroupRef group;
@end

@implementation ZJSVirtualMachineState
- (void)dealloc
{
    if (_group)
        JSContextGroupRelease(_group);
}
@end

@interface ZJSContextState : NSObject
@property (nonatomic) JSGlobalContextRef context;
@property (nonatomic, strong) JSVirtualMachine *virtualMachine;
@property (nonatomic, strong) JSValue *exception;
@property (nonatomic, copy) void (^exceptionHandler)(JSContext *, JSValue *);
@property (nonatomic, strong) NSMapTable<NSValue *, JSValue *> *values;
@end

@implementation ZJSContextState
- (void)dealloc
{
    if (_context)
        JSGlobalContextRelease(_context);
}
@end

@interface ZJSValueState : NSObject
@property (nonatomic) JSValueRef value;
@property (nonatomic, strong) JSContext *context;
@end

@implementation ZJSValueState
- (void)dealloc
{
    if (_value && _context)
        ZJSValueUnprotect(_context.JSGlobalContextRef, _value);
}
@end

static const void *ZJSVirtualMachineStateKey = &ZJSVirtualMachineStateKey;
static const void *ZJSContextStateKey = &ZJSContextStateKey;
static const void *ZJSValueStateKey = &ZJSValueStateKey;

static ZJSVirtualMachineState *ZJSVMState(JSVirtualMachine *virtualMachine)
{
    return objc_getAssociatedObject(virtualMachine, ZJSVirtualMachineStateKey);
}

static ZJSContextState *ZJSCtxState(JSContext *context)
{
    return objc_getAssociatedObject(context, ZJSContextStateKey);
}

static ZJSValueState *ZJSValState(JSValue *value)
{
    return objc_getAssociatedObject(value, ZJSValueStateKey);
}

static NSMapTable<NSValue *, JSVirtualMachine *> *ZJSVirtualMachines(void)
{
    static NSMapTable<NSValue *, JSVirtualMachine *> *table;
    @synchronized([JSVirtualMachine class]) {
        if (!table)
            table = [NSMapTable strongToWeakObjectsMapTable];
    }
    return table;
}

static NSMapTable<NSValue *, JSContext *> *ZJSContexts(void)
{
    static NSMapTable<NSValue *, JSContext *> *table;
    @synchronized([JSContext class]) {
        if (!table)
            table = [NSMapTable strongToWeakObjectsMapTable];
    }
    return table;
}

static NSValue *ZJSPointerKey(const void *pointer)
{
    return [NSValue valueWithPointer:pointer];
}

static JSStringRef ZJSStringCreate(NSString *string)
{
    if (!string)
        return NULL;
    NSUInteger length = string.length;
    JSChar *characters = length ? malloc(length * sizeof(JSChar)) : NULL;
    if (length && !characters)
        return NULL;
    if (length)
        [string getCharacters:characters range:NSMakeRange(0, length)];
    JSStringRef result = JSStringCreateWithCharacters(characters, length);
    free(characters);
    return result;
}

static NSString *ZJSStringCopy(JSStringRef string)
{
    if (!string)
        return nil;
    return [[NSString alloc] initWithCharacters:JSStringGetCharactersPtr(string)
                                         length:JSStringGetLength(string)];
}

@interface JSVirtualMachine (ZJSPrivate)
- (instancetype)zjs_initWithGroup:(JSContextGroupRef)group retain:(BOOL)retain
    __attribute__((objc_method_family(init)));
@end

@interface JSContext (ZJSPrivate)
- (instancetype)zjs_initWithContext:(JSGlobalContextRef)context
                      virtualMachine:(JSVirtualMachine *)virtualMachine
                              retain:(BOOL)retain
    __attribute__((objc_method_family(init)));
- (void)zjs_recordException:(JSValueRef)exception;
@end

@interface JSValue (ZJSPrivate)
- (instancetype)zjs_initWithValue:(JSValueRef)value context:(JSContext *)context
    __attribute__((objc_method_family(init)));
@end

@implementation JSVirtualMachine

- (instancetype)init
{
    JSContextGroupRef group = JSContextGroupCreate();
    if (!group)
        return nil;
    return [self zjs_initWithGroup:group retain:NO];
}

- (instancetype)zjs_initWithGroup:(JSContextGroupRef)group retain:(BOOL)retain
{
    self = [super init];
    if (!self)
        return nil;
    ZJSVirtualMachineState *state = [ZJSVirtualMachineState new];
    state.group = retain ? JSContextGroupRetain(group) : group;
    if (!state.group)
        return nil;
    objc_setAssociatedObject(self, ZJSVirtualMachineStateKey, state,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized([JSVirtualMachine class]) {
        [ZJSVirtualMachines() setObject:self forKey:ZJSPointerKey(state.group)];
    }
    return self;
}

@end

static JSVirtualMachine *ZJSVirtualMachineForGroup(JSContextGroupRef group)
{
    @synchronized([JSVirtualMachine class]) {
        JSVirtualMachine *existing = [ZJSVirtualMachines() objectForKey:ZJSPointerKey(group)];
        if (existing)
            return existing;
        return [[JSVirtualMachine alloc] zjs_initWithGroup:group retain:YES];
    }
}

@implementation JSContext

- (instancetype)init
{
    JSVirtualMachine *virtualMachine = [JSVirtualMachine new];
    return [self initWithVirtualMachine:virtualMachine];
}

- (instancetype)initWithVirtualMachine:(JSVirtualMachine *)virtualMachine
{
    if (!virtualMachine)
        return nil;
    JSGlobalContextRef context = JSGlobalContextCreateInGroup(ZJSVMState(virtualMachine).group, NULL);
    if (!context)
        return nil;
    return [self zjs_initWithContext:context virtualMachine:virtualMachine retain:NO];
}

- (instancetype)zjs_initWithContext:(JSGlobalContextRef)context
                      virtualMachine:(JSVirtualMachine *)virtualMachine
                              retain:(BOOL)retain
{
    self = [super init];
    if (!self)
        return nil;
    ZJSContextState *state = [ZJSContextState new];
    state.context = retain ? JSGlobalContextRetain(context) : context;
    state.virtualMachine = virtualMachine;
    state.values = [NSMapTable strongToWeakObjectsMapTable];
    __weak JSContext *weakContext = self;
    state.exceptionHandler = ^(JSContext *callbackContext, JSValue *exception) {
        ZJSCtxState(weakContext ?: callbackContext).exception = exception;
    };
    objc_setAssociatedObject(self, ZJSContextStateKey, state,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized([JSContext class]) {
        [ZJSContexts() setObject:self forKey:ZJSPointerKey(state.context)];
    }
    return self;
}

+ (JSContext *)contextWithJSGlobalContextRef:(JSGlobalContextRef)context
{
    if (!context)
        return nil;
    @synchronized([JSContext class]) {
        JSContext *existing = [ZJSContexts() objectForKey:ZJSPointerKey(context)];
        if (existing)
            return existing;
        JSVirtualMachine *virtualMachine = ZJSVirtualMachineForGroup(JSContextGetGroup(context));
        return [[JSContext alloc] zjs_initWithContext:context
                                      virtualMachine:virtualMachine
                                              retain:YES];
    }
}

- (JSGlobalContextRef)JSGlobalContextRef { return ZJSCtxState(self).context; }
- (JSVirtualMachine *)virtualMachine { return ZJSCtxState(self).virtualMachine; }

- (JSValue *)evaluateScript:(NSString *)script
{
    return [self evaluateScript:script withSourceURL:nil];
}

- (JSValue *)evaluateScript:(NSString *)script withSourceURL:(NSURL *)sourceURL
{
    JSStringRef source = ZJSStringCreate(script);
    JSStringRef url = ZJSStringCreate(sourceURL.absoluteString);
    if (!source)
        return nil;
    JSValueRef exception = NULL;
    JSValueRef value = JSEvaluateScript(self.JSGlobalContextRef, source, NULL, url, 1, &exception);
    JSStringRelease(source);
    if (url)
        JSStringRelease(url);
    if (exception) {
        [self zjs_recordException:exception];
        return nil;
    }
    return [JSValue valueWithJSValueRef:value inContext:self];
}

- (void)zjs_recordException:(JSValueRef)exception
{
    JSValue *wrapped = [JSValue valueWithJSValueRef:exception inContext:self];
    ZJSContextState *state = ZJSCtxState(self);
    state.exception = wrapped;
    if (state.exceptionHandler)
        state.exceptionHandler(self, wrapped);
}

- (JSValue *)globalObject
{
    return [JSValue valueWithJSValueRef:JSContextGetGlobalObject(self.JSGlobalContextRef)
                              inContext:self];
}

- (JSValue *)exception { return ZJSCtxState(self).exception; }
- (void)setException:(JSValue *)exception { ZJSCtxState(self).exception = exception; }
- (void (^)(JSContext *, JSValue *))exceptionHandler { return ZJSCtxState(self).exceptionHandler; }
- (void)setExceptionHandler:(void (^)(JSContext *, JSValue *))handler { ZJSCtxState(self).exceptionHandler = handler; }

- (NSString *)name
{
    JSStringRef name = JSGlobalContextCopyName(self.JSGlobalContextRef);
    NSString *result = ZJSStringCopy(name);
    if (name)
        JSStringRelease(name);
    return result;
}

- (void)setName:(NSString *)name
{
    JSStringRef string = ZJSStringCreate(name);
    JSGlobalContextSetName(self.JSGlobalContextRef, string);
    if (string)
        JSStringRelease(string);
}

- (BOOL)isInspectable { return JSGlobalContextIsInspectable(self.JSGlobalContextRef); }
- (void)setInspectable:(BOOL)inspectable { JSGlobalContextSetInspectable(self.JSGlobalContextRef, inspectable); }

- (JSValue *)objectForKeyedSubscript:(id)key
{
    JSValue *keyValue = [JSValue valueWithObject:key inContext:self];
    JSValueRef exception = NULL;
    JSValueRef value = JSObjectGetPropertyForKey(self.JSGlobalContextRef,
                                                 JSContextGetGlobalObject(self.JSGlobalContextRef),
                                                 keyValue.JSValueRef, &exception);
    if (exception) {
        [self zjs_recordException:exception];
        return nil;
    }
    return [JSValue valueWithJSValueRef:value inContext:self];
}

- (void)setObject:(id)object forKeyedSubscript:(NSObject<NSCopying> *)key
{
    JSValue *keyValue = [JSValue valueWithObject:key inContext:self];
    JSValue *objectValue = [JSValue valueWithObject:object inContext:self];
    JSValueRef exception = NULL;
    JSObjectSetPropertyForKey(self.JSGlobalContextRef,
                              JSContextGetGlobalObject(self.JSGlobalContextRef),
                              keyValue.JSValueRef, objectValue.JSValueRef, 0, &exception);
    if (exception)
        [self zjs_recordException:exception];
}

@end

@implementation JSValue

- (instancetype)zjs_initWithValue:(JSValueRef)value context:(JSContext *)context
{
    self = [super init];
    if (!self || !value || !context || !ZJSValueProtect(context.JSGlobalContextRef, value))
        return nil;
    ZJSValueState *state = [ZJSValueState new];
    state.value = value;
    state.context = context;
    objc_setAssociatedObject(self, ZJSValueStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [ZJSCtxState(context).values setObject:self forKey:ZJSPointerKey(value)];
    return self;
}

+ (JSValue *)valueWithJSValueRef:(JSValueRef)value inContext:(JSContext *)context
{
    if (!value || !context)
        return nil;
    JSValue *existing = [ZJSCtxState(context).values objectForKey:ZJSPointerKey(value)];
    return existing ?: [[JSValue alloc] zjs_initWithValue:value context:context];
}

- (JSValueRef)JSValueRef { return ZJSValState(self).value; }
- (JSContext *)context { return ZJSValState(self).context; }

+ (JSValue *)valueWithUndefinedInContext:(JSContext *)context { return [self valueWithJSValueRef:JSValueMakeUndefined(context.JSGlobalContextRef) inContext:context]; }
+ (JSValue *)valueWithNullInContext:(JSContext *)context { return [self valueWithJSValueRef:JSValueMakeNull(context.JSGlobalContextRef) inContext:context]; }
+ (JSValue *)valueWithBool:(BOOL)value inContext:(JSContext *)context { return [self valueWithJSValueRef:JSValueMakeBoolean(context.JSGlobalContextRef, value) inContext:context]; }
+ (JSValue *)valueWithDouble:(double)value inContext:(JSContext *)context { return [self valueWithJSValueRef:JSValueMakeNumber(context.JSGlobalContextRef, value) inContext:context]; }
+ (JSValue *)valueWithInt32:(int32_t)value inContext:(JSContext *)context { return [self valueWithDouble:value inContext:context]; }
+ (JSValue *)valueWithUInt32:(uint32_t)value inContext:(JSContext *)context { return [self valueWithDouble:value inContext:context]; }

+ (JSValue *)valueWithObject:(id)object inContext:(JSContext *)context
{
    if ([object isKindOfClass:[JSValue class]]) {
        JSValue *value = object;
        if (value.context.virtualMachine != context.virtualMachine)
            [NSException raise:NSInvalidArgumentException format:@"JSValue belongs to a different JSVirtualMachine"];
        return value;
    }
    if (!object)
        return [self valueWithUndefinedInContext:context];
    if (object == [NSNull null])
        return [self valueWithNullInContext:context];
    if ([object isKindOfClass:[NSString class]]) {
        JSStringRef string = ZJSStringCreate(object);
        JSValue *value = [self valueWithJSValueRef:JSValueMakeString(context.JSGlobalContextRef, string)
                                         inContext:context];
        if (string)
            JSStringRelease(string);
        return value;
    }
    if ([object isKindOfClass:[NSNumber class]]) {
        const char *type = [object objCType];
        if (!strcmp(type, @encode(BOOL)))
            return [self valueWithBool:[object boolValue] inContext:context];
        return [self valueWithDouble:[object doubleValue] inContext:context];
    }
    [NSException raise:NSInvalidArgumentException
                format:@"Unsupported Objective-C value class %@", [object class]];
    return nil;
}

- (BOOL)isUndefined { return JSValueIsUndefined(self.context.JSGlobalContextRef, self.JSValueRef); }
- (BOOL)isNull { return JSValueIsNull(self.context.JSGlobalContextRef, self.JSValueRef); }
- (BOOL)isBoolean { return JSValueIsBoolean(self.context.JSGlobalContextRef, self.JSValueRef); }
- (BOOL)isNumber { return JSValueIsNumber(self.context.JSGlobalContextRef, self.JSValueRef); }
- (BOOL)isString { return JSValueIsString(self.context.JSGlobalContextRef, self.JSValueRef); }
- (BOOL)isObject { return JSValueIsObject(self.context.JSGlobalContextRef, self.JSValueRef); }
- (BOOL)isArray { return JSValueIsArray(self.context.JSGlobalContextRef, self.JSValueRef); }
- (BOOL)isDate { return JSValueIsDate(self.context.JSGlobalContextRef, self.JSValueRef); }
- (BOOL)isSymbol { return JSValueIsSymbol(self.context.JSGlobalContextRef, self.JSValueRef); }
- (BOOL)isBigInt { return JSValueIsBigInt(self.context.JSGlobalContextRef, self.JSValueRef); }
- (BOOL)toBool { return JSValueToBoolean(self.context.JSGlobalContextRef, self.JSValueRef); }
- (double)toDouble { return JSValueToNumber(self.context.JSGlobalContextRef, self.JSValueRef, NULL); }
- (int32_t)toInt32 { return JSValueToInt32(self.context.JSGlobalContextRef, self.JSValueRef, NULL); }
- (uint32_t)toUInt32 { return JSValueToUInt32(self.context.JSGlobalContextRef, self.JSValueRef, NULL); }
- (int64_t)toInt64 { return JSValueToInt64(self.context.JSGlobalContextRef, self.JSValueRef, NULL); }
- (uint64_t)toUInt64 { return JSValueToUInt64(self.context.JSGlobalContextRef, self.JSValueRef, NULL); }

- (NSString *)toString
{
    JSValueRef exception = NULL;
    JSStringRef string = JSValueToStringCopy(self.context.JSGlobalContextRef, self.JSValueRef, &exception);
    if (exception) {
        [self.context zjs_recordException:exception];
        return nil;
    }
    NSString *result = ZJSStringCopy(string);
    if (string)
        JSStringRelease(string);
    return result;
}

- (NSNumber *)toNumber { return @([self toDouble]); }
- (id)toObject
{
    if (self.isUndefined || self.isNull)
        return nil;
    if (self.isBoolean)
        return @([self toBool]);
    if (self.isNumber)
        return [self toNumber];
    if (self.isString)
        return [self toString];
    return self;
}

- (BOOL)isEqualToObject:(id)object
{
    JSValue *other = [JSValue valueWithObject:object inContext:self.context];
    return JSValueIsStrictEqual(self.context.JSGlobalContextRef, self.JSValueRef, other.JSValueRef);
}

- (BOOL)isEqualWithTypeCoercionToObject:(id)object
{
    JSValue *other = [JSValue valueWithObject:object inContext:self.context];
    return JSValueIsEqual(self.context.JSGlobalContextRef, self.JSValueRef, other.JSValueRef, NULL);
}

@end
