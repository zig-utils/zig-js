#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/runtime.h>
#import <zig-js/Extensions.h>
#include <stdlib.h>
#include <string.h>

JS_EXPORT NSString *const JSPropertyDescriptorWritableKey = @"writable";
JS_EXPORT NSString *const JSPropertyDescriptorEnumerableKey = @"enumerable";
JS_EXPORT NSString *const JSPropertyDescriptorConfigurableKey = @"configurable";
JS_EXPORT NSString *const JSPropertyDescriptorValueKey = @"value";
JS_EXPORT NSString *const JSPropertyDescriptorGetKey = @"get";
JS_EXPORT NSString *const JSPropertyDescriptorSetKey = @"set";

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

@interface ZJSObjectConversionState : NSObject
@property (nonatomic, strong) NSMutableArray<JSValue *> *values;
@property (nonatomic, strong) NSMutableArray *objects;
- (id)objectForValue:(JSValue *)value;
- (void)recordValue:(JSValue *)value object:(id)object;
@end

@implementation ZJSObjectConversionState

- (instancetype)init
{
    self = [super init];
    if (self) {
        _values = [NSMutableArray array];
        _objects = [NSMutableArray array];
    }
    return self;
}

- (id)objectForValue:(JSValue *)value
{
    for (NSUInteger index = 0; index < _values.count; ++index) {
        JSValue *candidate = _values[index];
        if (JSValueIsStrictEqual(value.context.JSGlobalContextRef,
                                 value.JSValueRef, candidate.JSValueRef))
            return _objects[index];
    }
    return nil;
}

