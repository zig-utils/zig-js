#import <JavaScriptCore/JavaScriptCore.h>

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

@protocol ZJSDispatchBenchmarkExports <JSExport>
- (int32_t)add:(int32_t)left to:(int32_t)right;
@end

@interface ZJSDispatchBenchmarkObject : NSObject <ZJSDispatchBenchmarkExports>
@end

@implementation ZJSDispatchBenchmarkObject
- (int32_t)add:(int32_t)left to:(int32_t)right
{
    return left + right;
}
@end

static uint64_t monotonicNanoseconds(void)
{
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC_RAW, &value);
    return (uint64_t)value.tv_sec * 1000000000ULL + (uint64_t)value.tv_nsec;
}

static uint32_t expectedChecksum(uint64_t jobs)
{
    uint32_t checksum = 0;
    for (uint64_t index = 0; index < jobs; ++index)
        checksum += (uint32_t)(index & 255) + (uint32_t)((index * 3) & 255);
    return checksum;
}

int main(int argc, const char *argv[])
{
    if (argc != 5 || strcmp(argv[1], "single") || strcmp(argv[4], "1")) {
        fprintf(stderr, "usage: objc-abi-benchmark single <block|export> JOBS 1\n");
        return 2;
    }
    const char *workload = argv[2];
    char *end = NULL;
    uint64_t jobs = strtoull(argv[3], &end, 10);
    if (!jobs || !end || *end) {
        fprintf(stderr, "jobs must be a positive integer\n");
        return 2;
    }

    @autoreleasepool {
        JSContext *context = [JSContext new];
        int32_t (^adder)(int32_t, int32_t) = ^int32_t(int32_t left, int32_t right) {
            return left + right;
        };
        context[@"nativeAdder"] = adder;
        context[@"exported"] = [ZJSDispatchBenchmarkObject new];
        [context evaluateScript:
            @"globalThis.runBlock = n => { let s = 0; for (let i = 0; i < n; i++) s = (s + nativeAdder(i & 255, (i * 3) & 255)) >>> 0; return s; };"
             "globalThis.runExport = n => { let s = 0; for (let i = 0; i < n; i++) s = (s + exported.addTo(i & 255, (i * 3) & 255)) >>> 0; return s; };"];
        if (context.exception) {
            fprintf(stderr, "setup failed: %s\n", context.exception.toString.UTF8String);
            return 3;
        }
        NSString *functionName = !strcmp(workload, "block") ? @"runBlock"
            : !strcmp(workload, "export") ? @"runExport" : nil;
        if (!functionName) {
            fprintf(stderr, "unknown workload: %s\n", workload);
            return 2;
        }
        JSValue *function = context[functionName];
        [function callWithArguments:@[ @5000 ]];

        const uint64_t start = monotonicNanoseconds();
        JSValue *result = [function callWithArguments:@[ @(jobs) ]];
        const uint64_t elapsed = monotonicNanoseconds() - start;
        if (context.exception) {
            fprintf(stderr, "benchmark failed: %s\n", context.exception.toString.UTF8String);
            return 4;
        }
        const uint32_t checksum = result.toUInt32;
        const uint32_t expected = expectedChecksum(jobs);
        if (checksum != expected) {
            fprintf(stderr, "checksum mismatch: %" PRIu32 " != %" PRIu32 "\n",
                    checksum, expected);
            return 5;
        }
        printf("zig-js\tsingle\t%s\t1\t%" PRIu64 "\t0\t%" PRIu64 "\t%" PRIu32 "\n",
               workload, jobs, elapsed, checksum);
    }
    return 0;
}
