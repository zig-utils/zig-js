#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/runtime.h>
#import <zig-js/Extensions.h>
#include <ffi/ffi.h>
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
@property (nonatomic, strong) NSMapTable<id, NSMutableDictionary<NSValue *, JSValue *> *> *managedReferences;
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
@property (nonatomic, strong) NSHashTable<JSValue *> *objectValues;
@property (nonatomic, strong) NSMapTable<id, JSValue *> *objectiveCValues;
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

@interface ZJSManagedValueState : NSObject
@property (nonatomic, strong) JSValue *weakReference;
@property (nonatomic, strong) JSValue *primitiveValue;
@end

@implementation ZJSManagedValueState
@end

@interface ZJSHostObjectRecord : NSObject
@property (nonatomic, strong) id object;
@property (nonatomic, strong) NSMutableDictionary<NSString *, JSValue *> *methods;
@end

@implementation ZJSHostObjectRecord
@end

@interface ZJSHostMethodRecord : ZJSHostObjectRecord
@property (nonatomic) SEL selector;
@end

@implementation ZJSHostMethodRecord
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

@interface ZJSCallbackState : NSObject
@property (nonatomic, strong) JSContext *context;
@property (nonatomic, strong) JSValue *callee;
@property (nonatomic, strong) JSValue *thisValue;
@property (nonatomic, strong) NSArray<JSValue *> *arguments;
@end

@implementation ZJSCallbackState
@end

static NSString *const ZJSCallbackStateThreadKey = @"org.zig-utils.zig-js.callback-state";

static ZJSCallbackState *ZJSCurrentCallbackState(void)
{
    return NSThread.currentThread.threadDictionary[ZJSCallbackStateThreadKey];
}

static const void *ZJSVirtualMachineStateKey = &ZJSVirtualMachineStateKey;
static const void *ZJSContextStateKey = &ZJSContextStateKey;
static const void *ZJSValueStateKey = &ZJSValueStateKey;
static const void *ZJSManagedValueStateKey = &ZJSManagedValueStateKey;

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

static ZJSManagedValueState *ZJSManagedState(JSManagedValue *value)
{
    return objc_getAssociatedObject(value, ZJSManagedValueStateKey);
}

static NSValue *ZJSObjectiveCIdentityKey(id object);
static JSStringRef ZJSStringCreate(NSString *string);
static NSString *ZJSStringCopy(JSStringRef string);
static JSClassRef ZJSBlockObjectClass(void);
static bool ZJSExportHasProperty(JSContextRef context, JSObjectRef object,
                                 JSStringRef propertyName);
static JSValueRef ZJSExportGetProperty(JSContextRef context, JSObjectRef object,
                                       JSStringRef propertyName,
                                       JSValueRef *exception);
static bool ZJSExportSetProperty(JSContextRef context, JSObjectRef object,
                                 JSStringRef propertyName, JSValueRef value,
                                 JSValueRef *exception);
static void ZJSExportGetPropertyNames(JSContextRef context, JSObjectRef object,
                                      JSPropertyNameAccumulatorRef names);

static void ZJSOpaqueObjectFinalize(JSObjectRef object)
{
    void *privateData = JSObjectGetPrivate(object);
    if (!privateData)
        return;
    JSObjectSetPrivate(object, NULL);
    CFBridgingRelease(privateData);
}

static JSClassRef ZJSOpaqueObjectClass(void)
{
    static JSClassRef jsClass;
    @synchronized([ZJSHostObjectRecord class]) {
        if (!jsClass) {
            JSClassDefinition definition = kJSClassDefinitionEmpty;
            definition.className = "ZJSObjectiveCObject";
            definition.finalize = ZJSOpaqueObjectFinalize;
            definition.hasProperty = ZJSExportHasProperty;
            definition.getProperty = ZJSExportGetProperty;
            definition.setProperty = ZJSExportSetProperty;
            definition.getPropertyNames = ZJSExportGetPropertyNames;
            jsClass = JSClassCreate(&definition);
        }
    }
    return jsClass;
}

static ZJSHostObjectRecord *ZJSHostRecord(JSValue *value)
{
    if (!value.isObject)
        return nil;
    BOOL isHostObject = JSValueIsObjectOfClass(value.context.JSGlobalContextRef,
                                               value.JSValueRef, ZJSOpaqueObjectClass()) ||
        JSValueIsObjectOfClass(value.context.JSGlobalContextRef,
                               value.JSValueRef, ZJSBlockObjectClass());
    if (!isHostObject)
        return nil;
    JSObjectRef object = JSValueToObject(value.context.JSGlobalContextRef,
                                         value.JSValueRef, NULL);
    return (__bridge ZJSHostObjectRecord *)JSObjectGetPrivate(object);
}

enum {
    ZJSBlockHasCopyDispose = 1 << 25,
    ZJSBlockHasSignature = 1 << 30,
};

typedef struct {
    void *isa;
    int flags;
    int reserved;
    void (*invoke)(void *, ...);
    void *descriptor;
} ZJSBlockLiteral;

typedef union {
    int8_t sint8;
    uint8_t uint8;
    int16_t sint16;
    uint16_t uint16;
    int32_t sint32;
    uint32_t uint32;
    int64_t sint64;
    uint64_t uint64;
    float float32;
    double float64;
    void *pointer;
    CGPoint point;
    CGSize size;
    CGRect rect;
    NSRange range;
} ZJSFFIStorage;