- (void)recordValue:(JSValue *)value object:(id)object
{
    [_values addObject:value];
    [_objects addObject:object];
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

static JSObjectRef ZJSObjectForValue(JSValue *value);

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

+ (JSValue *)valueWithNewObjectInContext:(JSContext *)context
{
    return [self valueWithJSValueRef:JSObjectMake(context.JSGlobalContextRef, NULL, NULL)
                             inContext:context];
}

+ (JSValue *)valueWithNewArrayInContext:(JSContext *)context
{
    JSValueRef exception = NULL;
    JSObjectRef value = JSObjectMakeArray(context.JSGlobalContextRef, 0, NULL, &exception);
    if (exception) {
        [context zjs_recordException:exception];
        return nil;
    }
    return [self valueWithJSValueRef:value inContext:context];
}

+ (JSValue *)valueWithNewRegularExpressionFromPattern:(NSString *)pattern
                                                flags:(NSString *)flags
                                            inContext:(JSContext *)context
{
    JSValue *patternValue = [self valueWithObject:pattern inContext:context];
    JSValue *flagsValue = [self valueWithObject:flags inContext:context];
    JSValueRef arguments[] = { patternValue.JSValueRef, flagsValue.JSValueRef };
    JSValueRef exception = NULL;
    JSObjectRef value = JSObjectMakeRegExp(context.JSGlobalContextRef, 2, arguments, &exception);
    if (exception) {
        [context zjs_recordException:exception];
        return nil;
    }
    return [self valueWithJSValueRef:value inContext:context];
}

+ (JSValue *)valueWithNewErrorFromMessage:(NSString *)message inContext:(JSContext *)context
{
    JSValue *messageValue = [self valueWithObject:message inContext:context];
    JSValueRef argument = messageValue.JSValueRef;
    JSValueRef exception = NULL;
    JSObjectRef value = JSObjectMakeError(context.JSGlobalContextRef, 1, &argument, &exception);
    if (exception) {
        [context zjs_recordException:exception];
        return nil;
    }
    return [self valueWithJSValueRef:value inContext:context];
}

+ (JSValue *)valueWithNewSymbolFromDescription:(NSString *)description inContext:(JSContext *)context
{
    JSStringRef string = ZJSStringCreate(description);
    if (!string)
        return nil;
    JSValueRef value = JSValueMakeSymbol(context.JSGlobalContextRef, string);
    JSStringRelease(string);
    return [self valueWithJSValueRef:value inContext:context];
}

+ (JSValue *)valueWithNewBigIntFromString:(NSString *)string inContext:(JSContext *)context
{
    JSStringRef characters = ZJSStringCreate(string);
    if (!characters)
        return nil;
    JSValueRef exception = NULL;
    JSValueRef value = JSBigIntCreateWithString(context.JSGlobalContextRef, characters, &exception);
    JSStringRelease(characters);
    if (exception) {
        [context zjs_recordException:exception];
        return nil;
    }
    return [self valueWithJSValueRef:value inContext:context];
}

+ (JSValue *)valueWithNewBigIntFromInt64:(int64_t)value inContext:(JSContext *)context
{
    JSValueRef exception = NULL;
    JSValueRef result = JSBigIntCreateWithInt64(context.JSGlobalContextRef, value, &exception);
    if (exception) {
        [context zjs_recordException:exception];
        return nil;
    }
    return [self valueWithJSValueRef:result inContext:context];
}

+ (JSValue *)valueWithNewBigIntFromUInt64:(uint64_t)value inContext:(JSContext *)context
{
    JSValueRef exception = NULL;
    JSValueRef result = JSBigIntCreateWithUInt64(context.JSGlobalContextRef, value, &exception);
    if (exception) {
        [context zjs_recordException:exception];
        return nil;
    }
    return [self valueWithJSValueRef:result inContext:context];
}

+ (JSValue *)valueWithNewBigIntFromDouble:(double)value inContext:(JSContext *)context
{
    JSValueRef exception = NULL;
    JSValueRef result = JSBigIntCreateWithDouble(context.JSGlobalContextRef, value, &exception);
    if (exception) {
        [context zjs_recordException:exception];
        return nil;
    }
    return [self valueWithJSValueRef:result inContext:context];
}

static NSValue *ZJSObjectiveCIdentityKey(id object)
{
    return [NSValue valueWithPointer:(__bridge const void *)object];
}

static JSValue *ZJSValueFromObject(id object, JSContext *context,
                                   NSMutableDictionary<NSValue *, JSValue *> *seen)
{
    if ([object isKindOfClass:[JSValue class]]) {
        JSValue *value = object;
        if (value.context.virtualMachine != context.virtualMachine)
            [NSException raise:NSInvalidArgumentException format:@"JSValue belongs to a different JSVirtualMachine"];
        return value;
    }
    if (!object)
        return [JSValue valueWithUndefinedInContext:context];
    if (object == [NSNull null])
        return [JSValue valueWithNullInContext:context];
    if ([object isKindOfClass:[NSString class]]) {
        JSStringRef string = ZJSStringCreate(object);
        JSValue *value = [JSValue valueWithJSValueRef:JSValueMakeString(context.JSGlobalContextRef, string)
                                            inContext:context];
        if (string)
            JSStringRelease(string);
        return value;
    }
    if ([object isKindOfClass:[NSNumber class]]) {
        const char *type = [object objCType];
        if (!strcmp(type, @encode(BOOL)))
            return [JSValue valueWithBool:[object boolValue] inContext:context];
        return [JSValue valueWithDouble:[object doubleValue] inContext:context];
    }
    if ([object isKindOfClass:[NSDate class]]) {
        JSValueRef argument = JSValueMakeNumber(context.JSGlobalContextRef,
                                                [object timeIntervalSince1970] * 1000.0);
        JSValueRef exception = NULL;
        JSObjectRef date = JSObjectMakeDate(context.JSGlobalContextRef, 1, &argument, &exception);
        if (exception) {
            [context zjs_recordException:exception];
            return nil;
        }
        return [JSValue valueWithJSValueRef:date inContext:context];
    }
    if ([object isKindOfClass:[NSArray class]]) {
        NSValue *key = ZJSObjectiveCIdentityKey(object);
        JSValue *existing = seen[key];
        if (existing)
            return existing;
        JSValueRef exception = NULL;
        JSObjectRef array = JSObjectMakeArray(context.JSGlobalContextRef, 0, NULL, &exception);
        if (exception) {
            [context zjs_recordException:exception];
            return nil;
        }
        JSValue *result = [JSValue valueWithJSValueRef:array inContext:context];
        seen[key] = result;
        NSUInteger count = [object count];
        for (NSUInteger index = 0; index < count; ++index) {
            JSValue *item = ZJSValueFromObject(object[index], context, seen);
            if (!item)
                return nil;
            JSObjectSetPropertyAtIndex(context.JSGlobalContextRef, array, (unsigned)index,
                                       item.JSValueRef, &exception);
            if (exception) {
                [context zjs_recordException:exception];
                return nil;
            }
        }
        return result;
    }
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSValue *key = ZJSObjectiveCIdentityKey(object);
        JSValue *existing = seen[key];
        if (existing)
            return existing;
        JSObjectRef dictionary = JSObjectMake(context.JSGlobalContextRef, NULL, NULL);
        JSValue *result = [JSValue valueWithJSValueRef:dictionary inContext:context];
        seen[key] = result;
        for (id property in object) {
            if (![property isKindOfClass:[NSString class]])
                continue;
            JSValue *item = ZJSValueFromObject(object[property], context, seen);
            if (!item)
                return nil;
            JSStringRef name = ZJSStringCreate(property);
            if (!name)
                return nil;
            JSValueRef exception = NULL;
            JSObjectSetProperty(context.JSGlobalContextRef, dictionary, name,
                                item.JSValueRef, kJSPropertyAttributeNone, &exception);
            JSStringRelease(name);
            if (exception) {
                [context zjs_recordException:exception];
                return nil;
            }
        }
        return result;
    }
    [NSException raise:NSInvalidArgumentException
                format:@"Unsupported Objective-C value class %@", [object class]];
    return nil;
}

