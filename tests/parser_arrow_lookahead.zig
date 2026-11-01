const std = @import("std");
const parser_mod = @import("parser");

fn parse(source: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try parser_mod.Parser.init(arena.allocator(), source);
    _ = try parser.parseProgram();
    return parser.arrow_source_scans;
}

test "slashes inside parentheses keep arrows and groups apart" {
    // Each pair puts a slash in a parenthesised span, with a paren inside the
    // RegExp where a wrong RegExp/division choice would move the closing one.
    const sources = [_][]const u8{
        "var f=(a=/[)]/)=>a;",
        "var f=(a=[/[(]/])=>a;",
        "var f=(a=\"(\",b=/\\)/)=>a;",
        "var f=(a=b/c/d)=>a;",
        "var f=(a=g(x)/2)=>a;",
        "var f=(x/2)+(y/3);",
        "var f=(a=`/${b}/`)=>a;",
        "if(a)/[)]/.test(b);",
        "var f=(a=x++/2)=>a;",
        "var f=(a=function(){}/1)=>a;",
        "var f=(a=yield/2)=>a;",
        "for(const v of /[)]/.exec(s)){}",
        "var f=(a=typeof/[)]/)=>a;",
        "var f=(a={}/1)=>a;",
    };
    for (sources) |source| _ = parse(source) catch |err| {
        std.debug.print("could not parse: {s}\n", .{source});
        return err;
    };
}

test "a minified bundle's slashes never send arrow lookahead to the source scan" {
    // Nested immediately-invoked functions whose first slash is a RegExp
    // argument, then groups and calls divided by numbers: the shape of a
    // bundled screen. The grammar decides every one of these slashes, so the
    // token scan's answer stands; before, each one forced a source rescan of
    // every enclosing span.
    var source: std.ArrayListUnmanaged(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    const depth = 24;
    for (0..depth) |_| try source.appendSlice(std.testing.allocator, "(function(){");
    for (0..200) |i| {
        try source.print(std.testing.allocator, "var r{d}=s.replace(/\\//g,\"\"),v{d}=(w-h)/2+f(h)/3,a{d}=(n,m)=>n/m;", .{ i, i, i });
    }
    for (0..depth) |_| try source.appendSlice(std.testing.allocator, "})();");

    try std.testing.expectEqual(@as(usize, 0), try parse(source.items));
}

test "a slash after a closing brace still takes the source scan" {
    // `}` may close a block (RegExp next) or an object literal (division next);
    // only the source scan, which follows both, can tell.
    try std.testing.expect(try parse("var f=(a={}/1)=>a;") > 0);
}