static ffi_type *ZJSPointElements[] = { &ffi_type_double, &ffi_type_double, NULL };
static ffi_type *ZJSSizeElements[] = { &ffi_type_double, &ffi_type_double, NULL };
static ffi_type *ZJSRectElements[] = { NULL, NULL, NULL };
static ffi_type *ZJSRangeElements[] = { &ffi_type_uint64, &ffi_type_uint64, NULL };
static ffi_type ZJSPointType = { 0, 0, FFI_TYPE_STRUCT, ZJSPointElements };
static ffi_type ZJSSizeType = { 0, 0, FFI_TYPE_STRUCT, ZJSSizeElements };
static ffi_type ZJSRectType = { 0, 0, FFI_TYPE_STRUCT, ZJSRectElements };
static ffi_type ZJSRangeType = { 0, 0, FFI_TYPE_STRUCT, ZJSRangeElements };

static const char *ZJSSkipTypeQualifiers(const char *type)
{
    while (*type && strchr("rnNoORV", *type))
        ++type;
    return type;
}

static ffi_type *ZJSFFIType(const char *rawType)
{
    const char *type = ZJSSkipTypeQualifiers(rawType);
    switch (*type) {
    case 'v': return &ffi_type_void;
    case 'c': return &ffi_type_sint8;
    case 'C': return &ffi_type_uint8;
    case 's': return &ffi_type_sint16;
    case 'S': return &ffi_type_uint16;
    case 'i': return &ffi_type_sint32;
    case 'I': return &ffi_type_uint32;
    case 'l': return sizeof(long) == 8 ? &ffi_type_sint64 : &ffi_type_sint32;
    case 'L': return sizeof(unsigned long) == 8 ? &ffi_type_uint64 : &ffi_type_uint32;
    case 'q': return &ffi_type_sint64;
    case 'Q': return &ffi_type_uint64;
    case 'f': return &ffi_type_float;
    case 'd': return &ffi_type_double;
    case 'B': return &ffi_type_uint8;
    case '@':
    case '#':
    case ':':
    case '^':
    case '*': return &ffi_type_pointer;
    case '{':
        ZJSRectElements[0] = &ZJSPointType;
        ZJSRectElements[1] = &ZJSSizeType;
        if (!strcmp(type, @encode(CGPoint)))
            return &ZJSPointType;
        if (!strcmp(type, @encode(CGSize)))
            return &ZJSSizeType;
        if (!strcmp(type, @encode(CGRect)))
            return &ZJSRectType;
        if (!strcmp(type, @encode(NSRange)))
            return &ZJSRangeType;
        return NULL;
    default: return NULL;
    }
}

static const char *ZJSBlockSignature(id block)
{
    ZJSBlockLiteral *literal = (__bridge ZJSBlockLiteral *)block;
    if (!(literal->flags & ZJSBlockHasSignature))
        return NULL;
    uint8_t *cursor = literal->descriptor;
    cursor += sizeof(uintptr_t) * 2;
    if (literal->flags & ZJSBlockHasCopyDispose)
        cursor += sizeof(void *) * 2;
    return *(const char **)cursor;
}

static void ZJSPrepareFFIArgument(JSValue *value, const char *rawType,
                                  ZJSFFIStorage *storage,
                                  NSMutableArray *retainedObjects)
{
    const char *type = ZJSSkipTypeQualifiers(rawType);
    switch (*type) {
    case 'c': storage->sint8 = (int8_t)value.toInt32; return;
    case 'C': storage->uint8 = (uint8_t)value.toUInt32; return;
    case 's': storage->sint16 = (int16_t)value.toInt32; return;
    case 'S': storage->uint16 = (uint16_t)value.toUInt32; return;
    case 'i': storage->sint32 = value.toInt32; return;
    case 'I': storage->uint32 = value.toUInt32; return;
    case 'l':
    case 'q': storage->sint64 = value.toInt64; return;
    case 'L':
    case 'Q': storage->uint64 = value.toUInt64; return;
    case 'f': storage->float32 = (float)value.toDouble; return;
    case 'd': storage->float64 = value.toDouble; return;
    case 'B': storage->uint8 = value.toBool; return;
    case '@':
    case '#': {
        id object = value.toObject;
        if (object)
            [retainedObjects addObject:object];
        storage->pointer = (__bridge void *)object;
        return;
    }
    case ':': {
        NSString *selectorName = value.toString;
        storage->pointer = NSSelectorFromString(selectorName);
        return;
    }
    case '{':
        if (!strcmp(type, @encode(CGPoint))) {
            storage->point = value.toPoint;
            return;
        }
        if (!strcmp(type, @encode(CGSize))) {
            storage->size = value.toSize;
            return;
        }
        if (!strcmp(type, @encode(CGRect))) {
            storage->rect = value.toRect;
            return;
        }
        if (!strcmp(type, @encode(NSRange))) {
            storage->range = value.toRange;
            return;
        }
        break;
    }
    [NSException raise:NSInvalidArgumentException
                format:@"Unsupported Objective-C block argument encoding %s", rawType];
}

