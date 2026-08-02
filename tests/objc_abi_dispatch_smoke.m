#import <Foundation/Foundation.h>

#include "objc_abi_dispatch.h"

_Static_assert(sizeof(ZJSNativeStorage) == 32, "storage size");
_Static_assert(_Alignof(ZJSNativeStorage) == 8, "storage alignment");
_Static_assert(offsetof(ZJSNativeArgument, value) == 8, "argument value offset");
_Static_assert(sizeof(ZJSNativeArgument) == 40, "argument size");
_Static_assert(offsetof(ZJSNativeCall, returnKind) == 24, "return kind offset");
_Static_assert(offsetof(ZJSNativeCall, scratch) == 32, "scratch offset");
_Static_assert(offsetof(ZJSNativeCall, result) == 48, "result offset");
_Static_assert(sizeof(ZJSNativeCall) == 56, "call size");

static ZJSNativeCallStatus invoke(void *function, ZJSNativeKind returnKind,
                                  ZJSNativeArgument *arguments, size_t count,
                                  ZJSNativeStorage *result, void *scratch,
                                  size_t scratchCapacity)
{
    ZJSNativeCall call = {
        .function = function,
        .arguments = arguments,
        .argumentCount = count,
        .returnKind = returnKind,
        .scratch = scratch,
        .scratchCapacity = scratchCapacity,
        .result = result,
    };
    return ZJSObjCNativeCall(&call);
}

typedef struct {
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
} ScalarObservation;

static ScalarObservation scalarObservation;

static uint64_t observeScalars(int8_t sint8, uint8_t uint8, int16_t sint16,
                               uint16_t uint16, int32_t sint32, uint32_t uint32,
                               int64_t sint64, uint64_t uint64, float float32,
                               double float64, void *pointer)
{
    scalarObservation = (ScalarObservation){ sint8, uint8, sint16, uint16,
        sint32, uint32, sint64, uint64, float32, float64, pointer };
    return 0x4630cafeULL;
}

static uint64_t sumTenIntegers(uint64_t a, uint64_t b, uint64_t c, uint64_t d,
                               uint64_t e, uint64_t f, uint64_t g, uint64_t h,
                               uint64_t i, uint64_t j)
{
    return a + b + c + d + e + f + g + h + i + j;
}

static double sumTenDoubles(double a, double b, double c, double d, double e,
                            double f, double g, double h, double i, double j)
{
    return a + b + c + d + e + f + g + h + i + j;
}

static CGPoint pointAfterSevenDoubles(double a, double b, double c, double d,
                                      double e, double f, double g, CGPoint point,
                                      double tail)
{
    return CGPointMake(point.x + a + c + e + g,
                       point.y + b + d + f + tail);
}

static NSRange rangeAfterSevenIntegers(uint64_t a, uint64_t b, uint64_t c,
                                       uint64_t d, uint64_t e, uint64_t f,
                                       uint64_t g, NSRange range, uint64_t tail)
{
    return NSMakeRange(range.location + a + c + e + g,
                       range.length + b + d + f + tail);
}

static CGRect transformRect(CGRect rect, uint64_t delta)
{
    return CGRectMake(rect.origin.x + delta, rect.origin.y - delta,
                      rect.size.width * 2, rect.size.height * 3);
}

static void *echoPointer(void *pointer)
{
    return pointer;
}

static uint64_t addTwo(uint64_t left, uint64_t right)
{
    return left + right;
}

static uint64_t reenterDispatcher(uint64_t value)
{
    ZJSNativeArgument arguments[2] = { 0 };
    arguments[0].kind = ZJSNativeUInt64;
    arguments[0].value.uint64 = value;
    arguments[1].kind = ZJSNativeUInt64;
    arguments[1].value.uint64 = 2;
    ZJSNativeStorage result = { 0 };
    uint8_t scratch[128] = { 0 };
    if (invoke((void *)addTwo, ZJSNativeUInt64, arguments, 2, &result,
               scratch, sizeof(scratch)) != ZJSNativeCallOK)
        return UINT64_MAX;
    return result.uint64 + 40;
}

static BOOL insufficientScratchTargetCalled = NO;

