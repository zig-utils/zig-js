#import <Foundation/Foundation.h>
#include <stdint.h>

int32_t zig_js_benchmark_thermal_state(void) {
    if (@available(macOS 10.10.3, *)) {
        return (int32_t)[[NSProcessInfo processInfo] thermalState];
    }
    return -1;
}
