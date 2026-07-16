#ifndef ZIG_JS_JAVASCRIPTCORE_JSOBJECTREF_H
#define ZIG_JS_JAVASCRIPTCORE_JSOBJECTREF_H

#include <JavaScriptCore/JSValueRef.h>

enum {
    kJSPropertyAttributeNone = 0,
    kJSPropertyAttributeReadOnly = 1 << 1,
    kJSPropertyAttributeDontEnum = 1 << 2,
    kJSPropertyAttributeDontDelete = 1 << 3
};
typedef unsigned JSPropertyAttributes;

enum {
    kJSClassAttributeNone = 0,
    kJSClassAttributeNoAutomaticPrototype = 1 << 1
};
typedef unsigned JSClassAttributes;

typedef void (*JSObjectInitializeCallback)(JSContextRef ctx, JSObjectRef object);
typedef void (*JSObjectFinalizeCallback)(JSObjectRef object);
typedef bool (*JSObjectHasPropertyCallback)(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName);
typedef JSValueRef (*JSObjectGetPropertyCallback)(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName, JSValueRef* exception);
typedef bool (*JSObjectSetPropertyCallback)(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName, JSValueRef value, JSValueRef* exception);
typedef bool (*JSObjectDeletePropertyCallback)(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName, JSValueRef* exception);
typedef void (*JSObjectGetPropertyNamesCallback)(JSContextRef ctx, JSObjectRef object, JSPropertyNameAccumulatorRef propertyNames);
typedef JSValueRef (*JSObjectCallAsFunctionCallback)(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception);
typedef JSObjectRef (*JSObjectCallAsConstructorCallback)(JSContextRef ctx, JSObjectRef constructor, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception);
typedef bool (*JSObjectHasInstanceCallback)(JSContextRef ctx, JSObjectRef constructor, JSValueRef possibleInstance, JSValueRef* exception);
typedef JSValueRef (*JSObjectConvertToTypeCallback)(JSContextRef ctx, JSObjectRef object, JSType type, JSValueRef* exception);

typedef struct {
    const char* name;
    JSObjectGetPropertyCallback getProperty;
    JSObjectSetPropertyCallback setProperty;
    JSPropertyAttributes attributes;
} JSStaticValue;

typedef struct {
    const char* name;
    JSObjectCallAsFunctionCallback callAsFunction;
    JSPropertyAttributes attributes;
} JSStaticFunction;

typedef struct {
    int version;
    JSClassAttributes attributes;
    const char* className;
    JSClassRef parentClass;
    const JSStaticValue* staticValues;
    const JSStaticFunction* staticFunctions;
    JSObjectInitializeCallback initialize;
    JSObjectFinalizeCallback finalize;
    JSObjectHasPropertyCallback hasProperty;
    JSObjectGetPropertyCallback getProperty;
    JSObjectSetPropertyCallback setProperty;
    JSObjectDeletePropertyCallback deleteProperty;
    JSObjectGetPropertyNamesCallback getPropertyNames;
    JSObjectCallAsFunctionCallback callAsFunction;
    JSObjectCallAsConstructorCallback callAsConstructor;
    JSObjectHasInstanceCallback hasInstance;
    JSObjectConvertToTypeCallback convertToType;
} JSClassDefinition;

