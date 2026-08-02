#ifndef ZIG_JS_OBJC_ABI_DISPATCH_H
#define ZIG_JS_OBJC_ABI_DISPATCH_H

#import <Foundation/Foundation.h>

typedef NS_ENUM(uint32_t, ZJSNativeKind) {
    ZJSNativeVoid,
    ZJSNativeSInt8,
    ZJSNativeUInt8,
    ZJSNativeSInt16,
    ZJSNativeUInt16,
    ZJSNativeSInt32,
    ZJSNativeUInt32,
    ZJSNativeSInt64,
    ZJSNativeUInt64,
    ZJSNativeFloat,
    ZJSNativeDouble,
    ZJSNativePointer,
    ZJSNativePoint,
    ZJSNativeSize,
    ZJSNativeRect,
    ZJSNativeRange,
};

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
    uint8_t raw[32];
} ZJSNativeStorage;

typedef struct {
    ZJSNativeKind kind;
    ZJSNativeStorage value;
} ZJSNativeArgument;

typedef struct {
    void *function;
    const ZJSNativeArgument *arguments;
    size_t argumentCount;
    ZJSNativeKind returnKind;
    void *scratch;
    size_t scratchCapacity;
    ZJSNativeStorage *result;
} ZJSNativeCall;

typedef NS_ENUM(int32_t, ZJSNativeCallStatus) {
    ZJSNativeCallOK = 0,
    ZJSNativeCallInvalidDescriptor = 1,
    ZJSNativeCallUnsupportedArchitecture = 2,
    ZJSNativeCallInsufficientScratch = 3,
};

FOUNDATION_EXPORT ZJSNativeCallStatus ZJSObjCNativeCall(ZJSNativeCall *call);

#endif