static JSValue *ZJSValueFromFFIReturn(JSContext *context, const char *rawType,
                                      const ZJSFFIStorage *storage)
{
    const char *type = ZJSSkipTypeQualifiers(rawType);
    switch (*type) {
    case 'v': return [JSValue valueWithUndefinedInContext:context];
    case 'c': return [JSValue valueWithInt32:storage->sint8 inContext:context];
    case 'C': return [JSValue valueWithUInt32:storage->uint8 inContext:context];
    case 's': return [JSValue valueWithInt32:storage->sint16 inContext:context];
    case 'S': return [JSValue valueWithUInt32:storage->uint16 inContext:context];
    case 'i': return [JSValue valueWithInt32:storage->sint32 inContext:context];
    case 'I': return [JSValue valueWithUInt32:storage->uint32 inContext:context];
    case 'l':
    case 'q': return [JSValue valueWithDouble:(double)storage->sint64 inContext:context];
    case 'L':
    case 'Q': return [JSValue valueWithDouble:(double)storage->uint64 inContext:context];
    case 'f': return [JSValue valueWithDouble:storage->float32 inContext:context];
    case 'd': return [JSValue valueWithDouble:storage->float64 inContext:context];
    case 'B': return [JSValue valueWithBool:storage->uint8 inContext:context];
    case '@':
    case '#': return [JSValue valueWithObject:(__bridge id)storage->pointer inContext:context];
    case ':': return [JSValue valueWithObject:NSStringFromSelector((SEL)storage->pointer)
                                     inContext:context];
    case '{':
        if (!strcmp(type, @encode(CGPoint)))
            return [JSValue valueWithPoint:storage->point inContext:context];
        if (!strcmp(type, @encode(CGSize)))
            return [JSValue valueWithSize:storage->size inContext:context];
        if (!strcmp(type, @encode(CGRect)))
            return [JSValue valueWithRect:storage->rect inContext:context];
        if (!strcmp(type, @encode(NSRange)))
            return [JSValue valueWithRange:storage->range inContext:context];
        break;
    }
    [NSException raise:NSInvalidArgumentException
                format:@"Unsupported Objective-C block return encoding %s", rawType];
    return nil;
}

static JSValueRef ZJSBlockCall(JSContextRef contextRef, JSObjectRef functionRef,
                               JSObjectRef thisRef, size_t argumentCount,
                               const JSValueRef arguments[], JSValueRef *exception)
{
    JSContext *context = [JSContext contextWithJSGlobalContextRef:(JSGlobalContextRef)contextRef];
    JSValue *function = [JSValue valueWithJSValueRef:functionRef inContext:context];
    ZJSHostObjectRecord *record = ZJSHostRecord(function);
    id block = record.object;
    const char *signatureText = ZJSBlockSignature(block);
    if (!signatureText)
        return NULL;

    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:signatureText];
    NSUInteger nativeCount = signature.numberOfArguments;
    ffi_type **argumentTypes = calloc(nativeCount, sizeof(ffi_type *));
    void **argumentPointers = calloc(nativeCount, sizeof(void *));
    ZJSFFIStorage *argumentStorage = calloc(nativeCount, sizeof(ZJSFFIStorage));
    if (!argumentTypes || !argumentPointers || !argumentStorage) {
        free(argumentTypes);
        free(argumentPointers);
        free(argumentStorage);
        return NULL;
    }

    NSMutableArray *retainedObjects = [NSMutableArray array];
    NSMutableArray<JSValue *> *callbackArguments = [NSMutableArray array];
    JSValue *previousException = context.exception;
    ZJSCallbackState *previousState = ZJSCurrentCallbackState();
    NSMutableDictionary *threadDictionary = NSThread.currentThread.threadDictionary;
    JSValue *result = nil;
    @try {
        argumentTypes[0] = &ffi_type_pointer;
        argumentStorage[0].pointer = (__bridge void *)block;
        argumentPointers[0] = &argumentStorage[0];
        for (NSUInteger index = 1; index < nativeCount; ++index) {
            JSValue *value = index - 1 < argumentCount
                ? [JSValue valueWithJSValueRef:arguments[index - 1] inContext:context]
                : [JSValue valueWithUndefinedInContext:context];
            [callbackArguments addObject:value];
            const char *type = [signature getArgumentTypeAtIndex:index];
            argumentTypes[index] = ZJSFFIType(type);
            if (!argumentTypes[index])
                [NSException raise:NSInvalidArgumentException
                            format:@"Unsupported Objective-C block argument encoding %s", type];
            ZJSPrepareFFIArgument(value, type, &argumentStorage[index], retainedObjects);
            argumentPointers[index] = &argumentStorage[index];
        }
        ffi_type *returnType = ZJSFFIType(signature.methodReturnType);
        if (!returnType)
            [NSException raise:NSInvalidArgumentException
                        format:@"Unsupported Objective-C block return encoding %s",
                               signature.methodReturnType];
        ffi_cif callInterface;
        if (ffi_prep_cif(&callInterface, FFI_DEFAULT_ABI, (unsigned)nativeCount,
                         returnType, argumentTypes) != FFI_OK)
            [NSException raise:NSInvalidArgumentException format:@"Unable to prepare Objective-C block call"];

        ZJSCallbackState *callbackState = [ZJSCallbackState new];
        callbackState.context = context;
        callbackState.callee = function;
        callbackState.thisValue = thisRef
            ? [JSValue valueWithJSValueRef:thisRef inContext:context]
            : [JSValue valueWithUndefinedInContext:context];
        callbackState.arguments = callbackArguments;
        context.exception = nil;
        threadDictionary[ZJSCallbackStateThreadKey] = callbackState;

        ZJSFFIStorage returnStorage = { 0 };
        ZJSBlockLiteral *literal = (__bridge ZJSBlockLiteral *)block;
        ffi_call(&callInterface, FFI_FN(literal->invoke), &returnStorage,
                 argumentPointers);
        if (context.exception) {
            if (exception)
                *exception = context.exception.JSValueRef;
        } else {
            result = ZJSValueFromFFIReturn(context, signature.methodReturnType,
                                           &returnStorage);
        }
    } @catch (NSException *nativeException) {
        JSValue *error = [JSValue valueWithNewErrorFromMessage:nativeException.reason
                                                     inContext:context];
        if (exception)
            *exception = error.JSValueRef;
    } @finally {
        context.exception = previousException;
        if (previousState)
            threadDictionary[ZJSCallbackStateThreadKey] = previousState;
        else
            [threadDictionary removeObjectForKey:ZJSCallbackStateThreadKey];
        free(argumentTypes);
        free(argumentPointers);
        free(argumentStorage);
    }
    return result.JSValueRef;
}