#ifdef __cplusplus
extern "C" {
#endif

JS_EXPORT extern const JSClassDefinition kJSClassDefinitionEmpty;
JS_EXPORT JSClassRef JSClassCreate(const JSClassDefinition* definition);
JS_EXPORT JSClassRef JSClassRetain(JSClassRef jsClass);
JS_EXPORT void JSClassRelease(JSClassRef jsClass);
JS_EXPORT JSObjectRef JSObjectMake(JSContextRef ctx, JSClassRef jsClass, void* data);
JS_EXPORT JSObjectRef JSObjectMakeFunctionWithCallback(JSContextRef ctx, JSStringRef name, JSObjectCallAsFunctionCallback callAsFunction);
JS_EXPORT JSObjectRef JSObjectMakeConstructor(JSContextRef ctx, JSClassRef jsClass, JSObjectCallAsConstructorCallback callAsConstructor);
JS_EXPORT JSObjectRef JSObjectMakeArray(JSContextRef ctx, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception);
JS_EXPORT JSObjectRef JSObjectMakeDate(JSContextRef ctx, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception);
JS_EXPORT JSObjectRef JSObjectMakeError(JSContextRef ctx, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception);
JS_EXPORT JSObjectRef JSObjectMakeRegExp(JSContextRef ctx, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception);
JS_EXPORT JSObjectRef JSObjectMakeDeferredPromise(JSContextRef ctx, JSObjectRef* resolve, JSObjectRef* reject, JSValueRef* exception);
JS_EXPORT JSObjectRef JSObjectMakeFunction(JSContextRef ctx, JSStringRef name, unsigned parameterCount, const JSStringRef parameterNames[], JSStringRef body, JSStringRef sourceURL, int startingLineNumber, JSValueRef* exception);
JS_EXPORT JSValueRef JSObjectGetPrototype(JSContextRef ctx, JSObjectRef object);
JS_EXPORT void JSObjectSetPrototype(JSContextRef ctx, JSObjectRef object, JSValueRef value);
JS_EXPORT bool JSObjectHasProperty(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName);
JS_EXPORT JSValueRef JSObjectGetProperty(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName, JSValueRef* exception);
JS_EXPORT void JSObjectSetProperty(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName, JSValueRef value, JSPropertyAttributes attributes, JSValueRef* exception);
JS_EXPORT bool JSObjectDeleteProperty(JSContextRef ctx, JSObjectRef object, JSStringRef propertyName, JSValueRef* exception);
JS_EXPORT bool JSObjectHasPropertyForKey(JSContextRef ctx, JSObjectRef object, JSValueRef propertyKey, JSValueRef* exception);
JS_EXPORT JSValueRef JSObjectGetPropertyForKey(JSContextRef ctx, JSObjectRef object, JSValueRef propertyKey, JSValueRef* exception);
JS_EXPORT void JSObjectSetPropertyForKey(JSContextRef ctx, JSObjectRef object, JSValueRef propertyKey, JSValueRef value, JSPropertyAttributes attributes, JSValueRef* exception);
JS_EXPORT bool JSObjectDeletePropertyForKey(JSContextRef ctx, JSObjectRef object, JSValueRef propertyKey, JSValueRef* exception);
JS_EXPORT JSValueRef JSObjectGetPropertyAtIndex(JSContextRef ctx, JSObjectRef object, unsigned propertyIndex, JSValueRef* exception);
JS_EXPORT void JSObjectSetPropertyAtIndex(JSContextRef ctx, JSObjectRef object, unsigned propertyIndex, JSValueRef value, JSValueRef* exception);
JS_EXPORT void* JSObjectGetPrivate(JSObjectRef object);
JS_EXPORT bool JSObjectSetPrivate(JSObjectRef object, void* data);
JS_EXPORT bool JSObjectIsFunction(JSContextRef ctx, JSObjectRef object);
JS_EXPORT JSValueRef JSObjectCallAsFunction(JSContextRef ctx, JSObjectRef object, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception);
JS_EXPORT bool JSObjectIsConstructor(JSContextRef ctx, JSObjectRef object);
JS_EXPORT JSObjectRef JSObjectCallAsConstructor(JSContextRef ctx, JSObjectRef object, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception);
JS_EXPORT JSPropertyNameArrayRef JSObjectCopyPropertyNames(JSContextRef ctx, JSObjectRef object);
JS_EXPORT JSPropertyNameArrayRef JSPropertyNameArrayRetain(JSPropertyNameArrayRef array);
JS_EXPORT void JSPropertyNameArrayRelease(JSPropertyNameArrayRef array);
JS_EXPORT size_t JSPropertyNameArrayGetCount(JSPropertyNameArrayRef array);
JS_EXPORT JSStringRef JSPropertyNameArrayGetNameAtIndex(JSPropertyNameArrayRef array, size_t index);
JS_EXPORT void JSPropertyNameAccumulatorAddName(JSPropertyNameAccumulatorRef accumulator, JSStringRef propertyName);

#ifdef __cplusplus
}
#endif

#endif
