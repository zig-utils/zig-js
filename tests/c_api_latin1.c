/*
 * Embedder evidence for flat Latin-1 string storage.
 *
 * `flat_storage_active` makes a Latin-1 cell store one physical byte per UTF-16
 * code unit (0xE9 for 'é') instead of that unit's two canonical WTF-8 bytes, so
 * every ABI reader that hands bytes to an embedder has to re-encode rather than
 * borrow. Nothing outside the engine exercised that: the C hosts only ever moved
 * ASCII across the boundary. This host drives the JSC-shaped public API with
 * Latin-1, CJK, astral, and lone-surrogate payloads, and — because a string's
 * representation is chosen from its content — checks that strings built along
 * different paths (source literal, fromCharCode, slice, concat, property key)
 * are indistinguishable at the boundary.
 *
 * Each failure returns a distinct exit code; see the `return` sites below.
 */

#include <JavaScriptCore/JavaScript.h>

#include <stdint.h>
#include <string.h>

/* "café" — canonical UTF-8 is five bytes, four UTF-16 code units. */
static const char kCafeUtf8[] = "caf\xc3\xa9";
static const JSChar kCafeUtf16[] = { 0x63, 0x61, 0x66, 0x00E9 };

static JSValueRef eval(JSGlobalContextRef context, const char* source)
{
    JSStringRef script = JSStringCreateWithUTF8CString(source);
    JSValueRef exception = NULL;
    JSValueRef result = JSEvaluateScript(context, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);
    return exception ? NULL : result;
}

/* Copy the string form of `source`'s result; NULL on any failure. */
static JSStringRef evalToString(JSGlobalContextRef context, const char* source)
{
    JSValueRef value = eval(context, source);
    if (!value)
        return NULL;
    JSValueRef exception = NULL;
    JSStringRef copied = JSValueToStringCopy(context, value, &exception);
    return exception ? NULL : copied;
}

static bool isCafe(JSStringRef string)
{
    if (!string || JSStringGetLength(string) != 4)
        return false;
    const JSChar* units = JSStringGetCharactersPtr(string);
    if (!units || memcmp(units, kCafeUtf16, sizeof kCafeUtf16) != 0)
        return false;
    /* The UTF-8 egress must be the canonical five-byte form, not the stored image. */
    char buffer[16];
    size_t written = JSStringGetUTF8CString(string, buffer, sizeof buffer);
    if (written != sizeof kCafeUtf8)
        return false;
    return memcmp(buffer, kCafeUtf8, sizeof kCafeUtf8) == 0;
}