static JSClassRef ZJSBlockObjectClass(void)
{
    static JSClassRef jsClass;
    @synchronized([ZJSHostObjectRecord class]) {
        if (!jsClass) {
            JSClassDefinition definition = kJSClassDefinitionEmpty;
            definition.className = "ZJSObjectiveCBlock";
            definition.finalize = ZJSOpaqueObjectFinalize;
            definition.callAsFunction = ZJSBlockCall;
            jsClass = JSClassCreate(&definition);
        }
    }
    return jsClass;
}

static BOOL ZJSIsBlock(id object)
{
    Class objectClass = object_getClass(object);
    const char *name = objectClass ? class_getName(objectClass) : NULL;
    return name && strstr(name, "Block");
}

static void ZJSAddExportProtocol(Protocol *protocol,
                                 NSMutableArray<Protocol *> *protocols)
{
    if (protocol != @protocol(JSExport) &&
        protocol_conformsToProtocol(protocol, @protocol(JSExport)) &&
        ![protocols containsObject:protocol])
        [protocols addObject:protocol];
    unsigned count = 0;
    Protocol *__unsafe_unretained *adopted = protocol_copyProtocolList(protocol, &count);
    for (unsigned index = 0; index < count; ++index)
        ZJSAddExportProtocol(adopted[index], protocols);
    free(adopted);
}

static NSArray<Protocol *> *ZJSExportProtocols(id target)
{
    NSMutableArray<Protocol *> *result = [NSMutableArray array];
    Class targetClass = object_isClass(target) ? target : [target class];
    for (Class current = targetClass; current; current = class_getSuperclass(current)) {
        unsigned count = 0;
        Protocol *__unsafe_unretained *protocols = class_copyProtocolList(current, &count);
        for (unsigned index = 0; index < count; ++index)
            ZJSAddExportProtocol(protocols[index], result);
        free(protocols);
    }
    return result;
}

static NSString *ZJSJavaScriptNameForSelector(SEL selector)
{
    NSArray<NSString *> *parts = [NSStringFromSelector(selector)
        componentsSeparatedByString:@":"];
    NSMutableString *result = [parts.firstObject mutableCopy];
    for (NSUInteger index = 1; index + 1 < parts.count; ++index) {
        NSString *part = parts[index];
        if (!part.length)
            continue;
        [result appendString:[[part substringToIndex:1] uppercaseString]];
        [result appendString:[part substringFromIndex:1]];
    }
    return result;
}

static objc_property_t ZJSExportedProperty(id target, NSString *name)
{
    if (object_isClass(target))
        return NULL;
    for (Protocol *protocol in ZJSExportProtocols(target)) {
        unsigned count = 0;
        objc_property_t *properties = protocol_copyPropertyList(protocol, &count);
        for (unsigned index = 0; index < count; ++index) {
            objc_property_t property = properties[index];
            if ([name isEqualToString:@(property_getName(property))]) {
                free(properties);
                return property;
            }
        }
        free(properties);
    }
    return NULL;
}

static BOOL ZJSPropertyIsReadonly(objc_property_t property)
{
    const char *attributes = property_getAttributes(property);
    return attributes && (strstr(attributes, ",R") != NULL);
}

static SEL ZJSPropertyGetter(objc_property_t property)
{
    const char *attributes = property_getAttributes(property);
    const char *custom = attributes ? strstr(attributes, ",G") : NULL;
    if (!custom)
        return sel_registerName(property_getName(property));
    custom += 2;
    const char *end = strchr(custom, ',');
    size_t length = end ? (size_t)(end - custom) : strlen(custom);
    char *name = strndup(custom, length);
    SEL selector = sel_registerName(name);
    free(name);
    return selector;
}