static uint64_t insufficientScratchTarget(uint64_t a, uint64_t b, uint64_t c,
                                          uint64_t d, uint64_t e, uint64_t f,
                                          uint64_t g, uint64_t h, uint64_t i)
{
    insufficientScratchTargetCalled = YES;
    return a + b + c + d + e + f + g + h + i;
}

static void throwNativeException(void)
{
    [NSException raise:NSInvalidArgumentException format:@"owned-dispatch-exception"];
}

static int check(BOOL condition, int code)
{
    if (!condition)
        fprintf(stderr, "objc abi dispatcher check %d failed\n", code);
    return condition ? 0 : code;
}

int main(void)
{
    @autoreleasepool {
        uint8_t scratch[2048] = { 0 };
        ZJSNativeStorage result = { 0 };

        ZJSNativeArgument scalars[11] = { 0 };
        scalars[0].kind = ZJSNativeSInt8; scalars[0].value.sint8 = -8;
        scalars[1].kind = ZJSNativeUInt8; scalars[1].value.uint8 = 18;
        scalars[2].kind = ZJSNativeSInt16; scalars[2].value.sint16 = -1600;
        scalars[3].kind = ZJSNativeUInt16; scalars[3].value.uint16 = 65000;
        scalars[4].kind = ZJSNativeSInt32; scalars[4].value.sint32 = -320000;
        scalars[5].kind = ZJSNativeUInt32; scalars[5].value.uint32 = 4200000000U;
        scalars[6].kind = ZJSNativeSInt64; scalars[6].value.sint64 = -64000000000LL;
        scalars[7].kind = ZJSNativeUInt64; scalars[7].value.uint64 = 0xfedcba9876543210ULL;
        scalars[8].kind = ZJSNativeFloat; scalars[8].value.float32 = 1.25f;
        scalars[9].kind = ZJSNativeDouble; scalars[9].value.float64 = -9.5;
        scalars[10].kind = ZJSNativePointer; scalars[10].value.pointer = &scalarObservation;
        if (invoke((void *)observeScalars, ZJSNativeUInt64, scalars, 11,
                   &result, scratch, sizeof(scratch)) != ZJSNativeCallOK)
            return 1;
        if (check(result.uint64 == 0x4630cafeULL &&
                      scalarObservation.sint8 == -8 && scalarObservation.uint8 == 18 &&
                      scalarObservation.sint16 == -1600 && scalarObservation.uint16 == 65000 &&
                      scalarObservation.sint32 == -320000 && scalarObservation.uint32 == 4200000000U &&
                      scalarObservation.sint64 == -64000000000LL &&
                      scalarObservation.uint64 == 0xfedcba9876543210ULL &&
                      scalarObservation.float32 == 1.25f && scalarObservation.float64 == -9.5 &&
                      scalarObservation.pointer == &scalarObservation,
                  2))
            return 2;

        ZJSNativeArgument integers[10] = { 0 };
        for (NSUInteger index = 0; index < 10; ++index) {
            integers[index].kind = ZJSNativeUInt64;
            integers[index].value.uint64 = index + 1;
        }
        if (invoke((void *)sumTenIntegers, ZJSNativeUInt64, integers, 10,
                   &result, scratch, sizeof(scratch)) != ZJSNativeCallOK ||
            check(result.uint64 == 55, 3))
            return 3;

        ZJSNativeArgument doubles[10] = { 0 };
        for (NSUInteger index = 0; index < 10; ++index) {
            doubles[index].kind = ZJSNativeDouble;
            doubles[index].value.float64 = index + 0.5;
        }
        if (invoke((void *)sumTenDoubles, ZJSNativeDouble, doubles, 10,
                   &result, scratch, sizeof(scratch)) != ZJSNativeCallOK ||
            check(result.float64 == 50.0, 4))
            return 4;

        ZJSNativeArgument pointArguments[9] = { 0 };
        for (NSUInteger index = 0; index < 7; ++index) {
            pointArguments[index].kind = ZJSNativeDouble;
            pointArguments[index].value.float64 = index + 1;
        }
        pointArguments[7].kind = ZJSNativePoint;
        pointArguments[7].value.point = CGPointMake(10, 20);
        pointArguments[8].kind = ZJSNativeDouble;
        pointArguments[8].value.float64 = 8;
        if (invoke((void *)pointAfterSevenDoubles, ZJSNativePoint,
                   pointArguments, 9, &result, scratch, sizeof(scratch)) != ZJSNativeCallOK ||
            check(result.point.x == 26 && result.point.y == 40, 5))
            return 5;

        ZJSNativeArgument rangeArguments[9] = { 0 };
        for (NSUInteger index = 0; index < 7; ++index) {
            rangeArguments[index].kind = ZJSNativeUInt64;
            rangeArguments[index].value.uint64 = index + 1;
        }
        rangeArguments[7].kind = ZJSNativeRange;
        rangeArguments[7].value.range = NSMakeRange(100, 200);
        rangeArguments[8].kind = ZJSNativeUInt64;
        rangeArguments[8].value.uint64 = 8;
        if (invoke((void *)rangeAfterSevenIntegers, ZJSNativeRange,
                   rangeArguments, 9, &result, scratch, sizeof(scratch)) != ZJSNativeCallOK ||
            check(NSEqualRanges(result.range, NSMakeRange(116, 220)), 6))
            return 6;

        ZJSNativeArgument rectArguments[2] = { 0 };
        rectArguments[0].kind = ZJSNativeRect;
        rectArguments[0].value.rect = CGRectMake(3, 7, 11, 13);
        rectArguments[1].kind = ZJSNativeUInt64;
        rectArguments[1].value.uint64 = 2;
        if (invoke((void *)transformRect, ZJSNativeRect, rectArguments, 2,
                   &result, scratch, sizeof(scratch)) != ZJSNativeCallOK ||
            check(result.rect.origin.x == 5 && result.rect.origin.y == 5 &&
                      result.rect.size.width == 22 && result.rect.size.height == 39,
                  7))
            return 7;

        ZJSNativeArgument pointerArgument = { 0 };
        pointerArgument.kind = ZJSNativePointer;
        pointerArgument.value.pointer = &result;
        if (invoke((void *)echoPointer, ZJSNativePointer, &pointerArgument, 1,
                   &result, scratch, sizeof(scratch)) != ZJSNativeCallOK ||
            check(result.pointer == &result, 8))
            return 8;

        ZJSNativeArgument reentrantArgument = { 0 };
        reentrantArgument.kind = ZJSNativeUInt64;
        reentrantArgument.value.uint64 = 0;
        if (invoke((void *)reenterDispatcher, ZJSNativeUInt64,
                   &reentrantArgument, 1, &result, scratch, sizeof(scratch)) != ZJSNativeCallOK ||
            check(result.uint64 == 42, 9))
            return 9;

        BOOL caught = NO;
        @try {
            if (invoke((void *)throwNativeException, ZJSNativeVoid, NULL, 0,
                       &result, scratch, sizeof(scratch)) != ZJSNativeCallOK)
                return 10;
        } @catch (NSException *exception) {
            caught = [exception.reason isEqualToString:@"owned-dispatch-exception"];
        }
        if (check(caught, 11))
            return 11;

        ZJSNativeArgument overflowing[9] = { 0 };
        for (NSUInteger index = 0; index < 9; ++index) {
            overflowing[index].kind = ZJSNativeUInt64;
            overflowing[index].value.uint64 = index;
        }
        uint8_t noScratch = 0;
        insufficientScratchTargetCalled = NO;
        if (check(invoke((void *)insufficientScratchTarget, ZJSNativeUInt64,
                         overflowing, 9, &result, &noScratch, 0) ==
                      ZJSNativeCallInsufficientScratch &&
                      !insufficientScratchTargetCalled,
                  12))
            return 12;

        ZJSNativeCall invalid = { 0 };
        invalid.result = &result;
        invalid.scratch = scratch;
        invalid.scratchCapacity = sizeof(scratch);
        if (check(ZJSObjCNativeCall(&invalid) == ZJSNativeCallInvalidDescriptor, 13))
            return 13;
    }
    return 0;
}