int main(void)
{
    JSGlobalContextRef context = JSGlobalContextCreate(NULL);
    if (!context)
        return 1;

    /* 1. Both public constructors agree, and agree with each other. */
    JSStringRef from_utf8 = JSStringCreateWithUTF8CString(kCafeUtf8);
    JSStringRef from_units = JSStringCreateWithCharacters(kCafeUtf16, 4);
    if (!isCafe(from_utf8))
        return 2;
    if (!isCafe(from_units))
        return 3;
    if (!JSStringIsEqual(from_utf8, from_units))
        return 4;
    if (!JSStringIsEqualToUTF8CString(from_utf8, kCafeUtf8))
        return 5;
    if (JSStringGetMaximumUTF8CStringSize(from_utf8) < sizeof kCafeUtf8)
        return 6;

    /* 2. Strings the ENGINE builds must cross the boundary identically, whichever
     *    path built them. `slice` is the one that historically re-wrapped a flat
     *    byte as if it were WTF-8. */
    static const char* const builders[] = {
        "'caf\\u00e9'",                                     /* source literal   */
        "String.fromCharCode(0x63,0x61,0x66,0xe9)",         /* code units       */
        "'xcaf\\u00e9'.slice(1)",                           /* slice re-wrap    */
        "'caf' + String.fromCharCode(0xe9)",                /* concat           */
        "['caf\\u00e9'].join('')",                          /* join             */
        "JSON.parse('\"caf\\u00e9\"')",                     /* parser ingress   */
        "decodeURIComponent('caf%C3%A9')",                  /* decoder egress   */
    };
    for (size_t i = 0; i < sizeof builders / sizeof builders[0]; ++i) {
        JSStringRef built = evalToString(context, builders[i]);
        if (!isCafe(built)) {
            if (built)
                JSStringRelease(built);
            return 10 + (int)i;
        }
        /* Indistinguishable from an embedder-constructed "café". */
        if (!JSStringIsEqual(built, from_utf8)) {
            JSStringRelease(built);
            return 30 + (int)i;
        }
        JSStringRelease(built);
    }

    /* 3. A Latin-1 property key set from C is found again by an engine-built key
     *    (and the reverse), so key hashing does not depend on byte layout. */
    JSObjectRef global = JSContextGetGlobalObject(context);
    JSValueRef exception = NULL;
    JSObjectSetProperty(context, global, from_utf8, JSValueMakeNumber(context, 7), kJSPropertyAttributeNone, &exception);
    if (exception)
        return 50;
    JSValueRef seen = eval(context, "this['caf' + String.fromCharCode(0xe9)]");
    if (!seen || JSValueToNumber(context, seen, &exception) != 7.0 || exception)
        return 51;
    if (!eval(context, "this[String.fromCharCode(0x7a,0xfc)] = 9"))
        return 52;
    JSStringRef engine_key = JSStringCreateWithCharacters((const JSChar[]){ 0x7a, 0x00FC }, 2);
    JSValueRef by_c_key = JSObjectGetProperty(context, global, engine_key, &exception);
    JSStringRelease(engine_key);
    if (!by_c_key || JSValueToNumber(context, by_c_key, &exception) != 9.0 || exception)
        return 53;

    /* 4. Representations the flip does NOT change must still round-trip: CJK is
     *    stored as WTF-8, and astral / lone surrogates stay surrogate pairs. */
    JSStringRef cjk = evalToString(context, "'\\u4e9c\\u6c34'");
    if (!cjk || JSStringGetLength(cjk) != 2)
        return 60;
    const JSChar* cjk_units = JSStringGetCharactersPtr(cjk);
    if (!cjk_units || cjk_units[0] != 0x4E9C || cjk_units[1] != 0x6C34)
        return 61;
    JSStringRelease(cjk);

    JSStringRef astral = evalToString(context, "'\\u{1d401}'");
    if (!astral || JSStringGetLength(astral) != 2)
        return 62;
    const JSChar* astral_units = JSStringGetCharactersPtr(astral);
    if (!astral_units || astral_units[0] != 0xD835 || astral_units[1] != 0xDC01)
        return 63;
    JSStringRelease(astral);

    JSStringRef lone = evalToString(context, "'\\ud800'");
    if (!lone || JSStringGetLength(lone) != 1)
        return 64;
    const JSChar* lone_units = JSStringGetCharactersPtr(lone);
    if (!lone_units || lone_units[0] != 0xD800)
        return 65;
    JSStringRelease(lone);

    /* 5. A mixed string: the Latin-1 unit must not shift its neighbours. */
    JSStringRef mixed = evalToString(context, "'a\\u00e9\\u4e9c\\u{1d401}'");
    if (!mixed || JSStringGetLength(mixed) != 5)
        return 70;
    const JSChar* mixed_units = JSStringGetCharactersPtr(mixed);
    if (!mixed_units || mixed_units[0] != 0x61 || mixed_units[1] != 0x00E9 ||
        mixed_units[2] != 0x4E9C || mixed_units[3] != 0xD835 || mixed_units[4] != 0xDC01)
        return 71;
    JSStringRelease(mixed);

    /* 6. Latin-1 survives a round trip back INTO the engine as source and as a
     *    value, so ingress and egress use the same encoding. */
    JSValueRef round_trip = JSValueMakeString(context, from_utf8);
    JSObjectSetProperty(context, global, JSStringCreateWithUTF8CString("fromHost"), round_trip, kJSPropertyAttributeNone, &exception);
    if (exception)
        return 80;
    JSValueRef agrees = eval(context, "fromHost === 'caf' + String.fromCharCode(0xe9) && fromHost.length === 4 && fromHost.charCodeAt(3) === 233");
    if (!agrees || !JSValueToBoolean(context, agrees))
        return 81;

    JSStringRelease(from_utf8);
    JSStringRelease(from_units);
    JSGlobalContextRelease(context);
    return 0;
}
