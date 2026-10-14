const std = @import("std");
const parser_mod = @import("parser");

test "compact declared iteration heads do not scan later regexp bodies" {
    // Reduced from a minified stx URLSearchParams/URL polyfill. The later
    // regexp's quote makes the alternate slash-goal scan cross the loop head.
    const sources = [_][]const u8{
        "(()=>{class C{constructor(n){if(typeof n===\"string\"){for(let a of n.replace(/^\\?/,\"\").split(\"&\")){}}}}class D{static finish(n){if(n.query!==null)n.query=fn(n.query,a?/[ \"#<>']/:/[ \"#<>]/);}}})();",
        "(()=>{class C{constructor(n){if(typeof n===\"string\"){for(const a of n.replace(/^\\?/,\"\").split(\"&\")){}}}}class D{static finish(n){if(n.query!==null)n.query=fn(n.query,a?/[ \"#<>']/:/[ \"#<>]/);}}})();",
        "(()=>{class C{constructor(n){if(typeof n===\"string\"){for(var a of n.replace(/^\\?/,\"\").split(\"&\")){}}}}class D{static finish(n){if(n.query!==null)n.query=fn(n.query,a?/[ \"#<>']/:/[ \"#<>]/);}}})();",
        "for(let key in {pattern:/[)]/}){}; var tail=/[ \"#<>']/;",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try parser_mod.Parser.init(arena.allocator(), source);
        _ = try parser.parseProgram();
    }
}
