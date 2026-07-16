#ifndef ZIG_JS_JAVASCRIPTCORE_JSSTRINGREF_H
#define ZIG_JS_JAVASCRIPTCORE_JSSTRINGREF_H

#include <JavaScriptCore/JSBase.h>

typedef uint16_t JSChar;

#ifdef __cplusplus
extern "C" {
#endif

JS_EXPORT JSStringRef JSStringCreateWithCharacters(const JSChar* chars, size_t numChars);
JS_EXPORT JSStringRef JSStringCreateWithUTF8CString(const char* string);
JS_EXPORT JSStringRef JSStringRetain(JSStringRef string);
JS_EXPORT void JSStringRelease(JSStringRef string);
JS_EXPORT size_t JSStringGetLength(JSStringRef string);
JS_EXPORT const JSChar* JSStringGetCharactersPtr(JSStringRef string);
JS_EXPORT size_t JSStringGetMaximumUTF8CStringSize(JSStringRef string);
JS_EXPORT size_t JSStringGetUTF8CString(JSStringRef string, char* buffer, size_t bufferSize);
JS_EXPORT bool JSStringIsEqual(JSStringRef a, JSStringRef b);
JS_EXPORT bool JSStringIsEqualToUTF8CString(JSStringRef a, const char* b);

#ifdef __cplusplus
}
#endif

#endif