static SEL ZJSPropertySetter(objc_property_t property)
{
    if (ZJSPropertyIsReadonly(property))
        return NULL;
    const char *attributes = property_getAttributes(property);
    const char *custom = attributes ? strstr(attributes, ",S") : NULL;
    if (custom) {
        custom += 2;
        const char *end = strchr(custom, ',');
        size_t length = end ? (size_t)(end - custom) : strlen(custom);
        char *name = strndup(custom, length);
        SEL selector = sel_registerName(name);
        free(name);
        return selector;
    }
    NSString *propertyName = @(property_getName(property));
    NSString *setterName = [NSString stringWithFormat:@"set%@%@:",
                                                       [[propertyName substringToIndex:1] uppercaseString],
                                                       [propertyName substringFromIndex:1]];
    return NSSelectorFromString(setterName);
}

static BOOL ZJSSelectorIsPropertyAccessor(id target, SEL selector)
{
    if (object_isClass(target))
        return NO;
    for (Protocol *protocol in ZJSExportProtocols(target)) {
        unsigned count = 0;
        objc_property_t *properties = protocol_copyPropertyList(protocol, &count);
        for (unsigned index = 0; index < count; ++index) {
            BOOL matches = selector == ZJSPropertyGetter(properties[index]) ||
                selector == ZJSPropertySetter(properties[index]);
            if (matches) {
                free(properties);
                return YES;
            }
        }
        free(properties);
    }
    return NO;
}

static SEL ZJSExportedSelector(id target, NSString *name)
{
    BOOL instanceMethod = !object_isClass(target);
    for (Protocol *protocol in ZJSExportProtocols(target)) {
        for (NSUInteger requiredIndex = 0; requiredIndex < 2; ++requiredIndex) {
            BOOL required = requiredIndex == 0;
            unsigned count = 0;
            struct objc_method_description *methods =
                protocol_copyMethodDescriptionList(protocol, required,
                                                   instanceMethod, &count);
            for (unsigned index = 0; index < count; ++index) {
                SEL selector = methods[index].name;
                if (!selector || ZJSSelectorIsPropertyAccessor(target, selector))
                    continue;
                if ([name isEqualToString:ZJSJavaScriptNameForSelector(selector)] &&
                    [target respondsToSelector:selector]) {
                    free(methods);
                    return selector;
                }
            }
            free(methods);
        }
    }
    return NULL;
}

static JSValue *ZJSInvokeSelector(JSContext *context, id target, SEL selector,
                                  JSValue *callee, JSValue *thisValue,
                                  NSArray<JSValue *> *arguments,
                                  JSValueRef *exception)
{
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature)
        return nil;
    NSUInteger nativeCount = signature.numberOfArguments;
    ffi_type **argumentTypes = calloc(nativeCount, sizeof(ffi_type *));
    void **argumentPointers = calloc(nativeCount, sizeof(void *));
    ZJSFFIStorage *argumentStorage = calloc(nativeCount, sizeof(ZJSFFIStorage));
    if (!argumentTypes || !argumentPointers || !argumentStorage) {
        free(argumentTypes);
        free(argumentPointers);
        free(argumentStorage);
        return nil;
    }

    NSMutableArray *retainedObjects = [NSMutableArray array];
    JSValue *previousException = context.exception;
    ZJSCallbackState *previousState = ZJSCurrentCallbackState();
    NSMutableDictionary *threadDictionary = NSThread.currentThread.threadDictionary;
    JSValue *result = nil;
    @try {
        argumentTypes[0] = &ffi_type_pointer;
        argumentStorage[0].pointer = (__bridge void *)target;
        argumentPointers[0] = &argumentStorage[0];
        argumentTypes[1] = &ffi_type_pointer;
        argumentStorage[1].pointer = selector;
        argumentPointers[1] = &argumentStorage[1];
        for (NSUInteger index = 2; index < nativeCount; ++index) {
            JSValue *value = index - 2 < arguments.count
                ? arguments[index - 2]
                : [JSValue valueWithUndefinedInContext:context];
            const char *type = [signature getArgumentTypeAtIndex:index];
            argumentTypes[index] = ZJSFFIType(type);
            if (!argumentTypes[index])
                [NSException raise:NSInvalidArgumentException
                            format:@"Unsupported JSExport argument encoding %s", type];
            ZJSPrepareFFIArgument(value, type, &argumentStorage[index], retainedObjects);
            argumentPointers[index] = &argumentStorage[index];
        }
        ffi_type *returnType = ZJSFFIType(signature.methodReturnType);
        if (!returnType)
            [NSException raise:NSInvalidArgumentException
                        format:@"Unsupported JSExport return encoding %s",
                               signature.methodReturnType];
        ffi_cif callInterface;
        if (ffi_prep_cif(&callInterface, FFI_DEFAULT_ABI, (unsigned)nativeCount,
                         returnType, argumentTypes) != FFI_OK)
            [NSException raise:NSInvalidArgumentException format:@"Unable to prepare JSExport call"];

        ZJSCallbackState *callbackState = [ZJSCallbackState new];
        callbackState.context = context;
        callbackState.callee = callee;
        callbackState.thisValue = thisValue;
        callbackState.arguments = arguments;
        context.exception = nil;
        threadDictionary[ZJSCallbackStateThreadKey] = callbackState;

        ZJSFFIStorage returnStorage = { 0 };
        IMP implementation = [target methodForSelector:selector];
        ffi_call(&callInterface, FFI_FN(implementation), &returnStorage,
                 argumentPointers);
        if (context.exception) {
            if (exception)
                *exception = context.exception.JSValueRef;
        } else {
            result = ZJSValueFromFFIReturn(context, signature.methodReturnType,
                                           &returnStorage);
        }
    } @catch (NSException *nativeException) {
        JSValue *error = [JSValue valueWithNewErrorFromMessage:nativeException.reason
                                                     inContext:context];
        if (exception)
            *exception = error.JSValueRef;
    } @finally {
        context.exception = previousException;
        if (previousState)
            threadDictionary[ZJSCallbackStateThreadKey] = previousState;
        else
            [threadDictionary removeObjectForKey:ZJSCallbackStateThreadKey];
        free(argumentTypes);
        free(argumentPointers);
        free(argumentStorage);
    }
    return result;
}