+ (JSValue *)valueWithObject:(id)object inContext:(JSContext *)context
{
    return ZJSValueFromObject(object, context, [NSMutableDictionary dictionary]);
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

- (BOOL)isInstanceOf:(id)object
{
    JSValue *constructor = [JSValue valueWithObject:object inContext:self.context];
    JSValueRef exception = NULL;
    JSObjectRef constructorObject = JSValueToObject(self.context.JSGlobalContextRef,
                                                     constructor.JSValueRef, &exception);
    if (!exception) {
        BOOL result = JSValueIsInstanceOfConstructor(self.context.JSGlobalContextRef,
                                                     self.JSValueRef, constructorObject,
                                                     &exception);
        if (!exception)
            return result;
    }
    [self.context zjs_recordException:exception];
    return NO;
}

- (BOOL)toBool { return JSValueToBoolean(self.context.JSGlobalContextRef, self.JSValueRef); }

- (double)toDouble
{
    JSValueRef exception = NULL;
    double result = JSValueToNumber(self.context.JSGlobalContextRef, self.JSValueRef, &exception);
    if (exception)
        [self.context zjs_recordException:exception];
    return result;
}

- (int32_t)toInt32
{
    JSValueRef exception = NULL;
    int32_t result = JSValueToInt32(self.context.JSGlobalContextRef, self.JSValueRef, &exception);
    if (exception)
        [self.context zjs_recordException:exception];
    return result;
}

- (uint32_t)toUInt32
{
    JSValueRef exception = NULL;
    uint32_t result = JSValueToUInt32(self.context.JSGlobalContextRef, self.JSValueRef, &exception);
    if (exception)
        [self.context zjs_recordException:exception];
    return result;
}

- (int64_t)toInt64
{
    JSValueRef exception = NULL;
    int64_t result = JSValueToInt64(self.context.JSGlobalContextRef, self.JSValueRef, &exception);
    if (exception)
        [self.context zjs_recordException:exception];
    return result;
}

- (uint64_t)toUInt64
{
    JSValueRef exception = NULL;
    uint64_t result = JSValueToUInt64(self.context.JSGlobalContextRef, self.JSValueRef, &exception);
    if (exception)
        [self.context zjs_recordException:exception];
    return result;
}

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

- (NSNumber *)toNumber
{
    if (self.isBoolean)
        return @([self toBool]);
    JSValueRef exception = NULL;
    double result = JSValueToNumber(self.context.JSGlobalContextRef, self.JSValueRef, &exception);
    if (exception) {
        [self.context zjs_recordException:exception];
        return nil;
    }
    return @(result);
}
static id ZJSObjectFromValue(JSValue *value, ZJSObjectConversionState *state);

static NSArray *ZJSArrayFromValue(JSValue *value,
                                  ZJSObjectConversionState *state)
{
    if (value.isUndefined || value.isNull)
        return nil;
    if (!value.isObject) {
        JSValue *error = [JSValue valueWithNewErrorFromMessage:@"Cannot convert a non-object to NSArray"
                                                     inContext:value.context];
        [value.context zjs_recordException:error.JSValueRef];
        return nil;
    }
    id existing = [state objectForValue:value];
    if (existing)
        return existing;
    NSUInteger count = [[value valueForProperty:@"length"] toUInt32];
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    [state recordValue:value object:result];
    for (NSUInteger index = 0; index < count; ++index) {
        id item = ZJSObjectFromValue([value valueAtIndex:index], state);
        [result addObject:item ?: NSNull.null];
    }
    return result;
}

static NSDictionary *ZJSDictionaryFromValue(JSValue *value,
                                             ZJSObjectConversionState *state)
{
    if (value.isUndefined || value.isNull)
        return nil;
    JSObjectRef object = ZJSObjectForValue(value);
    if (!object)
        return nil;
    id existing = [state objectForValue:value];
    if (existing)
        return existing;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [state recordValue:value object:result];
    JSPropertyNameArrayRef names = JSObjectCopyPropertyNames(value.context.JSGlobalContextRef,
                                                            object);
    size_t count = JSPropertyNameArrayGetCount(names);
    for (size_t index = 0; index < count; ++index) {
        JSStringRef name = JSPropertyNameArrayGetNameAtIndex(names, index);
        JSValueRef exception = NULL;
        JSValueRef property = JSObjectGetProperty(value.context.JSGlobalContextRef,
                                                  object, name, &exception);
        if (exception) {
            JSPropertyNameArrayRelease(names);
            [value.context zjs_recordException:exception];
            return nil;
        }
        NSString *propertyName = ZJSStringCopy(name);
        id item = ZJSObjectFromValue([JSValue valueWithJSValueRef:property
                                                        inContext:value.context],
                                     state);
        result[propertyName] = item ?: NSNull.null;
    }
    JSPropertyNameArrayRelease(names);
    return result;
}

static id ZJSObjectFromValue(JSValue *value, ZJSObjectConversionState *state)
{
    if (value.isUndefined)
        return nil;
    if (value.isNull)
        return NSNull.null;
    if (value.isBoolean)
        return @([value toBool]);
    if (value.isNumber)
        return [value toNumber];
    if (value.isString)
        return [value toString];
    if (value.isDate)
        return [value toDate];
    if (value.isArray)
        return ZJSArrayFromValue(value, state);
    if (value.isObject)
        return ZJSDictionaryFromValue(value, state);
    return value;
}

- (id)toObject
{
    return ZJSObjectFromValue(self, [ZJSObjectConversionState new]);
}

- (id)toObjectOfClass:(Class)expectedClass
{
    id result = self.toObject;
    return [result isKindOfClass:expectedClass] ? result : nil;
}

- (NSDate *)toDate
{
    return [NSDate dateWithTimeIntervalSince1970:self.toDouble / 1000.0];
}

- (NSArray *)toArray
{
    return ZJSArrayFromValue(self, [ZJSObjectConversionState new]);
}

- (NSDictionary *)toDictionary
{
    return ZJSDictionaryFromValue(self, [ZJSObjectConversionState new]);
}

- (BOOL)isEqualToObject:(id)object
{
    JSValue *other = [JSValue valueWithObject:object inContext:self.context];
    return JSValueIsStrictEqual(self.context.JSGlobalContextRef, self.JSValueRef, other.JSValueRef);
}

- (BOOL)isEqualWithTypeCoercionToObject:(id)object
{
    JSValue *other = [JSValue valueWithObject:object inContext:self.context];
    JSValueRef exception = NULL;
    BOOL result = JSValueIsEqual(self.context.JSGlobalContextRef, self.JSValueRef,
                                 other.JSValueRef, &exception);
    if (exception)
        [self.context zjs_recordException:exception];
    return result;
}

static JSObjectRef ZJSObjectForValue(JSValue *value)
{
    JSValueRef exception = NULL;
    JSObjectRef object = JSValueToObject(value.context.JSGlobalContextRef,
                                         value.JSValueRef, &exception);
    if (exception) {
        [value.context zjs_recordException:exception];
        return NULL;
    }
    return object;
}

static JSValueRef *ZJSCreateArguments(NSArray *arguments, JSContext *context,
                                      size_t *count)
{
    *count = arguments ? arguments.count : 0;
    if (!*count)
        return NULL;
    JSValueRef *values = calloc(*count, sizeof(JSValueRef));
    if (!values)
        [NSException raise:NSMallocException format:@"Unable to allocate Objective-C bridge arguments"];
    @try {
        for (size_t index = 0; index < *count; ++index)
            values[index] = [JSValue valueWithObject:arguments[index] inContext:context].JSValueRef;
    } @catch (id exception) {
        free(values);
        @throw exception;
    }
    return values;
}

- (JSValue *)callWithArguments:(NSArray *)arguments
{
    JSObjectRef function = ZJSObjectForValue(self);
    if (!function)
        return nil;
    size_t count = 0;
    JSValueRef *values = NULL;
    @try {
        values = ZJSCreateArguments(arguments, self.context, &count);
        JSValueRef exception = NULL;
        JSValueRef result = JSObjectCallAsFunction(self.context.JSGlobalContextRef,
                                                   function, NULL, count, values,
                                                   &exception);
        if (exception) {
            [self.context zjs_recordException:exception];
            return nil;
        }
        return [JSValue valueWithJSValueRef:result inContext:self.context];
    } @finally {
        free(values);
    }
}

- (JSValue *)constructWithArguments:(NSArray *)arguments
{
    JSObjectRef constructor = ZJSObjectForValue(self);
    if (!constructor)
        return nil;
    size_t count = 0;
    JSValueRef *values = NULL;
    @try {
        values = ZJSCreateArguments(arguments, self.context, &count);
        JSValueRef exception = NULL;
        JSObjectRef result = JSObjectCallAsConstructor(self.context.JSGlobalContextRef,
                                                       constructor, count, values,
                                                       &exception);
        if (exception) {
            [self.context zjs_recordException:exception];
            return nil;
        }
        return [JSValue valueWithJSValueRef:result inContext:self.context];
    } @finally {
        free(values);
    }
}

- (JSValue *)invokeMethod:(NSString *)method withArguments:(NSArray *)arguments
{
    JSValue *functionValue = [self valueForProperty:method];
    JSObjectRef function = ZJSObjectForValue(functionValue);
    JSObjectRef thisObject = ZJSObjectForValue(self);
    if (!function || !thisObject)
        return nil;
    size_t count = 0;
    JSValueRef *values = NULL;
    @try {
        values = ZJSCreateArguments(arguments, self.context, &count);
        JSValueRef exception = NULL;
        JSValueRef result = JSObjectCallAsFunction(self.context.JSGlobalContextRef,
                                                   function, thisObject, count, values,
                                                   &exception);
        if (exception) {
            [self.context zjs_recordException:exception];
            return nil;
        }
        return [JSValue valueWithJSValueRef:result inContext:self.context];
    } @finally {
        free(values);
    }
}

- (JSValue *)valueForProperty:(JSValueProperty)property
{
    JSObjectRef object = ZJSObjectForValue(self);
    if (!object)
        return nil;
    JSValue *key = [JSValue valueWithObject:property inContext:self.context];
    JSValueRef exception = NULL;
    JSValueRef result = JSObjectGetPropertyForKey(self.context.JSGlobalContextRef,
                                                  object, key.JSValueRef, &exception);
    if (exception) {
        [self.context zjs_recordException:exception];
        return nil;
    }
    return [JSValue valueWithJSValueRef:result inContext:self.context];
}

- (void)setValue:(id)value forProperty:(JSValueProperty)property
{
    JSObjectRef object = ZJSObjectForValue(self);
    if (!object)
        return;
    JSValue *key = [JSValue valueWithObject:property inContext:self.context];
    JSValue *converted = [JSValue valueWithObject:value inContext:self.context];
    JSValueRef exception = NULL;
    JSObjectSetPropertyForKey(self.context.JSGlobalContextRef, object,
                              key.JSValueRef, converted.JSValueRef,
                              kJSPropertyAttributeNone, &exception);
    if (exception)
        [self.context zjs_recordException:exception];
}

- (BOOL)deleteProperty:(JSValueProperty)property
{
    JSObjectRef object = ZJSObjectForValue(self);
    if (!object)
        return NO;
    JSValue *key = [JSValue valueWithObject:property inContext:self.context];
    JSValueRef exception = NULL;
    BOOL result = JSObjectDeletePropertyForKey(self.context.JSGlobalContextRef,
                                               object, key.JSValueRef, &exception);
    if (exception)
        [self.context zjs_recordException:exception];
    return result;
}

- (BOOL)hasProperty:(JSValueProperty)property
{
    JSObjectRef object = ZJSObjectForValue(self);
    if (!object)
        return NO;
    JSValue *key = [JSValue valueWithObject:property inContext:self.context];
    JSValueRef exception = NULL;
    BOOL result = JSObjectHasPropertyForKey(self.context.JSGlobalContextRef,
                                            object, key.JSValueRef, &exception);
    if (exception)
        [self.context zjs_recordException:exception];
    return result;
}

- (void)defineProperty:(JSValueProperty)property descriptor:(id)descriptor
{
    JSValue *object = self.context.globalObject;
    JSValue *objectConstructor = [object valueForProperty:@"Object"];
    JSValue *defineProperty = [objectConstructor valueForProperty:@"defineProperty"];
    [defineProperty callWithArguments:@[ self, property, descriptor ]];
}

- (JSValue *)valueAtIndex:(NSUInteger)index
{
    JSObjectRef object = ZJSObjectForValue(self);
    if (!object)
        return nil;
    JSValueRef exception = NULL;
    JSValueRef result = JSObjectGetPropertyAtIndex(self.context.JSGlobalContextRef,
                                                   object, (unsigned)index, &exception);
    if (exception) {
        [self.context zjs_recordException:exception];
        return nil;
    }
    return [JSValue valueWithJSValueRef:result inContext:self.context];
}

- (void)setValue:(id)value atIndex:(NSUInteger)index
{
    JSObjectRef object = ZJSObjectForValue(self);
    if (!object)
        return;
    JSValue *converted = [JSValue valueWithObject:value inContext:self.context];
    JSValueRef exception = NULL;
    JSObjectSetPropertyAtIndex(self.context.JSGlobalContextRef, object,
                               (unsigned)index, converted.JSValueRef, &exception);
    if (exception)
        [self.context zjs_recordException:exception];
}

- (JSValue *)objectForKeyedSubscript:(id)key { return [self valueForProperty:key]; }
- (JSValue *)objectAtIndexedSubscript:(NSUInteger)index { return [self valueAtIndex:index]; }
- (void)setObject:(id)object forKeyedSubscript:(id)key { [self setValue:object forProperty:key]; }
- (void)setObject:(id)object atIndexedSubscript:(NSUInteger)index { [self setValue:object atIndex:index]; }

+ (JSValue *)valueWithPoint:(CGPoint)point inContext:(JSContext *)context
{
    JSValue *value = [self valueWithNewObjectInContext:context];
    [value setValue:@(point.x) forProperty:@"x"];
    [value setValue:@(point.y) forProperty:@"y"];
    return value;
}

+ (JSValue *)valueWithRange:(NSRange)range inContext:(JSContext *)context
{
    JSValue *value = [self valueWithNewObjectInContext:context];
    [value setValue:@(range.location) forProperty:@"location"];
    [value setValue:@(range.length) forProperty:@"length"];
    return value;
}

+ (JSValue *)valueWithRect:(CGRect)rect inContext:(JSContext *)context
{
    JSValue *value = [self valueWithNewObjectInContext:context];
    [value setValue:@(rect.origin.x) forProperty:@"x"];
    [value setValue:@(rect.origin.y) forProperty:@"y"];
    [value setValue:@(rect.size.width) forProperty:@"width"];
    [value setValue:@(rect.size.height) forProperty:@"height"];
    return value;
}

+ (JSValue *)valueWithSize:(CGSize)size inContext:(JSContext *)context
{
    JSValue *value = [self valueWithNewObjectInContext:context];
    [value setValue:@(size.width) forProperty:@"width"];
    [value setValue:@(size.height) forProperty:@"height"];
    return value;
}

- (CGPoint)toPoint
{
    return CGPointMake([[self valueForProperty:@"x"] toDouble],
                       [[self valueForProperty:@"y"] toDouble]);
}

- (NSRange)toRange
{
    return NSMakeRange((NSUInteger)[[self valueForProperty:@"location"] toDouble],
                       (NSUInteger)[[self valueForProperty:@"length"] toDouble]);
}

- (CGRect)toRect
{
    return CGRectMake([[self valueForProperty:@"x"] toDouble],
                      [[self valueForProperty:@"y"] toDouble],
                      [[self valueForProperty:@"width"] toDouble],
                      [[self valueForProperty:@"height"] toDouble]);
}

- (CGSize)toSize
{
    return CGSizeMake([[self valueForProperty:@"width"] toDouble],
                      [[self valueForProperty:@"height"] toDouble]);
}

- (JSRelationCondition)compareJSValue:(JSValue *)other
{
    if (other.context.virtualMachine != self.context.virtualMachine)
        [NSException raise:NSInvalidArgumentException format:@"JSValue belongs to a different JSVirtualMachine"];
    JSValueRef exception = NULL;
    JSRelationCondition result = JSValueCompare(self.context.JSGlobalContextRef,
                                                 self.JSValueRef, other.JSValueRef,
                                                 &exception);
    if (exception)
        [self.context zjs_recordException:exception];
    return result;
}

- (JSRelationCondition)compareInt64:(int64_t)other
{
    JSValueRef exception = NULL;
    JSRelationCondition result = JSValueCompareInt64(self.context.JSGlobalContextRef,
                                                      self.JSValueRef, other, &exception);
    if (exception)
        [self.context zjs_recordException:exception];
    return result;
}

- (JSRelationCondition)compareUInt64:(uint64_t)other
{
    JSValueRef exception = NULL;
    JSRelationCondition result = JSValueCompareUInt64(self.context.JSGlobalContextRef,
                                                       self.JSValueRef, other, &exception);
    if (exception)
        [self.context zjs_recordException:exception];
    return result;
}

- (JSRelationCondition)compareDouble:(double)other
{
    JSValueRef exception = NULL;
    JSRelationCondition result = JSValueCompareDouble(self.context.JSGlobalContextRef,
                                                       self.JSValueRef, other, &exception);
    if (exception)
        [self.context zjs_recordException:exception];
    return result;
}

@end