static JSValueRef ZJSMethodCall(JSContextRef contextRef, JSObjectRef functionRef,
                                JSObjectRef thisRef, size_t argumentCount,
                                const JSValueRef arguments[],
                                JSValueRef *exception)
{
    JSContext *context = [JSContext contextWithJSGlobalContextRef:(JSGlobalContextRef)contextRef];
    ZJSHostMethodRecord *record = (__bridge ZJSHostMethodRecord *)JSObjectGetPrivate(functionRef);
    JSValue *callee = [JSValue valueWithJSValueRef:functionRef inContext:context];
    JSValue *thisValue = [JSValue valueWithJSValueRef:thisRef inContext:context];
    NSMutableArray<JSValue *> *values = [NSMutableArray arrayWithCapacity:argumentCount];
    for (size_t index = 0; index < argumentCount; ++index)
        [values addObject:[JSValue valueWithJSValueRef:arguments[index]
                                              inContext:context]];
    return ZJSInvokeSelector(context, record.object, record.selector, callee,
                             thisValue, values, exception).JSValueRef;
}

static JSClassRef ZJSMethodObjectClass(void)
{
    static JSClassRef jsClass;
    @synchronized([ZJSHostMethodRecord class]) {
        if (!jsClass) {
            JSClassDefinition definition = kJSClassDefinitionEmpty;
            definition.className = "ZJSObjectiveCMethod";
            definition.finalize = ZJSOpaqueObjectFinalize;
            definition.callAsFunction = ZJSMethodCall;
            jsClass = JSClassCreate(&definition);
        }
    }
    return jsClass;
}

static JSValue *ZJSMethodValue(JSContext *context, ZJSHostObjectRecord *hostRecord,
                               NSString *name, SEL selector)
{
    JSValue *existing = hostRecord.methods[name];
    if (existing)
        return existing;
    ZJSHostMethodRecord *record = [ZJSHostMethodRecord new];
    record.object = hostRecord.object;
    record.selector = selector;
    void *privateData = (void *)CFBridgingRetain(record);
    JSObjectRef functionRef = JSObjectMake(context.JSGlobalContextRef,
                                           ZJSMethodObjectClass(), privateData);
    if (!functionRef) {
        CFBridgingRelease(privateData);
        return nil;
    }
    JSValue *function = [context.globalObject valueForProperty:@"Function"];
    JSValue *prototype = [function valueForProperty:@"prototype"];
    JSObjectSetPrototype(context.JSGlobalContextRef, functionRef,
                         prototype.JSValueRef);
    JSValue *result = [JSValue valueWithJSValueRef:functionRef inContext:context];
    if (!hostRecord.methods)
        hostRecord.methods = [NSMutableDictionary dictionary];
    hostRecord.methods[name] = result;
    return result;
}

static bool ZJSExportHasProperty(JSContextRef contextRef, JSObjectRef objectRef,
                                 JSStringRef propertyName)
{
    JSContext *context = [JSContext contextWithJSGlobalContextRef:(JSGlobalContextRef)contextRef];
    JSValue *object = [JSValue valueWithJSValueRef:objectRef inContext:context];
    id target = ZJSHostRecord(object).object;
    NSString *name = ZJSStringCopy(propertyName);
    return ZJSExportedProperty(target, name) != NULL ||
        ZJSExportedSelector(target, name) != NULL;
}

static JSValueRef ZJSExportGetProperty(JSContextRef contextRef, JSObjectRef objectRef,
                                       JSStringRef propertyName,
                                       JSValueRef *exception)
{
    JSContext *context = [JSContext contextWithJSGlobalContextRef:(JSGlobalContextRef)contextRef];
    JSValue *object = [JSValue valueWithJSValueRef:objectRef inContext:context];
    ZJSHostObjectRecord *record = ZJSHostRecord(object);
    NSString *name = ZJSStringCopy(propertyName);
    objc_property_t property = ZJSExportedProperty(record.object, name);
    if (property) {
        JSValue *result = ZJSInvokeSelector(context, record.object,
                                            ZJSPropertyGetter(property), nil,
                                            object, @[], exception);
        return result.JSValueRef;
    }
    SEL selector = ZJSExportedSelector(record.object, name);
    if (!selector)
        return NULL;
    return ZJSMethodValue(context, record, name, selector).JSValueRef;
}

static bool ZJSExportSetProperty(JSContextRef contextRef, JSObjectRef objectRef,
                                 JSStringRef propertyName, JSValueRef valueRef,
                                 JSValueRef *exception)
{
    JSContext *context = [JSContext contextWithJSGlobalContextRef:(JSGlobalContextRef)contextRef];
    JSValue *object = [JSValue valueWithJSValueRef:objectRef inContext:context];
    ZJSHostObjectRecord *record = ZJSHostRecord(object);
    NSString *name = ZJSStringCopy(propertyName);
    objc_property_t property = ZJSExportedProperty(record.object, name);
    SEL setter = property ? ZJSPropertySetter(property) : NULL;
    if (!setter)
        return false;
    JSValue *value = [JSValue valueWithJSValueRef:valueRef inContext:context];
    ZJSInvokeSelector(context, record.object, setter, nil, object,
                      @[ value ], exception);
    return exception == NULL || *exception == NULL;
}

static void ZJSExportGetPropertyNames(JSContextRef contextRef,
                                      JSObjectRef objectRef,
                                      JSPropertyNameAccumulatorRef names)
{
    JSContext *context = [JSContext contextWithJSGlobalContextRef:(JSGlobalContextRef)contextRef];
    JSValue *object = [JSValue valueWithJSValueRef:objectRef inContext:context];
    id target = ZJSHostRecord(object).object;
    BOOL instanceMethod = !object_isClass(target);
    NSMutableSet<NSString *> *published = [NSMutableSet set];
    for (Protocol *protocol in ZJSExportProtocols(target)) {
        if (instanceMethod) {
            unsigned propertyCount = 0;
            objc_property_t *properties = protocol_copyPropertyList(protocol,
                                                                     &propertyCount);
            for (unsigned index = 0; index < propertyCount; ++index)
                [published addObject:@(property_getName(properties[index]))];
            free(properties);
        }
        for (NSUInteger requiredIndex = 0; requiredIndex < 2; ++requiredIndex) {
            unsigned methodCount = 0;
            struct objc_method_description *methods =
                protocol_copyMethodDescriptionList(protocol, requiredIndex == 0,
                                                   instanceMethod, &methodCount);
            for (unsigned index = 0; index < methodCount; ++index) {
                SEL selector = methods[index].name;
                if (selector && !ZJSSelectorIsPropertyAccessor(target, selector))
                    [published addObject:ZJSJavaScriptNameForSelector(selector)];
            }
            free(methods);
        }
    }
    for (NSString *name in published) {
        JSStringRef string = ZJSStringCreate(name);
        JSPropertyNameAccumulatorAddName(names, string);
        JSStringRelease(string);
    }
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
    state.managedReferences = [NSMapTable weakToStrongObjectsMapTable];
    if (!state.group)
        return nil;
    objc_setAssociatedObject(self, ZJSVirtualMachineStateKey, state,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized([JSVirtualMachine class]) {
        [ZJSVirtualMachines() setObject:self forKey:ZJSPointerKey(state.group)];
    }
    return self;
}

- (void)addManagedReference:(id)object withOwner:(id)owner
{
    if (!object || !owner)
        return;
    JSValue *value = nil;
    if ([object isKindOfClass:[JSManagedValue class]])
        value = [object value];
    else if ([object isKindOfClass:[JSValue class]])
        value = object;
    if (!value)
        return;
    if (value.context.virtualMachine != self)
        [NSException raise:NSInvalidArgumentException format:@"Managed JSValue belongs to a different JSVirtualMachine"];
    @synchronized(self) {
        ZJSVirtualMachineState *state = ZJSVMState(self);
        NSMutableDictionary *references = [state.managedReferences objectForKey:owner];
        if (!references) {
            references = [NSMutableDictionary dictionary];
            [state.managedReferences setObject:references forKey:owner];
        }
        references[ZJSObjectiveCIdentityKey(object)] = value;
    }
}

- (void)removeManagedReference:(id)object withOwner:(id)owner
{
    if (!object || !owner)
        return;
    @synchronized(self) {
        ZJSVirtualMachineState *state = ZJSVMState(self);
        NSMutableDictionary *references = [state.managedReferences objectForKey:owner];
        [references removeObjectForKey:ZJSObjectiveCIdentityKey(object)];
        if (references.count == 0)
            [state.managedReferences removeObjectForKey:owner];
    }
}

@end

@implementation JSManagedValue

+ (JSManagedValue *)managedValueWithValue:(JSValue *)value
{
    return [[self alloc] initWithValue:value];
}

+ (JSManagedValue *)managedValueWithValue:(JSValue *)value andOwner:(id)owner
{
    JSManagedValue *managed = [[self alloc] initWithValue:value];
    [value.context.virtualMachine addManagedReference:managed withOwner:owner];
    return managed;
}

- (instancetype)initWithValue:(JSValue *)value
{
    self = [super init];
    if (!self || !value)
        return nil;
    ZJSManagedValueState *state = [ZJSManagedValueState new];
    if (value.isObject) {
        JSValue *constructor = [value.context.globalObject valueForProperty:@"WeakRef"];
        state.weakReference = [constructor constructWithArguments:@[ value ]];
        if (!state.weakReference)
            return nil;
    } else {
        state.primitiveValue = value;
    }
    objc_setAssociatedObject(self, ZJSManagedValueStateKey, state,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return self;
}

- (JSValue *)value
{
    ZJSManagedValueState *state = ZJSManagedState(self);
    if (state.primitiveValue)
        return state.primitiveValue;
    JSValue *value = [state.weakReference invokeMethod:@"deref" withArguments:nil];
    return value.isUndefined ? nil : value;
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

+ (JSContext *)currentContext { return ZJSCurrentCallbackState().context; }
+ (JSValue *)currentCallee { return ZJSCurrentCallbackState().callee; }
+ (JSValue *)currentThis { return ZJSCurrentCallbackState().thisValue; }
+ (NSArray *)currentArguments { return ZJSCurrentCallbackState().arguments; }

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
    state.objectValues = [NSHashTable weakObjectsHashTable];
    state.objectiveCValues = [NSMapTable
        mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                  valueOptions:NSPointerFunctionsWeakMemory];
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
    ZJSContextState *state = ZJSCtxState(context);
    JSValue *existing = [state.values objectForKey:ZJSPointerKey(value)];
    if (existing)
        return existing;
    if (JSValueIsObject(context.JSGlobalContextRef, value)) {
        for (JSValue *candidate in state.objectValues) {
            if (JSValueIsStrictEqual(context.JSGlobalContextRef,
                                     value, candidate.JSValueRef)) {
                [state.values setObject:candidate forKey:ZJSPointerKey(value)];
                return candidate;
            }
        }
    }
    JSValue *result = [[JSValue alloc] zjs_initWithValue:value context:context];
    if (result.isObject)
        [state.objectValues addObject:result];
    return result;
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

+ (JSValue *)valueWithNewPromiseInContext:(JSContext *)context
                             fromExecutor:(void (^)(JSValue *, JSValue *))callback
{
    if (!context || !callback)
        return nil;
    JSObjectRef resolveRef = NULL;
    JSObjectRef rejectRef = NULL;
    JSValueRef exception = NULL;
    JSObjectRef promiseRef = JSObjectMakeDeferredPromise(context.JSGlobalContextRef,
                                                         &resolveRef, &rejectRef,
                                                         &exception);
    if (exception) {
        [context zjs_recordException:exception];
        return nil;
    }

    JSValue *promise = [self valueWithJSValueRef:promiseRef inContext:context];
    JSValue *resolve = [self valueWithJSValueRef:resolveRef inContext:context];
    JSValue *reject = [self valueWithJSValueRef:rejectRef inContext:context];
    NSMutableDictionary *threadDictionary = NSThread.currentThread.threadDictionary;
    ZJSCallbackState *previousState = threadDictionary[ZJSCallbackStateThreadKey];
    ZJSCallbackState *callbackState = [ZJSCallbackState new];
    callbackState.context = context;
    callbackState.thisValue = promise;
    callbackState.arguments = @[ resolve, reject ];

    JSValue *previousException = context.exception;
    context.exception = nil;
    @try {
        threadDictionary[ZJSCallbackStateThreadKey] = callbackState;
        callback(resolve, reject);
    } @catch (NSException *nativeException) {
        context.exception = [self valueWithNewErrorFromMessage:nativeException.reason
                                                     inContext:context];
    } @finally {
        if (previousState)
            threadDictionary[ZJSCallbackStateThreadKey] = previousState;
        else
            [threadDictionary removeObjectForKey:ZJSCallbackStateThreadKey];
    }

    JSValue *callbackException = context.exception;
    context.exception = previousException;
    if (callbackException)
        [reject callWithArguments:@[ callbackException ]];
    return promise;
}

+ (JSValue *)valueWithNewPromiseResolvedWithResult:(id)result inContext:(JSContext *)context
{
    return [self valueWithNewPromiseInContext:context
                                 fromExecutor:^(JSValue *resolve, JSValue *reject) {
                                     (void)reject;
                                     JSValue *converted = [self valueWithObject:result inContext:context];
                                     [resolve callWithArguments:@[ converted ]];
                                 }];
}

+ (JSValue *)valueWithNewPromiseRejectedWithReason:(id)reason inContext:(JSContext *)context
{
    return [self valueWithNewPromiseInContext:context
                                 fromExecutor:^(JSValue *resolve, JSValue *reject) {
                                     (void)resolve;
                                     JSValue *converted = [self valueWithObject:reason inContext:context];
                                     [reject callWithArguments:@[ converted ]];
                                 }];
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
    ZJSContextState *contextState = ZJSCtxState(context);
    JSValue *existing = [contextState.objectiveCValues objectForKey:object];
    if (existing)
        return existing;
    ZJSHostObjectRecord *record = [ZJSHostObjectRecord new];
    record.object = object;
    void *privateData = (void *)CFBridgingRetain(record);
    BOOL isBlock = ZJSIsBlock(object);
    JSClassRef wrapperClass = isBlock
        ? ZJSBlockObjectClass()
        : ZJSOpaqueObjectClass();
    JSObjectRef wrapped = JSObjectMake(context.JSGlobalContextRef,
                                       wrapperClass, privateData);
    if (!wrapped) {
        CFBridgingRelease(privateData);
        return nil;
    }
    if (isBlock) {
        JSValue *function = [context.globalObject valueForProperty:@"Function"];
        JSValue *prototype = [function valueForProperty:@"prototype"];
        JSObjectSetPrototype(context.JSGlobalContextRef, wrapped,
                             prototype.JSValueRef);
    }
    JSValue *result = [JSValue valueWithJSValueRef:wrapped inContext:context];
    [contextState.objectiveCValues setObject:result forKey:object];
    return result;
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
    ZJSHostObjectRecord *hostRecord = ZJSHostRecord(value);
    if (hostRecord)
        return hostRecord.object;
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
