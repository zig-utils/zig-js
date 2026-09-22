const std = @import("std");
const lex = @import("lexer.zig");
const ast = @import("ast.zig");
const value_mod = @import("value.zig");
const agent = @import("agent.zig");
const Shape = @import("shape.zig").Shape;
const regex = @import("regex");
const regexp_compat = @import("regexp_compat.zig");
const PrivateNameMap = @import("private_name_map.zig").PrivateNameMap;
const stack_scan = @import("stack_scan.zig");

const Token = lex.Token;
const TokenKind = lex.TokenKind;
const Node = ast.Node;
const synthetic_eof_token: Token = .{ .kind = .eof, .text = "", .pos = 0 };

pub const ParseError = lex.LexError || error{ UnexpectedToken, ExpectedToken, InvalidAssignmentTarget };

/// A grammar check records its reason where the violation is known. Keep the
/// compact ParseError ABI while letting JS boundaries render an actual message
/// instead of guessing from the token at which parsing happened to stop.
pub const DiagnosticReason = enum {
    unexpected_token,
    expected_token,
    unexpected_end_of_expression,
    expected_semicolon_after_variable_declaration,
    expected_if_condition,
    escaped_keyword,
    lexical_declaration_single_statement,
    using_declaration_invalid_context,
    strict_with_statement,
    break_outside_loop_or_switch,
    undeclared_label,
    continue_outside_loop,
    continue_non_loop_label,
    duplicate_label,
    class_declaration_single_statement,
    generator_function_single_statement,
    async_function_single_statement,
    strict_function_single_statement,
    function_single_statement,
    duplicate_let_binding,
    duplicate_const_binding,
    duplicate_class_binding,
    duplicate_catch_binding,
    duplicate_catch_destructuring,
    catch_function_shadow,
    invalid_strict_parameters,
    function_name_required,
    function_keyword_name,
    strict_directive_non_simple_parameters,
    strict_function_name,
    array_rest_pattern_closing,
    object_rest_pattern_comma,
    expected_binding_element,
    expected_property_name,
    expected_named_destructuring_colon,
    abbreviated_destructuring_keyword,
    lexical_keyword_binding,
    strict_destructure_binding,
    private_accessor_outside_class,
    expected_method_parenthesis,
    shorthand_keyword,
    yield_shorthand_generator,
    await_shorthand_async,
    expected_identifier_property_name,
    expected_module_specifier,
    expected_import_binding,
    string_import_requires_alias,
    import_call_arguments,
    expected_import_call_parenthesis,
    import_meta_module_only,
    import_meta_property,
    malformed_template_hex_escape,
    malformed_template_unicode_escape,
    template_numeric_escape,
    for_await_in,
    using_for_in,
    for_of_initializer,
    for_await_semicolon,
    getter_parameters,
    setter_parameters,
    setter_parameter_pattern,
    unexpected_end_of_script,
    duplicate_proto,
    template_expression_tail,
    return_outside_function,
    new_target_outside_function,
    new_target_in_global_arrow,
    new_target_invalid_identifier,
    private_field_delete,
    undeclared_private_name,
    invalid_super,
    super_call_field_initializer,
    static_block_await_statement,
    static_block_await_reference,
    static_block_for_await,
    invalid_assignment,
    invalid_destructuring_assignment,
    invalid_prefix_increment,
    invalid_prefix_decrement,
    invalid_postfix_increment,
    invalid_postfix_decrement,
    strict_modify_eval,
    strict_modify_arguments,
    strict_postfix_eval,
    strict_postfix_arguments,
    constructor_field,
    private_constructor_field,
    private_constructor_method,
    private_constructor_accessor,
    duplicate_constructor,
    static_prototype_field,
    static_prototype_method,
    constructor_accessor,
    constructor_async,
    constructor_generator,
    duplicate_private_field,
    duplicate_private_method,
    duplicate_private_accessor,
    static_getter_instance_setter,
    static_setter_instance_getter,
    instance_getter_static_setter,
    instance_setter_static_getter,
    regexp_missing_closing_parenthesis,
    regexp_missing_character_class_terminator,
    regexp_quantifier_numbers_out_of_order,
    regexp_nothing_to_repeat,
    regexp_trailing_backslash,
    regexp_invalid_group_specifier_name,
    regexp_range_out_of_order_in_character_class,
    regexp_duplicate_group_specifier_name,
    regexp_invalid_named_backreference,
    regexp_invalid_property_expression,
    regexp_invalid_escaped_character_for_unicode_pattern,
    regexp_invalid_unicode_escape,
    regexp_invalid_unicode_code_point_escape,
    regexp_invalid_octal_escape_for_unicode_pattern,
    regexp_invalid_range_in_character_class_for_unicode_pattern,
    regexp_invalid_backreference_for_unicode_pattern,
    regexp_unrecognized_character_after_group_start,
    regexp_unmatched_parentheses,

    pub fn parseError(reason: DiagnosticReason) ParseError {
        return switch (reason) {
            .expected_token, .expected_if_condition, .unexpected_end_of_script, .expected_identifier_property_name, .expected_import_call_parenthesis => ParseError.ExpectedToken,
            .invalid_assignment,
            .invalid_destructuring_assignment,
            .array_rest_pattern_closing,
            .object_rest_pattern_comma,
            .invalid_prefix_increment,
            .invalid_prefix_decrement,
            .invalid_postfix_increment,
            .invalid_postfix_decrement,
            => ParseError.InvalidAssignmentTarget,
            else => ParseError.UnexpectedToken,
        };
    }

    pub fn message(reason: DiagnosticReason) []const u8 {
        return switch (reason) {
            .unexpected_token => "",
            .expected_token => "",
            .unexpected_end_of_expression => "Unexpected end of script",
            .expected_semicolon_after_variable_declaration => "Expected ';' after variable declaration.",
            .expected_if_condition => "Expected '(' to start an 'if' condition.",
            .escaped_keyword => "",
            .lexical_declaration_single_statement => "Cannot use lexical declaration in single-statement context.",
            .using_declaration_invalid_context => "'using' declarations are only valid inside blocks, functions, or modules.",
            .strict_with_statement => "'with' statements are not valid in strict mode.",
            .break_outside_loop_or_switch => "'break' is only valid inside a switch or loop statement.",
            .undeclared_label => "",
            .continue_outside_loop => "'continue' is only valid inside a loop statement.",
            .continue_non_loop_label => "",
            .duplicate_label => "",
            .class_declaration_single_statement => "'class' declaration is not directly within a block statement.",
            .generator_function_single_statement => "Cannot use generator function declaration in single-statement context.",
            .async_function_single_statement => "Cannot use async function declaration in single-statement context.",
            .strict_function_single_statement => "Function declarations are only allowed inside blocks or switch statements in strict mode.",
            .function_single_statement => "Function declarations are only allowed inside block statements or at the top level of a program.",
            .duplicate_let_binding, .duplicate_const_binding, .duplicate_class_binding => "",
            .duplicate_catch_binding, .duplicate_catch_destructuring, .catch_function_shadow => "",
            .invalid_strict_parameters => "Invalid parameters or function name in strict mode.",
            .function_name_required => "Function statements must have a name.",
            .function_keyword_name => "",
            .strict_directive_non_simple_parameters => "'use strict' directive not allowed inside a function with a non-simple parameter list.",
            .strict_function_name => "",
            .array_rest_pattern_closing => "Expected a closing ']' following a rest element destructuring pattern.",
            .object_rest_pattern_comma => "Cannot parse assignment pattern.",
            .expected_binding_element => "Expected a binding element.",
            .expected_property_name => "Expected a property name.",
            .expected_named_destructuring_colon => "Expected a ':' prior to a named destructuring property.",
            .abbreviated_destructuring_keyword, .lexical_keyword_binding, .strict_destructure_binding => "",
            .private_accessor_outside_class => "Cannot declare a private setter or getter outside a class.",
            .expected_method_parenthesis => "Expected a parenthesis for argument list.",
            .shorthand_keyword => "",
            .yield_shorthand_generator => "Cannot use 'yield' as a shorthand property name in a generator function.",
            .await_shorthand_async => "Cannot use 'await' as a shorthand property name in an async function.",
            .expected_identifier_property_name => "Expected an identifier as property name.",
            .expected_module_specifier => "Expected a string literal for module specifier.",
            .expected_import_binding => "Expected an identifier for import binding.",
            .string_import_requires_alias => "A string import name requires an 'as' binding.",
            .import_call_arguments => "import call expects one or two arguments.",
            .expected_import_call_parenthesis => "import call expects one or two arguments.",
            .import_meta_module_only => "import.meta is only valid inside modules.",
            .import_meta_property => "\"import.\" can only be followed with meta.",
            .malformed_template_hex_escape => "\\x can only be followed by a hex character sequence",
            .malformed_template_unicode_escape => "\\u can only be followed by a Unicode character sequence",
            .template_numeric_escape => "The only valid numeric escape in strict mode is '\\0'",
            .for_await_in => "Expected 'of' in for-await syntax.",
            .using_for_in => "Expected either 'in' or 'of' in enumeration syntax.",
            .for_of_initializer => "Cannot assign to the loop variable inside a for-of loop header.",
            .for_await_semicolon => "Unexpected a ';' in for-await-of header.",
            .getter_parameters => "getter functions must have no parameters.",
            .setter_parameters => "setter functions must have one parameter.",
            .setter_parameter_pattern => "Expected a parameter pattern or a ')' in parameter list.",
            .unexpected_end_of_script => "Unexpected end of script",
            .duplicate_proto => "Attempted to redefine __proto__ property.",
            .template_expression_tail => "Expected a closing '}' following an expression in template literal.",
            .return_outside_function => "Return statements are only valid inside functions.",
            .new_target_outside_function => "new.target is only valid inside functions or static blocks.",
            .new_target_in_global_arrow => "new.target is not valid inside arrow functions in global code.",
            .new_target_invalid_identifier => "\"new.\" can only be followed with target.",
            .private_field_delete => "Cannot delete private field.",
            .undeclared_private_name => "Cannot reference undeclared private names.",
            .invalid_super => "super is not valid in this context.",
            .super_call_field_initializer => "Unexpected token '('. super call is not valid in class field initializer context.",
            .static_block_await_statement => "Unexpected identifier 'await'. Cannot use 'await' within static block.",
            .static_block_await_reference => "The 'await' keyword is disallowed in the IdentifierReference position within static block.",
            .static_block_for_await => "for-await-of can only be used in an async function or async generator.",
            .invalid_assignment => "Left side of assignment is not a reference.",
            .invalid_destructuring_assignment => "Invalid destructuring assignment target.",
            .invalid_prefix_increment => "Prefix ++ operator applied to value that is not a reference.",
            .invalid_prefix_decrement => "Prefix -- operator applied to value that is not a reference.",
            .invalid_postfix_increment => "Postfix ++ operator applied to value that is not a reference.",
            .invalid_postfix_decrement => "Postfix -- operator applied to value that is not a reference.",
            .strict_modify_eval => "Cannot modify 'eval' in strict mode.",
            .strict_modify_arguments => "Cannot modify 'arguments' in strict mode.",
            .strict_postfix_eval => "'eval' cannot be modified in strict mode.",
            .strict_postfix_arguments => "'arguments' cannot be modified in strict mode.",
            .constructor_field => "Cannot declare class field named 'constructor'.",
            .private_constructor_field => "Cannot declare private class field named '#constructor'.",
            .private_constructor_method => "Cannot declare a private method named '#constructor'.",
            .private_constructor_accessor => "Cannot declare a private accessor named '#constructor'.",
            .duplicate_constructor => "Cannot declare multiple constructors in a single class.",
            .static_prototype_field => "Cannot declare a static field named 'prototype'.",
            .static_prototype_method => "Cannot declare a static method named 'prototype'.",
            .constructor_accessor => "Cannot declare a getter or setter named 'constructor'.",
            .constructor_async => "Cannot declare an async method named 'constructor'.",
            .constructor_generator => "Cannot declare a generator method named 'constructor'.",
            .duplicate_private_field => "Cannot declare private field twice.",
            .duplicate_private_method => "Cannot declare private method twice.",
            // JSC uses "setter" for either duplicate accessor kind.
            .duplicate_private_accessor => "Declared private setter with an already used name.",
            .static_getter_instance_setter => "Cannot declare a private static getter if there is a non-static private setter with used name.",
            .static_setter_instance_getter => "Cannot declare a private static setter if there is a non-static private getter with used name.",
            .instance_getter_static_setter => "Cannot declare a private non-static getter if there is a static private setter with used name.",
            .instance_setter_static_getter => "Cannot declare a private non-static setter if there is a static private getter with used name.",
            .regexp_missing_closing_parenthesis => "Invalid regular expression: missing )",
            .regexp_missing_character_class_terminator => "Invalid regular expression: missing terminating ] for character class",
            .regexp_quantifier_numbers_out_of_order => "Invalid regular expression: numbers out of order in {} quantifier",
            .regexp_nothing_to_repeat => "Invalid regular expression: nothing to repeat",
            .regexp_trailing_backslash => "Invalid regular expression: \\ at end of pattern",
            .regexp_invalid_group_specifier_name => "Invalid regular expression: invalid group specifier name",
            .regexp_range_out_of_order_in_character_class => "Invalid regular expression: range out of order in character class",
            .regexp_duplicate_group_specifier_name => "Invalid regular expression: duplicate group specifier name",
            .regexp_invalid_named_backreference => "Invalid regular expression: invalid \\k<> named backreference",
            .regexp_invalid_property_expression => "Invalid regular expression: invalid property expression",
            .regexp_invalid_escaped_character_for_unicode_pattern => "Invalid regular expression: invalid escaped character for Unicode pattern",
            .regexp_invalid_unicode_escape => "Invalid regular expression: invalid Unicode \\u escape",
            .regexp_invalid_unicode_code_point_escape => "Invalid regular expression: invalid Unicode code point \\u{} escape",
            .regexp_invalid_octal_escape_for_unicode_pattern => "Invalid regular expression: invalid octal escape for Unicode pattern",
            .regexp_invalid_range_in_character_class_for_unicode_pattern => "Invalid regular expression: invalid range in character class for Unicode pattern",
            .regexp_invalid_backreference_for_unicode_pattern => "Invalid regular expression: invalid backreference for Unicode pattern",
            .regexp_unrecognized_character_after_group_start => "Invalid regular expression: unrecognized character after (?",
            .regexp_unmatched_parentheses => "Invalid regular expression: unmatched parentheses",
        };
    }
};

fn regexDiagnosticReason(reason: regex.CompileErrorReason) DiagnosticReason {
    return switch (reason) {
        .missing_closing_parenthesis => .regexp_missing_closing_parenthesis,
        .missing_character_class_terminator => .regexp_missing_character_class_terminator,
        .quantifier_numbers_out_of_order => .regexp_quantifier_numbers_out_of_order,
        .nothing_to_repeat => .regexp_nothing_to_repeat,
        .trailing_backslash => .regexp_trailing_backslash,
        .invalid_group_specifier_name => .regexp_invalid_group_specifier_name,
        .range_out_of_order_in_character_class => .regexp_range_out_of_order_in_character_class,
        .duplicate_group_specifier_name => .regexp_duplicate_group_specifier_name,
        .invalid_named_backreference => .regexp_invalid_named_backreference,
        .invalid_property_expression => .regexp_invalid_property_expression,
        .invalid_escaped_character_for_unicode_pattern => .regexp_invalid_escaped_character_for_unicode_pattern,
        .invalid_unicode_escape => .regexp_invalid_unicode_escape,
        .invalid_unicode_code_point_escape => .regexp_invalid_unicode_code_point_escape,
        .invalid_octal_escape_for_unicode_pattern => .regexp_invalid_octal_escape_for_unicode_pattern,
        .invalid_range_in_character_class_for_unicode_pattern => .regexp_invalid_range_in_character_class_for_unicode_pattern,
        .invalid_backreference_for_unicode_pattern => .regexp_invalid_backreference_for_unicode_pattern,
        .unrecognized_character_after_group_start => .regexp_unrecognized_character_after_group_start,
        .unmatched_parentheses => .regexp_unmatched_parentheses,
    };
}

const DiagnosticTokenKind = enum { identifier, keyword, number, string, token };

const DiagnosticToken = struct {
    kind: DiagnosticTokenKind,
    text: []const u8,
    detail: ?[]const u8 = null,
};

pub const SourceLocation = struct {
    byte_offset: usize,
    line: usize,
    column: usize,
};

/// Source metadata retained for every parsed statement. Keeping this separate
/// from `ast.Node` avoids widening every AST node while still giving debugger
/// clients exact statement boundaries. The node and source bytes share the
/// parser arena lifetime.
pub const StatementLocation = struct {
    node: *const Node,
    location: SourceLocation,
    debugger_statement: bool = false,
};

const StatementLocationCheckpoint = struct {
    cursor: SourceLocation,
    published_len: usize,
};

/// Whether `parseStatement` can publish `node` in `statement_locations`.
/// Expression and synthetic Program nodes never enter that registry, so the
/// evaluator can avoid a guaranteed-negative debugger lookup without weakening
/// late debugger attachment or host statement checkpoints.
pub inline fn canPublishStatementLocation(node: *const Node) bool {
    return switch (node.*) {
        .var_decl,
        .destructure_decl,
        .func_decl,
        .return_stmt,
        .throw_stmt,
        .try_stmt,
        .break_stmt,
        .continue_stmt,
        .labeled_stmt,
        .expr_stmt,
        .debugger_stmt,
        .block,
        .decl_group,
        .if_stmt,
        .while_stmt,
        .do_while_stmt,
        .for_stmt,
        .for_in,
        .switch_stmt,
        .with_stmt,
        .import_decl,
        .export_decl,
        => true,
        else => false,
    };
}

const BindingKeywordClass = packed struct {
    always_reserved: bool = false,
    grammar_reserved: bool = false,
    strict_reserved: bool = false,
};

const always_and_grammar = BindingKeywordClass{ .always_reserved = true, .grammar_reserved = true };
const always_only = BindingKeywordClass{ .always_reserved = true };
const grammar_and_strict = BindingKeywordClass{ .grammar_reserved = true, .strict_reserved = true };
const strict_only = BindingKeywordClass{ .strict_reserved = true };

/// Immutable ECMA-262 keyword membership. StaticStringMap partitions by byte
/// length first, so ordinary long bindings reject without walking every word.
const binding_keyword_entries = .{
    .{ "break", always_and_grammar },  .{ "case", always_and_grammar },
    .{ "catch", always_and_grammar },  .{ "class", always_and_grammar },
    .{ "const", always_and_grammar },  .{ "continue", always_and_grammar },
    .{ "debugger", always_only },      .{ "default", always_and_grammar },
    .{ "delete", always_and_grammar }, .{ "do", always_and_grammar },
    .{ "else", always_and_grammar },   .{ "enum", always_and_grammar },
    .{ "export", always_and_grammar }, .{ "extends", always_and_grammar },
    .{ "false", always_and_grammar },  .{ "finally", always_and_grammar },
    .{ "for", always_and_grammar },    .{ "function", always_and_grammar },
    .{ "if", always_and_grammar },     .{ "import", always_and_grammar },
    .{ "in", always_and_grammar },     .{ "instanceof", always_and_grammar },
    .{ "new", always_and_grammar },    .{ "null", always_and_grammar },
    .{ "return", always_and_grammar }, .{ "super", always_and_grammar },
    .{ "switch", always_and_grammar }, .{ "this", always_and_grammar },
    .{ "throw", always_and_grammar },  .{ "true", always_and_grammar },
    .{ "try", always_and_grammar },    .{ "typeof", always_and_grammar },
    .{ "var", always_and_grammar },    .{ "void", always_and_grammar },
    .{ "while", always_and_grammar },  .{ "with", always_only },
    .{ "let", grammar_and_strict },    .{ "yield", grammar_and_strict },
    .{ "implements", strict_only },    .{ "interface", strict_only },
    .{ "package", strict_only },       .{ "private", strict_only },
    .{ "protected", strict_only },     .{ "public", strict_only },
    .{ "static", strict_only },
};
const binding_keyword_classes = std.StaticStringMap(BindingKeywordClass).initComptime(binding_keyword_entries);

inline fn bindingKeywordClass(text: []const u8) BindingKeywordClass {
    return binding_keyword_classes.get(text) orelse .{};
}

const SecureStringHashContext = struct {
    seed: u64,

    pub fn hash(context: @This(), value: []const u8) u64 {
        return std.hash.Wyhash.hash(context.seed, value);
    }

    pub fn eql(_: @This(), left: []const u8, right: []const u8) bool {
        return std.mem.eql(u8, left, right);
    }
};

/// Cover-grammar facts are keyed by arena-node identity. Hash the exact address
/// representation with the parse-root secret instead of treating allocator
/// placement or ASLR as a collision-resistance mechanism.
const SecureIdentityHashContext = struct {
    seed: u64,

    pub fn hash(context: @This(), identity: usize) u64 {
        return std.hash.Wyhash.hash(context.seed, std.mem.asBytes(&identity));
    }

    pub fn eql(_: @This(), left: usize, right: usize) bool {
        return left == right;
    }
};

/// One lazy keyed-hash context belongs to the complete parse, including nested
/// template-substitution parsers. Production callers attach the realm's Shape
/// key source; standalone parser users fall back to the engine entropy provider.
const SecureHashState = struct {
    context: ?SecureStringHashContext = null,
    realm_shape: ?*Shape = null,

    fn candidate(state: *@This()) std.mem.Allocator.Error!SecureStringHashContext {
        if (state.context) |context| return context;
        if (state.realm_shape) |shape|
            return .{ .seed = try shape.deriveSecureHashSeed() };

        var seed_bytes: [@sizeOf(u64)]u8 = undefined;
        agent.engineIo().randomSecure(&seed_bytes) catch return error.OutOfMemory;
        return .{ .seed = std.mem.readInt(u64, &seed_bytes, .little) };
    }
};

fn SecureStringMapUnmanaged(comptime Value: type) type {
    const Index = std.HashMapUnmanaged(
        []const u8,
        Value,
        SecureStringHashContext,
        std.hash_map.default_max_load_percentage,
    );

    return struct {
        const Self = @This();

        index: Index = .empty,
        state: *SecureHashState,

        fn publish(self: *Self, context: SecureStringHashContext) void {
            if (self.state.context == null) self.state.context = context;
        }

        fn put(self: *Self, allocator: std.mem.Allocator, key: []const u8, value: Value) std.mem.Allocator.Error!void {
            const context = try self.state.candidate();
            try self.index.putContext(allocator, key, value, context);
            self.publish(context);
        }

        fn getOrPut(self: *Self, allocator: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error!Index.GetOrPutResult {
            const context = try self.state.candidate();
            const result = try self.index.getOrPutContext(allocator, key, context);
            self.publish(context);
            return result;
        }

        fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, capacity: u32) std.mem.Allocator.Error!void {
            const context = try self.state.candidate();
            try self.index.ensureTotalCapacityContext(allocator, capacity, context);
            self.publish(context);
        }

        fn get(self: *const Self, key: []const u8) ?Value {
            const context = self.state.context orelse return null;
            return self.index.getContext(key, context);
        }

        fn getPtr(self: *Self, key: []const u8) ?*Value {
            const context = self.state.context orelse return null;
            return self.index.getPtrContext(key, context);
        }

        fn contains(self: *const Self, key: []const u8) bool {
            const context = self.state.context orelse return false;
            return self.index.containsContext(key, context);
        }

        /// Reads the published context like `contains` rather than deriving a
        /// candidate: a map with no published context holds no entries, so
        /// there is nothing to remove and no reason to mint a key for the
        /// attempt. Returns whether the key was present.
        fn remove(self: *Self, key: []const u8) bool {
            const context = self.state.context orelse return false;
            return self.index.removeContext(key, context);
        }

        fn count(self: *const Self) usize {
            return self.index.count();
        }

        fn iterator(self: *const Self) Index.Iterator {
            return self.index.iterator();
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.index.deinit(allocator);
        }
    };
}

fn SecureIdentityMapUnmanaged(comptime Value: type) type {
    const Index = std.HashMapUnmanaged(
        usize,
        Value,
        SecureIdentityHashContext,
        std.hash_map.default_max_load_percentage,
    );

    return struct {
        const Self = @This();

        index: Index = .empty,

        fn put(
            self: *Self,
            allocator: std.mem.Allocator,
            state: *SecureHashState,
            identity: usize,
            value: Value,
        ) std.mem.Allocator.Error!void {
            const root_context = try state.candidate();
            const context = SecureIdentityHashContext{ .seed = root_context.seed };
            try self.index.putContext(allocator, identity, value, context);
            // Failed first insertion publishes neither a table nor the shared
            // parse-root seed, so a caller can recover and retry exactly.
            if (state.context == null) state.context = root_context;
        }

        fn contains(self: *const Self, state: *const SecureHashState, identity: usize) bool {
            const root_context = state.context orelse return false;
            return self.index.containsContext(identity, .{ .seed = root_context.seed });
        }

        fn get(self: *const Self, state: *const SecureHashState, identity: usize) ?Value {
            const root_context = state.context orelse return null;
            return self.index.getContext(identity, .{ .seed = root_context.seed });
        }

        fn remove(self: *Self, state: *const SecureHashState, identity: usize) bool {
            const root_context = state.context orelse return false;
            return self.index.removeContext(identity, .{ .seed = root_context.seed });
        }

        fn count(self: *const Self) usize {
            return self.index.count();
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.index.deinit(allocator);
        }
    };
}

pub fn sourceLocationAt(source: []const u8, raw_offset: usize) SourceLocation {
    const offset = @min(raw_offset, source.len);
    var line: usize = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < offset) {
        if (lex.lineTerminatorLen(source, i)) |len| {
            line += 1;
            i += len;
            line_start = i;
        } else {
            i += 1;
        }
    }
    return .{
        .byte_offset = offset,
        .line = line,
        .column = offset - line_start + 1,
    };
}

/// Recursive-descent + precedence-climbing parser producing an arena-allocated
/// AST for the v1 subset (expressions, var/let/const, if/else, while, blocks).
pub const Parser = struct {
    tokens: std.ArrayListUnmanaged(Token),
    pos: usize = 0,
    current_token: *const Token = &synthetic_eof_token,
    arena: std.mem.Allocator,
    token_allocator: std.mem.Allocator,
    lexer: lex.Lexer,
    lex_error: ?ParseError = null,
    lex_error_offset: usize = 0,
    /// Freeable backing for invocation-local indexes. AST nodes, tokens, and
    /// source-derived names remain arena-owned; scratch tables never own keys.
    scratch_allocator: std.mem.Allocator,
    /// Root parser storage for lazily derived source-string hashing. A nested
    /// template parser points at this state instead of installing another key.
    secure_hash_state: SecureHashState = .{},
    shared_secure_hash_state: ?*SecureHashState = null,
    /// Parse entry points install one resettable arena here so every RegExp
    /// literal reuses the largest validation footprint seen by that parse. The
    /// pointer is stack-local to parsing and never escapes or enters the AST.
    regex_validation_arena: ?*std.heap.ArenaAllocator = null,
    /// The matching `)` of every `(` token, by token index, or
    /// `no_matching_paren`. Arrow lookahead builds this inside its disposable
    /// arena when nesting crosses the linear-scan threshold (#933 item 8b).
    paren_close: ?[]u32 = null,
    /// Source-offset results retained from the disposable parenthesis index.
    /// Unlike token indexes, these remain valid after speculative tokens are
    /// discarded and make every nested arrow query after the first O(1).
    arrow_lookahead: std.AutoHashMapUnmanaged(usize, bool) = .empty,
    /// Var-scoped names declared inside the body of the outermost lexical `for`
    /// being parsed in the current var scope, each with the order of its latest
    /// declaration. A lexical head asks this whether its body var-declares one
    /// of its names: one lookup per name, where re-collecting the body's
    /// VarDeclaredNames at every head was quadratic for nested heads (#933 item
    /// 8). Null outside such a body; every var-scope boundary suspends it.
    for_body_vars: ?*ForBodyVars = null,
    /// The original source text, so function definitions can capture their exact
    /// source span for `Function.prototype.toString`.
    source: []const u8 = "",
    /// First Annex B HTML-like comment accepted under Script lexical rules.
    /// Modules reject this exact offset before parsing, so one token stream can
    /// serve both public parse entry points without lexical-goal ambiguity.
    html_comment_offset: ?usize = null,
    /// Statement nodes are published in completion order (inner statement,
    /// block, outer statement), but their parse entries are encountered in source
    /// order. Resolve coordinates at entry with one forward-only cursor, then
    /// retain the value until publication. This avoids both prefix rescans and an
    /// attacker-proportional line index without widening tokens or AST nodes.
    statement_location_cursor: SourceLocation = .{ .byte_offset = 0, .line = 1, .column = 1 },
    /// True while parsing a generator body, so `yield` is recognized as a yield
    /// expression rather than an identifier. Saved/restored around each function.
    in_generator: bool = false,
    /// True while parsing an async function body, so `await` is recognized as an
    /// await expression rather than an identifier. Saved/restored per function.
    in_async: bool = false,
    /// Inside a class body (so a private name `#x` is in scope) — gates the
    /// `#field in obj` brand check, which is a syntax error outside any class.
    in_class: bool = false,
    /// Direct eval's exact enclosing PrivateEnvironment. Locally declared class
    /// names are checked normally; other private uses must occur in this map.
    eval_private_names: ?*const PrivateNameMap = null,
    /// True while parsing strict-mode code: the program (or an enclosing
    /// function) had a `"use strict"` directive prologue, a function body has
    /// its own such directive, or we're inside a class (always strict). Inherited
    /// by nested functions. Recorded on each `FunctionNode.is_strict`.
    strict: bool = false,
    /// Strictness of the most recently parsed function body, read by the caller
    /// to stamp `FunctionNode.is_strict` (since `parseFnBody` restores `strict`).
    last_fn_strict: bool = false,
    /// Syntactic-context depths for early errors: `return` requires a function,
    /// unlabeled `break` a loop/switch, unlabeled `continue` a loop. A function
    /// boundary resets the loop/switch depths (you can't break across it).
    fn_depth: u32 = 0,
    iter_depth: u32 = 0,
    switch_depth: u32 = 0,
    /// Stack-local flag owned by the ordinary function/method currently being
    /// parsed. Nested ordinary functions replace it; arrows deliberately share
    /// it because they inherit `arguments`. The pointer never escapes parsing,
    /// so tracking adds no attacker-proportional allocation or cleanup path.
    current_arguments_use: ?*bool = null,
    /// Direct eval has the same ordinary-function/arrow ownership boundary as
    /// `arguments`, but is tracked separately so compiler admission cannot
    /// confuse a dynamic-environment requirement with a frame-local binding.
    current_direct_eval_use: ?*bool = null,
    /// Depth of syntax contexts where `new.target` is allowed. Ordinary
    /// functions/methods introduce one; arrows only inherit an outer one.
    new_target_depth: u32 = 0,
    /// The stack address below which parsing and the analysis walks over the
    /// finished tree stop recursing (#936). Read once, on the thread that
    /// creates the parser, so each level pays one comparison.
    stack_floor: usize,
    /// True when parsing a Module (via `parseModule`): top-level `import` and
    /// `export` declarations are recognized, and the body is implicitly strict.
    module: bool = false,
    /// When false (the default), `scanSuperAndArgs` also flags an `arguments`
    /// reference — used for class field initializers, where `arguments` is an
    /// early error. Set true to scan only for SuperCall (e.g. a method body,
    /// where `arguments` is legal).
    scan_allow_arguments: bool = false,
    /// Parameter Contains Await/Yield queries must not impose a SuperCall ban;
    /// the enclosing function/method/field validates its own lexical super use.
    scan_forbid_super_call: bool = true,
    /// Selects the class-field-specific SuperCall diagnostic while that
    /// initializer's Contains query runs. Arrows inherit it; nested ordinary
    /// functions and class bodies retain their existing query boundaries.
    scan_super_call_field_initializer: bool = false,
    /// When true, `scanSuperAndArgs` also flags a SuperProperty (`super.x`) —
    /// used to validate indirect-eval code, which is global and may contain no
    /// `super` at all (a direct eval from a field initializer leaves this false,
    /// since `super.prop` is permitted there).
    scan_forbid_super_property: bool = false,
    /// When true, `scanSuperAndArgs` flags a YieldExpression — used to enforce
    /// the early error "FormalParameters of a generator must not contain a
    /// YieldExpression" (e.g. `function* g(a = yield) {}`).
    scan_forbid_yield: bool = false,
    /// When true, `scanSuperAndArgs` flags an AwaitExpression — used to enforce
    /// the early error "FormalParameters of an async function/arrow must not
    /// contain an AwaitExpression" (e.g. `async function f(a = await x) {}`).
    scan_forbid_await: bool = false,
    /// The active ContainsAwait query belongs to a class static block, which
    /// has position-specific diagnostics distinct from parameter queries.
    scan_static_block_await: bool = false,
    /// The current node is a direct StatementList item. Cleared before descent;
    /// nested blocks publish their own items while `if`/label bodies do not.
    scan_static_statement_list_item: bool = false,
    /// Array literals (parsed as a cover for array patterns) with a comma after
    /// a spread element. Legal in a literal but not in the destructuring
    /// refinement, where a rest element must be last and have no trailing comma.
    /// The value is the comma offset for an exact failure diagnostic.
    rest_comma_arrays: SecureIdentityMapUnmanaged(usize) = .{},
    /// Object literals with a comma after a spread property. A literal permits
    /// this; an assignment-pattern refinement does not, even when the comma is
    /// trailing. The value is the comma offset and the map is consulted only
    /// during refinement.
    rest_comma_objects: SecureIdentityMapUnmanaged(usize) = .{},
    /// Object literals carrying a CoverInitializedName (`{ a = 1 }`), which is
    /// valid ONLY when the object is later refined to an assignment pattern.
    /// `litToPattern` removes an entry on conversion; any left when the
    /// Script/Module finishes parsing was used as a real object literal — an
    /// early SyntaxError (`({ a = 1 })`, `f({ a = 1 })`).
    pending_cover_inits: SecureIdentityMapUnmanaged(void) = .{},
    /// Object literals with two or more `__proto__: value` colon properties,
    /// which is an early error for a real object literal but legal when the object
    /// is refined to a pattern (where `__proto__` is just a property key).
    /// Same lifecycle as `pending_cover_inits`.
    pending_proto_dup: SecureIdentityMapUnmanaged(usize) = .{},
    /// Expression nodes that were wrapped in parentheses, keyed by node address
    /// so the mark is true pointer identity rather than any structural hashing.
    /// A parenthesized
    /// array/object literal is not a valid destructuring assignment target
    /// (`({}) = 1`, `([a]) = b`), so `litToPattern` rejects one; a parenthesized
    /// identifier/member stays a valid target and is routed around litToPattern.
    paren_wrapped: SecureIdentityMapUnmanaged(void) = .{},
    /// Identifier name for the just-parsed parenthesized target in `(... ) =`.
    /// This feeds NamedEvaluation, where `(f) = function(){}` must not name the
    /// anonymous function even though the parenthesized identifier remains a valid
    /// assignment target.
    paren_assign_target_name: ?[]const u8 = null,
    /// The `[~In]` grammar parameter: true while parsing a classic `for (init;…)`
    /// init expression, where a top-level `in` (binary or `#x in obj`) is
    /// forbidden so it can't be confused with a for-in head. Reset to `[+In]`
    /// inside any bracketing construct (parens, `[]`, `{}`, call args, computed
    /// member, conditional branches).
    no_in: bool = false,
    /// Set for the single statement that is the body of an `if`/loop/`with` or a
    /// `label:` item — a Statement position, where a LexicalDeclaration is not
    /// allowed. `let` there must be an ordinary identifier (so `if (x) let\ny=1`
    /// is `let;` + `y=1` via ASI), not the start of a `let`-declaration. Consumed
    /// (read and cleared) at the top of parseStatement so it applies only to that
    /// one statement and never leaks into a nested block's StatementList.
    suppress_let_decl: bool = false,
    /// True where a `using`/`await using` declaration statement is permitted: the
    /// StatementList of a Block (incl. function bodies, which parse via
    /// parseBlock) and the top level of a Module. It is NOT permitted at the top
    /// level of a Script or directly in a switch CaseClause/DefaultClause (a
    /// nested Block there re-enables it). The for-of head is a separate path.
    using_allowed: bool = false,
    /// Active labels in the current function body. A function boundary resets
    /// these because `break`/`continue` cannot target labels outside the
    /// function it appears in.
    active_labels: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Labels immediately wrapping the next statement. If that statement is an
    /// iteration statement, those labels become valid labeled-continue targets.
    pending_labels: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Labels of currently enclosing iteration statements.
    continue_labels: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Best-effort byte offset for the most recent parse failure. The parser
    /// still returns compact Zig error tags, but embedders can combine this with
    /// `sourceLocationAt` to report useful source diagnostics.
    last_error_offset: ?usize = null,
    last_error_reason: ?DiagnosticReason = null,
    last_error_token: ?DiagnosticToken = null,
    /// Statement locations accumulated while parsing, including nested function
    /// bodies. Consumers copy these entries into their context-owned registry
    /// before the parser value leaves scope.
    statement_locations: std.ArrayListUnmanaged(StatementLocation) = .empty,

    pub fn init(arena: std.mem.Allocator, source: []const u8) ParseError!Parser {
        var ignored: ?SourceLocation = null;
        return initWithScratchDiagnostic(arena, arena, source, &ignored);
    }

    pub fn initWithScratch(arena: std.mem.Allocator, scratch_allocator: std.mem.Allocator, source: []const u8) ParseError!Parser {
        var ignored: ?SourceLocation = null;
        return initWithScratchDiagnostic(arena, scratch_allocator, source, &ignored);
    }

    pub fn initWithDiagnostic(arena: std.mem.Allocator, source: []const u8, diagnostic: *?SourceLocation) ParseError!Parser {
        return initWithScratchDiagnostic(arena, arena, source, diagnostic);
    }

    pub fn initWithScratchDiagnostic(arena: std.mem.Allocator, scratch_allocator: std.mem.Allocator, source: []const u8, diagnostic: *?SourceLocation) ParseError!Parser {
        diagnostic.* = null;
        const lx = lex.Lexer.init(arena, source);
        var parser: Parser = .{
            .tokens = .empty,
            .arena = arena,
            .token_allocator = arena,
            .lexer = lx,
            .scratch_allocator = scratch_allocator,
            .source = source,
            .html_comment_offset = lx.htmlCommentOffset(),
            .stack_floor = stack_scan.nestingStackFloor(),
        };
        parser.fillTokenRun(.div);
        if (parser.tokens.items.len != 0) parser.current_token = &parser.tokens.items[0];
        return parser;
    }

    fn secureHashState(self: *Parser) *SecureHashState {
        return self.shared_secure_hash_state orelse &self.secure_hash_state;
    }

    fn streamError(self: *Parser, fallback: ?ParseError) ?ParseError {
        const html_offset = if (self.module) self.html_comment_offset else null;
        if (html_offset) |offset| {
            if (self.lex_error == null or offset <= self.lex_error_offset) {
                self.last_error_offset = offset;
                self.last_error_reason = null;
                self.last_error_token = null;
                return ParseError.UnexpectedToken;
            }
        }
        if (self.lex_error) |err| {
            self.last_error_offset = @min(self.lex_error_offset, self.source.len);
            self.last_error_reason = null;
            self.last_error_token = null;
            return err;
        }
        return fallback;
    }

    fn secureStringMap(self: *Parser, comptime Value: type) SecureStringMapUnmanaged(Value) {
        return .{ .state = self.secureHashState() };
    }

    /// Attach the parse to an existing realm's domain-separated secret source.
    /// This remains lazy: candidate-free parses derive no key and allocate no
    /// declaration-name table.
    pub fn useRealmHashKeys(self: *Parser, realm_shape: *Shape) void {
        const state = self.secureHashState();
        std.debug.assert(state.context == null);
        state.realm_shape = realm_shape;
    }

    fn validateRegexLiteral(self: *Parser, pattern: []const u8, flags: []const u8, offset: usize) ParseError!void {
        var diagnostic: ?regex.CompileErrorReason = null;
        if (self.regex_validation_arena) |validation_arena| {
            validateRegexLiteralWithArena(validation_arena, pattern, flags, &diagnostic) catch |err| {
                if (diagnostic) |reason| return self.failWithReasonAt(regexDiagnosticReason(reason), offset);
                return self.fail(err);
            };
            return;
        }

        // `parseExpression` is also a public entry point. When it is used
        // directly, keep the same bounded validation lifetime without requiring
        // the caller to establish the Program/Module parse scope first.
        var validation_arena = std.heap.ArenaAllocator.init(self.scratch_allocator);
        defer validation_arena.deinit();
        validateRegexLiteralWithArena(&validation_arena, pattern, flags, &diagnostic) catch |err| {
            if (diagnostic) |reason| return self.failWithReasonAt(regexDiagnosticReason(reason), offset);
            return self.fail(err);
        };
    }

    /// Source slice from the start position of the token at `start_pos` through
    /// the end of the most recently consumed token (`self.pos - 1`). Used to
    /// capture a function's exact definition text for `Function.prototype.toString`.
    fn sourceFrom(self: *Parser, start_pos: usize) []const u8 {
        if (self.source.len == 0 or self.pos == 0) return "";
        const lo = self.tokenAt(start_pos).pos;
        const hi = self.tokenAt(self.pos - 1).end;
        if (lo > hi or hi > self.source.len) return "";
        return self.source[lo..hi];
    }

    fn appendNextToken(self: *Parser, goal: lex.LexicalGoal) void {
        if (self.lex_error != null) return;
        if (self.tokens.items.len != 0 and self.tokens.items[self.tokens.items.len - 1].kind == .eof) return;
        const token = self.lexer.nextWithGoal(goal) catch |err| {
            self.lex_error = err;
            self.lex_error_offset = self.lexer.errorOffset();
            return;
        };
        self.tokens.append(self.token_allocator, token) catch {
            self.lex_error = error.OutOfMemory;
            self.lex_error_offset = token.pos;
            return;
        };
    }

    /// Lex one parser-selected token and then batch the unambiguous run that
    /// follows it. InputElementDiv makes `/` a one-token boundary, so the loop
    /// never crosses the next place where grammar context is required. Ordinary
    /// slash-free source keeps the eager lexer's tight linear loop instead of
    /// paying a parser/allocator round trip per token.
    fn fillTokenRun(self: *Parser, first_goal: lex.LexicalGoal) void {
        self.appendNextToken(first_goal);
        scan: while (self.lex_error == null and self.tokens.items.len != 0) {
            switch (self.tokens.items[self.tokens.items.len - 1].kind) {
                .eof, .slash, .slash_eq => break :scan,
                else => self.appendNextToken(.div),
            }
        }
        if (self.pos < self.tokens.items.len) self.current_token = &self.tokens.items[self.pos];
        self.html_comment_offset = self.lexer.htmlCommentOffset();
    }

    fn ensureToken(self: *Parser, index: usize) void {
        while (self.tokens.items.len <= index and self.lex_error == null) self.appendNextToken(.automatic);
        if (self.pos < self.tokens.items.len) self.current_token = &self.tokens.items[self.pos];
        self.html_comment_offset = self.lexer.htmlCommentOffset();
    }

    fn tokenAt(self: *Parser, index: usize) Token {
        self.ensureToken(index);
        if (index < self.tokens.items.len) return self.tokens.items[index];
        return .{
            .kind = .eof,
            .text = "",
            .pos = @min(self.lex_error_offset, self.source.len),
            .end = @min(self.lex_error_offset, self.source.len),
        };
    }

    inline fn cur(self: *const Parser) Token {
        return self.current_token.*;
    }

    fn curRegExp(self: *Parser) Token {
        if (self.tokens.items.len <= self.pos) self.fillTokenRun(.regexp);
        if (self.pos + 1 == self.tokens.items.len and
            (self.tokens.items[self.pos].kind == .slash or self.tokens.items[self.pos].kind == .slash_eq))
        {
            const token = self.lexer.reinterpretSlashAsRegex(self.tokens.items[self.pos]) catch |err| {
                self.lex_error = err;
                self.lex_error_offset = self.lexer.errorOffset();
                return self.tokenAt(self.pos);
            };
            self.tokens.items[self.pos] = token;
            self.current_token = &self.tokens.items[self.pos];
        }
        return self.current_token.*;
    }
    fn containsLineTerminator(bytes: []const u8) bool {
        if (std.mem.indexOfScalar(u8, bytes, '\n') != null) return true;
        if (std.mem.indexOfScalar(u8, bytes, '\r') != null) return true;
        var i: usize = 0;
        while (i + 2 < bytes.len) : (i += 1) {
            if (bytes[i] == 0xe2 and bytes[i + 1] == 0x80 and
                (bytes[i + 2] == 0xa8 or bytes[i + 2] == 0xa9))
                return true;
        }
        return false;
    }

    fn hasLineTerminatorBefore(self: *Parser, ahead: usize) bool {
        const idx = self.pos + ahead;
        if (idx == 0) return false;
        const current = self.tokenAt(idx);
        if (idx >= self.tokens.items.len) return false;
        const gap = self.source[self.tokenAt(idx - 1).end..current.pos];
        return containsLineTerminator(gap);
    }

    fn fail(self: *Parser, err: ParseError) ParseError {
        self.last_error_offset = if (self.pos < self.tokens.items.len) self.cur().pos else self.source.len;
        self.last_error_reason = null;
        self.last_error_token = null;
        return err;
    }

    fn failWithReasonAt(self: *Parser, reason: DiagnosticReason, offset: usize) ParseError {
        self.last_error_reason = reason;
        self.last_error_token = null;
        self.last_error_offset = offset;
        return reason.parseError();
    }

    fn failWithToken(self: *Parser, reason: DiagnosticReason, token: Token) ParseError {
        if (token.kind == .eof) {
            const eof_reason: DiagnosticReason = if (reason.parseError() == ParseError.ExpectedToken)
                .unexpected_end_of_script
            else
                .unexpected_end_of_expression;
            return self.failWithReasonAt(eof_reason, token.pos);
        }
        const err = self.failWithReasonAt(reason, token.pos);
        self.last_error_token = .{
            .kind = switch (token.kind) {
                .identifier => if (isReservedWord(token.text)) .keyword else .identifier,
                .number => if (token.is_bigint) .token else .number,
                .string => .string,
                else => .token,
            },
            // Preserve the raw spelling, including identifier escapes and string
            // quotes. The source has the same lifetime as the parser diagnostic.
            .text = self.source[token.pos..token.end],
        };
        return err;
    }

    fn failWithTokenReason(self: *Parser, reason: DiagnosticReason) ParseError {
        return self.failWithToken(reason, self.cur());
    }

    fn failWithTokenDetail(self: *Parser, reason: DiagnosticReason, token: Token, detail: []const u8) ParseError {
        const err = self.failWithToken(reason, token);
        self.last_error_token.?.detail = detail;
        return err;
    }

    fn failWithDiagnosticAt(
        self: *Parser,
        reason: DiagnosticReason,
        kind: DiagnosticTokenKind,
        text: []const u8,
        detail: ?[]const u8,
        offset: usize,
    ) ParseError {
        const err = self.failWithReasonAt(reason, offset);
        self.last_error_token = .{ .kind = kind, .text = text, .detail = detail };
        return err;
    }

    fn sourceOffsetForSlice(self: *const Parser, text: []const u8, fallback: usize) usize {
        if (text.len == 0) return fallback;
        const source_start = @intFromPtr(self.source.ptr);
        const text_start = @intFromPtr(text.ptr);
        if (text_start < source_start) return fallback;
        const relative = text_start - source_start;
        if (relative > self.source.len or text.len > self.source.len - relative) return fallback;
        return relative;
    }

    fn statementStartOffset(self: *const Parser, node: *const Node) usize {
        var index = self.statement_locations.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.statement_locations.items[index];
            if (entry.node == node) return entry.location.byte_offset;
        }
        return self.cur().pos;
    }

    fn failWithNameAt(self: *Parser, reason: DiagnosticReason, name: []const u8, fallback_offset: usize) ParseError {
        return self.failWithDiagnosticAt(reason, .identifier, name, null, self.sourceOffsetForSlice(name, fallback_offset));
    }

    pub fn diagnosticMessage(self: *const Parser, allocator: std.mem.Allocator, reason: DiagnosticReason) std.mem.Allocator.Error![]const u8 {
        const token = self.last_error_token orelse return reason.message();
        if (reason == .private_field_delete)
            return std.fmt.allocPrint(allocator, "Cannot delete private field {s}.", .{token.text});
        if (reason == .undeclared_private_name)
            return std.fmt.allocPrint(allocator, "Cannot reference undeclared private names: \"{s}\"", .{token.text});
        if (reason == .escaped_keyword)
            return std.fmt.allocPrint(allocator, "Unexpected escaped characters in keyword token: '{s}'", .{token.text});
        if (reason == .undeclared_label)
            return std.fmt.allocPrint(allocator, "Cannot use the undeclared label '{s}'.", .{token.text});
        if (reason == .continue_non_loop_label)
            return std.fmt.allocPrint(allocator, "Cannot continue to the label '{s}' as it is not targeting a loop.", .{token.text});
        if (reason == .duplicate_label)
            return std.fmt.allocPrint(allocator, "Unexpected token '{s}'. Attempted to redeclare the label '{s}'.", .{ token.text, token.detail.? });
        if (reason == .duplicate_let_binding)
            return std.fmt.allocPrint(allocator, "Cannot declare a let variable twice: '{s}'.", .{token.text});
        if (reason == .duplicate_const_binding)
            return std.fmt.allocPrint(allocator, "Cannot declare a const variable twice: '{s}'.", .{token.text});
        if (reason == .duplicate_class_binding)
            return std.fmt.allocPrint(allocator, "Cannot declare a class twice: '{s}'.", .{token.text});
        if (reason == .duplicate_catch_binding)
            return std.fmt.allocPrint(allocator, "Unexpected identifier '{s}'. Cannot declare a lexical variable twice: '{s}'.", .{ token.text, token.text });
        if (reason == .duplicate_catch_destructuring)
            return std.fmt.allocPrint(allocator, "Unexpected token '{s}'. Cannot declare a lexical variable twice: '{s}'.", .{ token.text, token.detail.? });
        if (reason == .catch_function_shadow)
            return std.fmt.allocPrint(allocator, "Cannot declare a function that shadows a let/const/class/function variable '{s}'.", .{token.text});
        if (reason == .function_keyword_name)
            return std.fmt.allocPrint(allocator, "Cannot use the keyword '{s}' as a function name.", .{token.text});
        if (reason == .strict_function_name)
            return std.fmt.allocPrint(allocator, "'{s}' is not a valid function name in strict mode.", .{token.text});
        if (reason == .abbreviated_destructuring_keyword)
            return std.fmt.allocPrint(allocator, "Cannot use abbreviated destructuring syntax for keyword '{s}'.", .{token.text});
        if (reason == .lexical_keyword_binding)
            return std.fmt.allocPrint(allocator, "Cannot use the keyword '{s}' as a lexical variable name.", .{token.text});
        if (reason == .strict_destructure_binding)
            return std.fmt.allocPrint(allocator, "Cannot destructure to a variable named '{s}' in strict mode.", .{token.text});
        if (reason == .shorthand_keyword)
            return std.fmt.allocPrint(allocator, "Cannot use the keyword '{s}' as a shorthand property name.", .{token.text});
        const noun = if (token.kind == .string) "string literal" else @tagName(token.kind);
        const quote = if (token.kind == .string) "" else "'";
        if (reason == .unexpected_token or reason == .expected_token)
            return std.fmt.allocPrint(allocator, "Unexpected {s} {s}{s}{s}", .{ noun, quote, token.text, quote });
        return std.fmt.allocPrint(allocator, "Unexpected {s} {s}{s}{s}. {s}", .{ noun, quote, token.text, quote, reason.message() });
    }

    pub fn errorLocation(self: *const Parser) SourceLocation {
        const offset = self.last_error_offset orelse if (self.pos < self.tokens.items.len) self.tokens.items[self.pos].pos else self.source.len;
        return sourceLocationAt(self.source, offset);
    }

    /// CreateDynamicFunction appends a newline, `}`, and `)` after the caller's
    /// body. If those synthetic tokens are where an incomplete caller body is
    /// finally rejected, classify the failure as end-of-script while retaining
    /// the exact assembled-source location for debugger metadata.
    pub fn classifySyntheticSuffixAsEndOfScript(self: *Parser, suffix_start: usize, err: ParseError) void {
        if (self.errorLocation().byte_offset < suffix_start) return;
        self.last_error_reason = switch (err) {
            ParseError.ExpectedToken => .unexpected_end_of_script,
            ParseError.UnexpectedToken => .unexpected_end_of_expression,
            else => return,
        };
        self.last_error_token = null;
    }

    fn statementLocationAt(self: *Parser, raw_offset: usize) ParseError!SourceLocation {
        const offset = @min(raw_offset, self.source.len);
        // Recursive-descent may rewind inside one statement while refining cover
        // grammars, but it must never enter a later statement behind an earlier
        // entry. Reject a future invariant violation instead of underflowing or
        // reintroducing attacker-controlled prefix rescans.
        if (offset < self.statement_location_cursor.byte_offset)
            return self.fail(ParseError.UnexpectedToken);

        var location = self.statement_location_cursor;
        var cursor = location.byte_offset;
        while (cursor < offset) {
            if (lex.lineTerminatorLen(self.source, cursor)) |len| {
                // A token cannot start inside a multi-byte line terminator. Keep
                // that lexer/parser contract executable in release builds.
                if (len > offset - cursor) return self.fail(ParseError.UnexpectedToken);
                cursor += len;
                location.line += 1;
                location.column = 1;
            } else {
                cursor += 1;
                location.column += 1;
            }
        }
        location.byte_offset = offset;
        self.statement_location_cursor = location;
        return location;
    }

    fn statementLocationCheckpoint(self: *const Parser) StatementLocationCheckpoint {
        return .{
            .cursor = self.statement_location_cursor,
            .published_len = self.statement_locations.items.len,
        };
    }

    fn restoreStatementLocationCheckpoint(self: *Parser, checkpoint: StatementLocationCheckpoint) void {
        self.statement_location_cursor = checkpoint.cursor;
        self.statement_locations.items.len = checkpoint.published_len;
    }

    /// Whether no line terminator separates the token `ahead` positions away from
    /// the one just before it (the restricted-production check, e.g. `using` may
    /// not be followed by a newline before its binding identifier).
    fn noNewlineBefore(self: *Parser, ahead: usize) bool {
        return !self.hasLineTerminatorBefore(ahead);
    }

    fn consumeStatementTerminator(self: *Parser) ParseError!void {
        return self.consumeStatementTerminatorWithReason(.unexpected_token);
    }

    inline fn consumeStatementTerminatorWithReason(self: *Parser, reason: DiagnosticReason) ParseError!void {
        if (self.match(.semicolon)) return;
        if (self.check(.eof) or self.check(.rbrace)) return;
        if (self.hasLineTerminatorBefore(0)) return;
        return self.failWithTokenReason(reason);
    }

    fn advance(self: *Parser) Token {
        const t = self.cur();
        if (t.kind == .eof) return t;
        self.pos += 1;
        if (self.tokens.items.len <= self.pos) self.fillTokenRun(.div);
        self.current_token = if (self.pos < self.tokens.items.len) &self.tokens.items[self.pos] else &synthetic_eof_token;
        return t;
    }

    inline fn check(self: *Parser, kind: TokenKind) bool {
        return self.cur().kind == kind;
    }

    fn match(self: *Parser, kind: TokenKind) bool {
        if (self.check(kind)) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn expect(self: *Parser, kind: TokenKind) ParseError!void {
        if (!self.match(kind)) return self.failWithTokenReason(.expected_token);
    }

    fn expectWithTokenReason(self: *Parser, kind: TokenKind, reason: DiagnosticReason) ParseError!void {
        if (!self.match(kind)) return self.failWithTokenReason(reason);
    }

    fn isKeyword(t: Token, word: []const u8) bool {
        return t.kind == .identifier and std.mem.eql(u8, t.text, word);
    }

    /// The current token is the contextual keyword `word` (an identifier token).
    /// A contextual keyword written with a Unicode escape (`from`) is never
    /// the keyword — it is an ordinary identifier — so an escaped form never
    /// matches (e.g. `import {} from "x"` is a SyntaxError).
    fn isContextual(self: *Parser, word: []const u8) bool {
        return !self.cur().escaped_identifier and isKeyword(self.cur(), word);
    }
    /// Alias of `isContextual` for readability at peek sites.
    fn checkContextual(self: *Parser, word: []const u8) bool {
        return self.isContextual(word);
    }
    /// Consume a contextual keyword `word` or fail.
    fn expectContextual(self: *Parser, word: []const u8) ParseError!void {
        if (!self.isContextual(word)) return self.fail(ParseError.UnexpectedToken);
        _ = self.advance();
    }
    /// The token `ahead` positions from the cursor has kind `kind`.
    fn peekIs(self: *Parser, ahead: usize, kind: TokenKind) bool {
        const idx = self.pos + ahead;
        return self.tokenAt(idx).kind == kind;
    }

    /// A label after `break`/`continue` on the same logical line.
    fn optionalLabel(self: *Parser) ?[]const u8 {
        if (self.hasLineTerminatorBefore(0)) return null;
        if (self.check(.identifier) and !self.isForbiddenLabelName(self.cur().text)) {
            return self.advance().text;
        }
        return null;
    }

    fn labelListContains(labels: []const []const u8, label: []const u8) bool {
        for (labels) |candidate| {
            if (std.mem.eql(u8, candidate, label)) return true;
        }
        return false;
    }

    const LabelContext = struct {
        active: std.ArrayListUnmanaged([]const u8),
        pending: std.ArrayListUnmanaged([]const u8),
        continue_targets: std.ArrayListUnmanaged([]const u8),
    };

    /// Move the complete label lists aside before entering a fresh control-flow
    /// boundary. Truncating them would let nested labels overwrite the outer
    /// lists' retained backing slots, so restoring only the old lengths would
    /// resurrect the wrong names (#950).
    fn takeLabelContext(self: *Parser) LabelContext {
        const saved = LabelContext{
            .active = self.active_labels,
            .pending = self.pending_labels,
            .continue_targets = self.continue_labels,
        };
        self.active_labels = .empty;
        self.pending_labels = .empty;
        self.continue_labels = .empty;
        return saved;
    }

    fn restoreLabelContext(self: *Parser, saved: LabelContext) void {
        self.active_labels = saved.active;
        self.pending_labels = saved.pending;
        self.continue_labels = saved.continue_targets;
    }

    fn statementCanInheritPendingLabels(self: *Parser) bool {
        const t = self.cur();
        if (t.kind != .identifier) return false;
        if (std.mem.eql(u8, t.text, "while") or
            std.mem.eql(u8, t.text, "do") or
            std.mem.eql(u8, t.text, "for"))
            return true;
        return self.peekKind(1) == .colon and !self.isForbiddenLabelName(t.text);
    }

    /// Keywords that can NEVER be a binding identifier, in any mode (the
    /// unconditional ReservedWords). Excludes the contextual ones — `let`,
    /// `yield`, `await`, `static`, `async`, `of`, `get`/`set`, `implements`,
    /// `undefined`, `eval`/`arguments`, … — which are legal binding names in at
    /// least some contexts, so this never false-rejects them.
    fn isAlwaysReservedBinding(text: []const u8) bool {
        return bindingKeywordClass(text).always_reserved;
    }

    fn isReservedWord(text: []const u8) bool {
        return bindingKeywordClass(text).grammar_reserved;
    }

    fn isStrictReservedBinding(text: []const u8) bool {
        return bindingKeywordClass(text).strict_reserved;
    }

    fn isForbiddenBindingName(self: *Parser, text: []const u8) bool {
        const keyword = bindingKeywordClass(text);
        return keyword.always_reserved or
            ((self.module or self.in_async) and std.mem.eql(u8, text, "await")) or
            (self.in_generator and std.mem.eql(u8, text, "yield")) or
            (self.strict and (keyword.strict_reserved or isEvalOrArguments(text)));
    }

    fn isForbiddenLabelName(self: *Parser, text: []const u8) bool {
        const keyword = bindingKeywordClass(text);
        return keyword.always_reserved or
            ((self.module or self.in_async) and std.mem.eql(u8, text, "await")) or
            (self.in_generator and std.mem.eql(u8, text, "yield")) or
            (self.strict and keyword.strict_reserved);
    }

    fn isEscapedReservedWord(self: *Parser, t: Token) bool {
        const keyword = bindingKeywordClass(t.text);
        return t.kind == .identifier and t.escaped_identifier and
            (keyword.always_reserved or (self.strict and keyword.strict_reserved));
    }

    fn letDeclAhead(self: *Parser) bool {
        // A `let` written with a Unicode escape (`let`) is never the keyword,
        // so it cannot begin a LexicalDeclaration — it is an ordinary identifier.
        if (self.cur().escaped_identifier) return false;
        if (!isKeyword(self.cur(), "let")) return false;
        return switch (self.peekKind(1)) {
            .lbrace => self.noNewlineBefore(1),
            .lbracket => true,
            // `let` followed by a BindingIdentifier begins a LexicalDeclaration.
            // The contextual keywords `let`/`yield`/`await` are BindingIdentifiers
            // (then rejected as bound names where illegal), so `let let`/`let yield`
            // is a declaration — not `let` the identifier followed by an operator
            // keyword (`let in x`, `let instanceof X`), which stays an expression.
            .identifier => blk: {
                const t1 = self.tokenAt(self.pos + 1).text;
                break :blk !isReservedWord(t1) or std.mem.eql(u8, t1, "let") or
                    std.mem.eql(u8, t1, "yield") or std.mem.eql(u8, t1, "await");
            },
            else => false,
        };
    }

    fn alloc(self: *Parser, node: Node) ParseError!*Node {
        const p = try self.arena.create(Node);
        p.* = node;
        return p;
    }

    fn markParenWrapped(self: *Parser, node: *Node) ParseError!void {
        try self.paren_wrapped.put(self.arena, self.secureHashState(), @intFromPtr(node), {});
    }

    fn isParenWrapped(self: *Parser, node: *Node) bool {
        return self.paren_wrapped.contains(self.secureHashState(), @intFromPtr(node));
    }

    fn parenWrappedIdentifierBefore(self: *Parser, pos: usize, name: []const u8) bool {
        if (pos == 0 or self.tokens.items[pos - 1].kind != .rparen) return false;
        var i = pos;
        var depth: usize = 0;
        var saw_ident = false;
        var ident_matches = false;
        while (i > 0) {
            i -= 1;
            const t = self.tokens.items[i];
            switch (t.kind) {
                .rparen => depth += 1,
                .lparen => {
                    if (depth == 0) return false;
                    depth -= 1;
                    if (depth == 0) return saw_ident and ident_matches;
                },
                .identifier => {
                    if (depth != 1 or saw_ident) return false;
                    saw_ident = true;
                    ident_matches = std.mem.eql(u8, t.text, name);
                },
                else => if (depth == 1) return false,
            }
        }
        return false;
    }

    /// NamedEvaluation (applied at parse time): an *anonymous* function/class
    /// literal bound to a name takes that name (`var f = function(){}` ⇒
    /// `f.name === "f"`). Doing it on the AST means it holds whether the program
    /// runs on the VM or the tree-walker. A named function expression keeps its
    /// own name. (Runtime sites — destructuring/param defaults — name anon
    /// values too, for the dynamic cases this can't see.)
    fn nameAnon(node: *Node, name: []const u8) void {
        if (name.len == 0) return;
        switch (node.*) {
            .function => |f| {
                if (f.name.len == 0) f.name = name;
            },
            .class_expr => {
                if (node.class_expr.name.len == 0) node.class_expr.inferred_name = name;
            },
            else => {},
        }
    }

    // ----- program / statements -------------------------------------------

    pub fn parseProgram(self: *Parser) ParseError!*Node {
        const program = if (self.regex_validation_arena != null)
            self.parseProgramInner()
        else
            parse: {
                var validation_arena = std.heap.ArenaAllocator.init(self.scratch_allocator);
                defer validation_arena.deinit();
                self.regex_validation_arena = &validation_arena;
                defer self.regex_validation_arena = null;
                break :parse self.parseProgramInner();
            } catch |err| return self.streamError(err).?;
        if (self.streamError(null)) |err| return err;
        return program;
    }

    fn parseProgramInner(self: *Parser) ParseError!*Node {
        // A top-level `"use strict"` directive prologue makes the whole program
        // (and every function in it, by inheritance) strict.
        var i: usize = self.pos;
        while (self.tokenAt(i).kind == .string) {
            if (std.mem.eql(u8, self.tokenAt(i).text, "use strict")) {
                self.strict = true;
                break;
            }
            i += 1;
            if (self.tokenAt(i).kind == .semicolon) i += 1;
        }
        var stmts: std.ArrayListUnmanaged(*Node) = .empty;
        while (!self.check(.eof)) {
            try stmts.append(self.arena, try self.parseStatement());
        }
        // Early error: no duplicate lexically-declared names in a scope.
        var lexical_scope = self.lexicalScope();
        defer lexical_scope.undo.deinit(self.scratch_allocator);
        try self.checkLexicalDupes(stmts.items, false, &lexical_scope);
        lexical_scope.assertBalanced();
        try self.checkPrivateUsesInProgram(stmts.items);
        // A CoverInitializedName (`{ a = 1 }`) never refined to a pattern is an
        // early error.
        try self.checkPendingCoverErrors();
        return self.alloc(.{ .program = stmts.items });
    }

    fn checkPendingCoverErrors(self: *Parser) ParseError!void {
        if (self.pending_cover_inits.count() > 0) return self.fail(ParseError.UnexpectedToken);
        // Object Initializer early errors are deferred until cover grammar has
        // been refined: repeated __proto__ keys are legal in assignment patterns.
        // Pick the first remaining violation, not hash-table iteration order.
        var duplicate_offset: ?usize = null;
        var offsets = self.pending_proto_dup.index.valueIterator();
        while (offsets.next()) |offset| {
            duplicate_offset = @min(duplicate_offset orelse offset.*, offset.*);
        }
        if (duplicate_offset) |offset| return self.failWithReasonAt(.duplicate_proto, offset);
    }

    /// Early-error check (13.2.1.1 et al.): a scope's lexically-declared names
    /// (`let`/`const`/`class`, plus block-level `function`s) must be unique. This
    /// flags only *same-scope* duplicates — always a SyntaxError — so valid
    /// shadowing in nested scopes is never rejected. `funcs_lexical` is true for a
    /// block/switch scope (where a function declaration is lexical) and false for
    /// a function-body/script top level (where it is var-scoped). Incomplete
    /// traversal only misses errors; it never produces a false positive.
    fn checkLexicalDupes(self: *Parser, stmts: []const *Node, funcs_lexical: bool, scope: *LexicalScope) ParseError!void {
        // name → is the declaration "rigid"? A let/const/class — or an async/
        // generator function — is rigid: any same-name collision is an error.
        // Two *plain* function declarations in a sloppy block are allowed
        // (Annex B.3.3), so a collision is reported only when a rigid one is
        // involved — which keeps the rigid rule free of false positives. That
        // holds only if the caller classifies the scope correctly: a scope whose
        // top-level functions are var-scoped must pass `funcs_lexical = false`
        // (#929 was a static block passing `true`).
        var seen = self.secureStringMap(bool);
        for (stmts) |s| {
            switch (s.*) {
                .var_decl => |d| if (d.kind != .@"var") try self.addDecl(&seen, d.name, true),
                .destructure_decl => |d| if (d.kind != .@"var") {
                    var names: std.ArrayListUnmanaged([]const u8) = .empty;
                    try self.addPatternNames(&names, d.pattern);
                    for (names.items) |n| try self.addDecl(&seen, n, true);
                },
                .decl_group => |g| for (g) |d2| {
                    if (d2.* == .var_decl and d2.var_decl.kind != .@"var") try self.addDecl(&seen, d2.var_decl.name, true);
                    if (d2.* == .destructure_decl and d2.destructure_decl.kind != .@"var") {
                        var names: std.ArrayListUnmanaged([]const u8) = .empty;
                        try self.addPatternNames(&names, d2.destructure_decl.pattern);
                        for (names.items) |n| try self.addDecl(&seen, n, true);
                    }
                },
                // A block-level function declaration is "rigid" (no duplicate
                // allowed) when it is a generator/async — or in strict mode, which
                // has no Annex B.3.3 plain-function duplicate allowance, so
                // `{ function f(){} function f(){} }` is a strict SyntaxError.
                .func_decl => |fnode| if (funcs_lexical and fnode.name.len > 0)
                    try self.addDecl(&seen, fnode.name, fnode.is_async or fnode.is_generator or self.strict),
                .labeled_stmt => if (funcs_lexical) {
                    if (statementFunctionDecl(s)) |fnode| if (fnode.name.len > 0)
                        try self.addDecl(&seen, fnode.name, fnode.is_async or fnode.is_generator or self.strict);
                },
                else => {},
            }
        }
        // Early error (Block 14.2.1, Script 16.1.1, FunctionBody 15.2.1): a scope's
        // LexicallyDeclaredNames must not intersect its VarDeclaredNames — e.g.
        // `{ var f; const f }` or `let x; { var x; }`. Var names hoist out of nested
        // blocks/control-flow (but not functions).
        //
        // #928: this used to re-collect the var names of the WHOLE subtree at every
        // scope, so a chain of blocks each declaring something lexical re-walked
        // the remaining subtree once per level into the never-released arena --
        // quadratic in time and retained memory from linear source. It now opens
        // this scope's lexical names in one shared map and tests each `var` as the
        // walk reaches it. A `var` conflicts with exactly the lexical names of the
        // scopes enclosing it up to its var scope, which is what that map holds at
        // that moment, so every conflict the subtree scan found is still found.
        scope.depth += 1;
        defer scope.depth -= 1;
        const mark = scope.undo.items.len;
        defer self.closeLexicalScope(scope, mark);
        var it = seen.iterator();
        while (it.next()) |entry| try self.openLexicalName(scope, entry.key_ptr.*);
        // At a function/script scope, top-level function declarations are
        // themselves var-scoped, so they take the var side of the check.
        if (!funcs_lexical) for (stmts) |s| {
            if (statementFunctionDecl(s)) |fnode| if (fnode.name.len > 0)
                try self.checkVarAgainstLexical(scope, fnode.name);
        };
        for (stmts) |s| try self.recurseScope(s, scope);
    }

    /// Early error (15.2.1 etc.): no element of a function's parameter BoundNames
    /// may also occur in the LexicallyDeclaredNames of its body —
    /// `function f(a){ let a; }`, `(a) => { const a = 1; }`, `({ m(a){ class a{} } })`
    /// are all SyntaxErrors. (A body `var a`/`function a(){}` is VarDeclared, not
    /// Lexical, so it may legally shadow a parameter, and a `let a` nested in an
    /// inner block has its own scope.) Applies to every function, method, and
    /// block-body arrow. The body of an expression-bodied arrow has no
    /// declarations, so nothing to check.
    fn checkParamBodyConflict(self: *Parser, params: []const ast.Param, body: *Node) ParseError!void {
        if (body.* != .block) return;
        // Only the function body's direct LexicallyDeclaredNames participate.
        // Most bodies contain no such declaration; reject that impossible case
        // before hashing an attacker-sized parameter list. Nested blocks are
        // separate lexical scopes and deliberately do not keep this path alive.
        var may_conflict = false;
        for (body.block) |statement| {
            if (hasDirectLexicalDeclaration(statement)) {
                may_conflict = true;
                break;
            }
        }
        if (!may_conflict) return;

        var pnames = self.secureStringMap(void);
        for (params) |p| {
            if (p.pattern) |pat| {
                var names: std.ArrayListUnmanaged([]const u8) = .empty;
                try self.addPatternNames(&names, pat);
                for (names.items) |n| if (n.len > 0) try pnames.put(self.arena, n, {});
            } else if (p.name.len > 0) try pnames.put(self.arena, p.name, {});
        }
        if (pnames.count() == 0) return;
        for (body.block) |s| switch (s.*) {
            .var_decl => |d| if (d.kind != .@"var" and pnames.contains(d.name)) {
                const reason: DiagnosticReason = if (d.init != null and d.init.?.* == .class_expr)
                    .duplicate_class_binding
                else
                    duplicateBindingReason(d.kind);
                return self.failWithNameAt(reason, d.name, self.statementStartOffset(s));
            },
            .destructure_decl => |d| if (d.kind != .@"var") {
                var names: std.ArrayListUnmanaged([]const u8) = .empty;
                try self.addPatternNames(&names, d.pattern);
                for (names.items) |n| if (pnames.contains(n))
                    return self.failWithNameAt(duplicateBindingReason(d.kind), n, self.statementStartOffset(s));
            },
            .decl_group => |g| for (g) |d2| {
                if (d2.* == .var_decl and d2.var_decl.kind != .@"var" and pnames.contains(d2.var_decl.name)) {
                    const reason: DiagnosticReason = if (d2.var_decl.init != null and d2.var_decl.init.?.* == .class_expr)
                        .duplicate_class_binding
                    else
                        duplicateBindingReason(d2.var_decl.kind);
                    return self.failWithNameAt(reason, d2.var_decl.name, self.statementStartOffset(s));
                }
                if (d2.* == .destructure_decl and d2.destructure_decl.kind != .@"var") {
                    var names: std.ArrayListUnmanaged([]const u8) = .empty;
                    try self.addPatternNames(&names, d2.destructure_decl.pattern);
                    for (names.items) |n| if (pnames.contains(n))
                        return self.failWithNameAt(duplicateBindingReason(d2.destructure_decl.kind), n, self.statementStartOffset(s));
                }
            },
            .class_expr => |c| if (c.name.len > 0 and pnames.contains(c.name))
                return self.failWithNameAt(.duplicate_class_binding, c.name, self.statementStartOffset(s)),
            else => {},
        };
    }

    fn hasDirectLexicalDeclaration(statement: *const Node) bool {
        return switch (statement.*) {
            .var_decl => |decl| decl.kind != .@"var",
            .destructure_decl => |decl| decl.kind != .@"var",
            .decl_group => |group| for (group) |decl| {
                if (hasDirectLexicalDeclaration(decl)) break true;
            } else false,
            .class_expr => |class| class.name.len > 0,
            else => false,
        };
    }

    /// Collect VarDeclaredNames reachable from `node` without crossing a function
    /// boundary: `var` declarations (incl. destructuring and `for` heads) hoist out
    /// of nested blocks and control-flow statements, so recurse through those but
    /// not into nested functions/classes. Block-level function declarations are
    /// *not* collected (they are lexical to their block per the static semantics).
    fn collectVarNames(self: *Parser, node: *Node, out: *SecureStringMapUnmanaged(void)) ParseError!void {
        try self.checkNesting();
        switch (node.*) {
            .var_decl => |d| if (d.kind == .@"var" and d.name.len > 0) try out.put(self.arena, d.name, {}),
            .destructure_decl => |d| if (d.kind == .@"var") try self.putPatternVarNames(d.pattern, out),
            .decl_group => |g| for (g) |d2| try self.collectVarNames(d2, out),
            .block => |b| for (b) |s| try self.collectVarNames(s, out),
            .if_stmt => |i| {
                try self.collectVarNames(i.consequent, out);
                if (i.alternate) |a| try self.collectVarNames(a, out);
            },
            .while_stmt => |w| try self.collectVarNames(w.body, out),
            .do_while_stmt => |w| try self.collectVarNames(w.body, out),
            .for_stmt => |f| {
                if (f.init) |ini| try self.collectVarNames(ini, out);
                try self.collectVarNames(f.body, out);
            },
            .for_in => |f| {
                if (f.decl_kind) |k| if (k == .@"var") try self.putPatternVarNames(f.target, out);
                try self.collectVarNames(f.body, out);
            },
            // A with environment changes name resolution, not declaration
            // ownership. Vars in its body still hoist through the statement.
            .with_stmt => |w| try self.collectVarNames(w.body, out),
            .labeled_stmt => |l| try self.collectVarNames(l.body, out),
            .try_stmt => |t| {
                try self.collectVarNames(t.block, out);
                if (t.catch_block) |c| try self.collectVarNames(c, out);
                if (t.finally_block) |fb| try self.collectVarNames(fb, out);
            },
            .switch_stmt => |sw| for (sw.cases) |cs| for (cs.body) |s| try self.collectVarNames(s, out),
            // func_decl / function / class bodies are separate var scopes.
            else => {},
        }
    }

    fn putPatternVarNames(self: *Parser, pattern: *Node, out: *SecureStringMapUnmanaged(void)) ParseError!void {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        try self.addPatternNames(&names, pattern);
        for (names.items) |n| if (n.len > 0) try out.put(self.arena, n, {});
    }

    /// A lexical binding target's BoundNames must be unique (`let [x, x]` etc.).
    /// The BoundNames of a *lexical* (`let`/`const`/`using`) for-in/of head must
    /// be unique and must not contain `let` — `for (let [x, x] of …)` and
    /// `for (const let of …)` are both early errors. Called only for lexical
    /// heads (plain `var` permits both).
    fn checkNoDuplicateBindings(self: *Parser, target: *Node) ParseError!void {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        try self.addPatternNames(&names, target);
        var seen = self.secureStringMap(void);
        for (names.items) |n| {
            if (n.len == 0) continue;
            if (std.mem.eql(u8, n, "let")) return ParseError.UnexpectedToken;
            if (seen.contains(n)) return ParseError.UnexpectedToken;
            try seen.put(self.arena, n, {});
        }
    }

    fn checkNoDuplicateLexicalDeclNames(self: *Parser, decl: *Node) ParseError!void {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        try self.collectLexicalDeclNames(decl, &names);
        var seen = self.secureStringMap(void);
        for (names.items) |n| {
            if (n.len == 0) continue;
            if (std.mem.eql(u8, n, "let")) return ParseError.UnexpectedToken;
            if (seen.contains(n)) return ParseError.UnexpectedToken;
            try seen.put(self.arena, n, {});
        }
    }

    /// A lexical for-in/of head's BoundNames must not also appear among the
    /// VarDeclaredNames of the loop body — `for (const x of []) { var x; }` is an
    /// early error (the body's `var` would redeclare the per-iteration lexical
    /// binding). Called only for lexical heads.
    const ForBodyVars = struct {
        names: SecureStringMapUnmanaged(usize),
        count: usize = 0,
    };

    /// Record a var-scoped declaration of `name` for an enclosing lexical `for`.
    fn noteVarName(self: *Parser, name: []const u8) ParseError!void {
        const vars = self.for_body_vars orelse return;
        if (name.len == 0) return;
        vars.count += 1;
        try vars.names.put(self.scratch_allocator, name, vars.count);
    }

    fn noteVarPattern(self: *Parser, pattern: *Node) ParseError!void {
        if (self.for_body_vars == null) return;
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        try self.addPatternNames(&names, pattern);
        for (names.items) |name| try self.noteVarName(name);
    }

    /// Parse the body of a `for` whose lexical head binds `head`. Its BoundNames
    /// must not occur among the body's VarDeclaredNames (14.7.4.1, 14.7.5.1):
    /// `for (let x of a) { var x; }` is an early error. The outermost lexical
    /// `for` of a var scope owns the record of var declarations; a nested one
    /// joins it and only compares declaration order against its own start.
    fn parseLexicalForBody(self: *Parser, head: []const []const u8) ParseError!*Node {
        var own: ForBodyVars = undefined;
        const owns = self.for_body_vars == null;
        if (owns) {
            own = .{ .names = self.secureStringMap(usize) };
            self.for_body_vars = &own;
        }
        defer if (owns) {
            own.names.deinit(self.scratch_allocator);
            self.for_body_vars = null;
        };
        const started = self.for_body_vars.?.count;
        const body = try self.parseLoopBody();
        const vars = self.for_body_vars.?;
        for (head) |name| {
            const declared = vars.names.get(name) orelse continue;
            if (declared > started) return ParseError.UnexpectedToken;
        }
        return body;
    }

    /// Collect the BoundNames of a *lexical* (`let`/`const`/`using`) declaration
    /// node (single binding, destructuring, or `decl_group` of several). A `var`
    /// declaration contributes nothing (its names are VarDeclaredNames).
    fn collectLexicalDeclNames(self: *Parser, decl: *Node, out: *std.ArrayListUnmanaged([]const u8)) ParseError!void {
        switch (decl.*) {
            .var_decl => |d| if (d.kind != .@"var" and d.name.len > 0) try out.append(self.arena, d.name),
            .destructure_decl => |d| if (d.kind != .@"var") try self.addPatternNames(out, d.pattern),
            .decl_group => |g| for (g) |d2| try self.collectLexicalDeclNames(d2, out),
            else => {},
        }
    }

    fn addDecl(self: *Parser, seen: *SecureStringMapUnmanaged(bool), name: []const u8, rigid: bool) ParseError!void {
        if (seen.get(name)) |existing_rigid| {
            // A collision is an early error unless BOTH are plain functions.
            if (rigid or existing_rigid) return ParseError.UnexpectedToken;
            return; // plain-function vs plain-function: allowed
        }
        try seen.put(self.arena, name, rigid);
    }

    /// Descend into a statement's nested scopes, running `checkLexicalDupes` at
    /// each new lexical scope, and test every `var` against the lexical names
    /// currently open.
    ///
    /// This walk replaced two: the old scope descent, and the per-scope
    /// `collectVarNames` subtree scan. Where the two reached different children
    /// the union is taken arm by arm, and the children only the var scan reached
    /// (a `for` head, a declaration group) go through `checkDeclVarNames`, which
    /// does not open scopes -- so neither reach is widened.
    fn recurseScope(self: *Parser, node: *Node, scope: *LexicalScope) ParseError!void {
        try self.checkNesting();
        switch (node.*) {
            // A nested block is a new lexical scope. Its vars still hoist, and they
            // are still seen: `checkLexicalDupes` walks the block with this scope's
            // names left open beneath its own.
            .block => |b| try self.checkLexicalDupes(b, true, scope),
            .var_decl => |d| {
                if (d.kind == .@"var") try self.checkVarAgainstLexical(scope, d.name);
                if (d.init) |ini| try self.recurseScope(ini, scope);
            },
            .destructure_decl => |d| if (d.kind == .@"var") try self.checkPatternVarNames(d.pattern, scope),
            .decl_group => |g| for (g) |d2| try self.checkDeclVarNames(d2, scope),
            .if_stmt => |i| {
                try self.recurseScope(i.consequent, scope);
                if (i.alternate) |a| try self.recurseScope(a, scope);
            },
            .while_stmt => |w| try self.recurseScope(w.body, scope),
            .do_while_stmt => |w| try self.recurseScope(w.body, scope),
            .for_stmt => |f| {
                if (f.init) |ini| try self.checkDeclVarNames(ini, scope);
                try self.recurseScope(f.body, scope);
            },
            .for_in => |f| {
                if (f.decl_kind) |k| if (k == .@"var") try self.checkPatternVarNames(f.target, scope);
                try self.recurseScope(f.body, scope);
            },
            // `with` introduces an object environment but no lexical or var
            // declaration boundary. Its statement body remains in this walk.
            .with_stmt => |w| try self.recurseScope(w.body, scope),
            .labeled_stmt => |l| try self.recurseScope(l.body, scope),
            .try_stmt => |t| {
                try self.recurseScope(t.block, scope);
                if (t.catch_block) |c| try self.recurseCatchBlock(t.catch_param, c, scope);
                if (t.finally_block) |fb| try self.recurseScope(fb, scope);
            },
            .switch_stmt => |sw| {
                // The whole switch is one lexical (block) scope spanning all cases.
                var combined: std.ArrayListUnmanaged(*Node) = .empty;
                for (sw.cases) |cs| try combined.appendSlice(self.arena, cs.body);
                try self.checkLexicalDupes(combined.items, true, scope);
            },
            // Function bodies -- declarations, expressions, arrows, methods and
            // accessors alike -- are checked as each one finishes parsing
            // (`checkFunctionBodyDeclarations`), wherever it appears. Reaching
            // them from here found only the few positions this walk followed,
            // so a function in a call argument, literal or default was never
            // checked (#930 family 1); and descending here as well would walk
            // every nested body once per enclosing body, the #928 quadratic.
            .func_decl, .function => {},
            // Class members' bodies are function bodies too: see above.
            .class_expr => {},
            .expr_stmt => |e| try self.recurseScope(e, scope),
            else => {},
        }
    }

    /// Catch (14.15.1): a CatchParameter's BoundNames must not occur in its
    /// Block's VarDeclaredNames. Annex B.3.4 lifts that for a plain
    /// BindingIdentifier -- `catch (e) { var e; }` is legal -- so only a
    /// destructuring parameter opens its names here (#931).
    ///
    /// Done in this walk rather than at parse time in `checkCatchClause`: that
    /// would walk the whole catch block per clause, and nested destructuring
    /// catches would re-walk each other -- the #928 quadratic again. Opening the
    /// names in the shared scope instead tests each `var` once, and inherits the
    /// right function boundary for free: a `var` in a function nested in the
    /// catch block does not conflict. It also sees through an inner plain
    /// catch: in `catch ([e]) { try {} catch (e) { var e; } }` the `var` is
    /// allowed by the inner clause but still hoists into the outer one's block.
    fn recurseCatchBlock(self: *Parser, param: ?*Node, block: *Node, scope: *LexicalScope) ParseError!void {
        const pattern = param orelse return self.recurseScope(block, scope);
        if (pattern.* == .identifier) return self.recurseScope(block, scope);
        scope.depth += 1;
        defer scope.depth -= 1;
        const mark = scope.undo.items.len;
        defer self.closeLexicalScope(scope, mark);
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        try self.addPatternNames(&names, pattern);
        for (names.items) |name| try self.openLexicalName(scope, name);
        try self.recurseScope(block, scope);
    }

    /// The declaration arms of `collectVarNames`, for children the scope
    /// descent never followed. Tests var names only and opens no scope, so a
    /// class or function nested in a `for` head or a declaration group keeps
    /// exactly the reach it had.
    fn checkDeclVarNames(self: *Parser, node: *Node, scope: *const LexicalScope) ParseError!void {
        switch (node.*) {
            .var_decl => |d| if (d.kind == .@"var") try self.checkVarAgainstLexical(scope, d.name),
            .destructure_decl => |d| if (d.kind == .@"var") try self.checkPatternVarNames(d.pattern, scope),
            .decl_group => |g| for (g) |d2| try self.checkDeclVarNames(d2, scope),
            else => {},
        }
    }

    fn checkPatternVarNames(self: *Parser, pattern: *Node, scope: *const LexicalScope) ParseError!void {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        try self.addPatternNames(&names, pattern);
        for (names.items) |n| try self.checkVarAgainstLexical(scope, n);
    }

    /// A function body's lexical/var early errors (15.2.1 and the block rules
    /// within it), checked once, when the body has just been parsed.
    ///
    /// A function body is a fresh var scope, so no lexical name from an
    /// enclosing scope can collide with a `var` in it: the check needs nothing
    /// but the body itself. Running it here means every body is checked exactly
    /// once whatever expression contains it, and the parser's strictness is
    /// already the body's own -- Annex B.3.3 duplicate block functions are
    /// allowed only in sloppy code (#930 families 1 and 4).
    fn checkFunctionBodyDeclarations(self: *Parser, body: *Node) ParseError!void {
        if (body.* != .block) return;
        var scope = self.lexicalScope();
        defer scope.undo.deinit(self.scratch_allocator);
        try self.checkLexicalDupes(body.block, false, &scope);
        scope.assertBalanced();
    }

    /// Lexical names currently open for the var/lexical early error (#928),
    /// threaded as a parameter rather than held on `Parser`: the map carries a
    /// `*SecureHashState`, and `Parser` is returned by value with its shared
    /// hash state assigned after `init`, so a map captured at construction would
    /// dangle.
    const LexicalScope = struct {
        /// name -> depth of the innermost open scope declaring it lexically.
        names: SecureStringMapUnmanaged(usize),
        /// Lexical names already inventoried by the current var scope's caller.
        /// Modules need this because their top-level declaration pass also owns
        /// export validation; borrowing that map avoids hashing every import a
        /// second time merely to check vars nested in module statements (#949).
        var_scope_names: ?*const SecureStringMapUnmanaged(void) = null,
        /// Restores a shadowed name's outer depth instead of deleting it, since
        /// one name may be open at several depths at once.
        undo: std.ArrayListUnmanaged(Undo) = .empty,
        depth: usize = 0,
        /// Depth at which the current var scope began. A lexical name shallower
        /// than this belongs to an enclosing function, and a `var` here must not
        /// match it.
        var_base: usize = 1,

        const Undo = struct { name: []const u8, previous: ?usize };

        /// Every scope a walk opens is closed on the way out, so a finished walk
        /// leaves nothing open: anything left is a scope that failed to unwind.
        fn assertBalanced(self: *const LexicalScope) void {
            std.debug.assert(self.undo.items.len == 0);
            std.debug.assert(self.names.count() == 0);
            std.debug.assert(self.depth == 0 and self.var_base == 1);
        }
    };

    fn lexicalScope(self: *Parser) LexicalScope {
        return .{ .names = self.secureStringMap(usize) };
    }

    fn openLexicalName(self: *Parser, scope: *LexicalScope, name: []const u8) ParseError!void {
        if (name.len == 0) return;
        const previous = scope.names.get(name);
        // Reserve the undo record first, so recording it cannot fail after the
        // name is already visible to vars in this scope.
        try scope.undo.ensureUnusedCapacity(self.scratch_allocator, 1);
        try scope.names.put(self.arena, name, scope.depth);
        scope.undo.appendAssumeCapacity(.{ .name = name, .previous = previous });
    }

    fn closeLexicalScope(self: *Parser, scope: *LexicalScope, mark: usize) void {
        _ = self;
        while (scope.undo.items.len > mark) {
            const entry = scope.undo.pop().?;
            if (entry.previous) |depth| {
                // Scopes close LIFO, so a name that was open when this scope
                // shadowed it is still open now. A missing key would mean the
                // invariant broke and a later conflict could go silently
                // unreported, so it is not tolerated. Restoring cannot allocate.
                const slot = scope.names.getPtr(entry.name) orelse unreachable;
                slot.* = depth;
            } else {
                _ = scope.names.remove(entry.name);
            }
        }
    }

    fn checkVarAgainstLexical(self: *Parser, scope: *const LexicalScope, name: []const u8) ParseError!void {
        _ = self;
        if (name.len == 0) return;
        if (scope.var_scope_names) |names| if (names.contains(name))
            return ParseError.UnexpectedToken;
        const depth = scope.names.get(name) orelse return;
        if (depth >= scope.var_base) return ParseError.UnexpectedToken;
    }

    fn addModuleLexicalName(
        self: *Parser,
        lexical: *SecureStringMapUnmanaged(void),
        vars: *SecureStringMapUnmanaged(void),
        name: []const u8,
    ) ParseError!void {
        if (name.len == 0) return;
        if (lexical.contains(name) or vars.contains(name)) return ParseError.UnexpectedToken;
        try lexical.put(self.arena, name, {});
    }

    fn addModuleVarName(
        self: *Parser,
        lexical: *SecureStringMapUnmanaged(void),
        vars: *SecureStringMapUnmanaged(void),
        name: []const u8,
    ) ParseError!void {
        if (name.len == 0) return;
        if (lexical.contains(name)) return ParseError.UnexpectedToken;
        try vars.put(self.arena, name, {});
    }

    fn addPatternNames(
        self: *Parser,
        out: *std.ArrayListUnmanaged([]const u8),
        pattern: *Node,
    ) ParseError!void {
        try self.checkNesting();
        switch (pattern.*) {
            .identifier => |name| try out.append(self.arena, name),
            .obj_pattern => |p| {
                for (p.props) |prop| try self.addPatternNames(out, prop.target);
                if (p.rest) |r| if (r.* == .identifier) try out.append(self.arena, r.identifier);
            },
            .arr_pattern => |p| {
                for (p.elems) |elem| if (elem.target) |target|
                    try self.addPatternNames(out, target);
                if (p.rest) |rest| try self.addPatternNames(out, rest);
            },
            else => {},
        }
    }

    fn collectModuleDeclNames(
        self: *Parser,
        node: *Node,
        lexical: *SecureStringMapUnmanaged(void),
        vars: *SecureStringMapUnmanaged(void),
    ) ParseError!void {
        switch (node.*) {
            .import_decl => |i| for (i.entries) |entry|
                try self.addModuleLexicalName(lexical, vars, entry.local),
            .export_decl => |e| {
                if (e.declaration) |decl| try self.collectModuleDeclNames(decl, lexical, vars);
                if (e.default_name.len > 0) try self.addModuleLexicalName(lexical, vars, e.default_name);
            },
            .var_decl => |d| {
                if (d.kind == .@"var")
                    try self.addModuleVarName(lexical, vars, d.name)
                else
                    try self.addModuleLexicalName(lexical, vars, d.name);
            },
            .decl_group => |group| for (group) |decl|
                try self.collectModuleDeclNames(decl, lexical, vars),
            .destructure_decl => |d| {
                var names: std.ArrayListUnmanaged([]const u8) = .empty;
                try self.addPatternNames(&names, d.pattern);
                for (names.items) |name| {
                    if (d.kind == .@"var")
                        try self.addModuleVarName(lexical, vars, name)
                    else
                        try self.addModuleLexicalName(lexical, vars, name);
                }
            },
            .func_decl => |f| try self.addModuleLexicalName(lexical, vars, f.name),
            else => {},
        }
    }

    fn addExportedName(
        self: *Parser,
        exported: *SecureStringMapUnmanaged(void),
        name: []const u8,
    ) ParseError!void {
        if (name.len == 0) return;
        if (exported.contains(name)) return ParseError.UnexpectedToken;
        try exported.put(self.arena, name, {});
    }

    fn collectDeclExportedNames(
        self: *Parser,
        exported: *SecureStringMapUnmanaged(void),
        decl: *Node,
    ) ParseError!void {
        switch (decl.*) {
            .var_decl => |d| try self.addExportedName(exported, d.name),
            .decl_group => |group| for (group) |item| try self.collectDeclExportedNames(exported, item),
            .destructure_decl => |d| {
                var names: std.ArrayListUnmanaged([]const u8) = .empty;
                try self.addPatternNames(&names, d.pattern);
                for (names.items) |name| try self.addExportedName(exported, name);
            },
            .func_decl => |f| try self.addExportedName(exported, f.name),
            else => {},
        }
    }

    fn collectExportedNames(
        self: *Parser,
        exported: *SecureStringMapUnmanaged(void),
        node: *Node,
    ) ParseError!void {
        if (node.* != .export_decl) return;
        const e = node.export_decl;
        if (e.default_expr != null) try self.addExportedName(exported, "default");
        if (e.star_as.len > 0) try self.addExportedName(exported, e.star_as);
        for (e.entries) |entry| try self.addExportedName(exported, entry.exported);
        if (e.declaration) |decl| try self.collectDeclExportedNames(exported, decl);
    }

    fn checkLocalExportedBindings(
        node: *Node,
        lexical: *const SecureStringMapUnmanaged(void),
        vars: *const SecureStringMapUnmanaged(void),
    ) ParseError!void {
        if (node.* != .export_decl) return;
        const e = node.export_decl;
        if (e.from.len != 0) return;
        for (e.entries) |entry| {
            if (!lexical.contains(entry.local) and !vars.contains(entry.local))
                return ParseError.UnexpectedToken;
        }
    }

    fn checkModuleEarlyErrors(self: *Parser, stmts: []const *Node) ParseError!void {
        var lexical = self.secureStringMap(void);
        var vars = self.secureStringMap(void);
        var exported = self.secureStringMap(void);
        for (stmts) |stmt| {
            try self.collectModuleDeclNames(stmt, &lexical, &vars);
            try self.collectExportedNames(&exported, stmt);
        }
        for (stmts) |stmt| try checkLocalExportedBindings(stmt, &lexical, &vars);
        var lexical_scope = self.lexicalScope();
        defer lexical_scope.undo.deinit(self.scratch_allocator);
        // ModuleBody's LexicallyDeclaredNames remain visible while nested
        // statements contribute VarDeclaredNames: `let x; { var x; }` is an
        // early error. Reuse the inventory above instead of copying it (#949).
        lexical_scope.var_scope_names = &lexical;
        for (stmts) |stmt| try self.recurseScope(stmt, &lexical_scope);
        lexical_scope.assertBalanced();
        try self.checkPrivateUsesInProgram(stmts);
        // ModuleBody's early errors reject Contains `super` at the module
        // boundary, including arrows and exported expressions. Keep this in
        // the parser: module loading need not pass through Script evaluation.
        try self.scanEvalContext(stmts, true, true);
    }

    fn wtf8SurrogateAt(s: []const u8, i: usize) ?u16 {
        if (i + 2 >= s.len) return null;
        if (s[i] != 0xed) return null;
        if (s[i + 1] < 0xa0 or s[i + 1] > 0xbf) return null;
        if ((s[i + 2] & 0xc0) != 0x80) return null;
        const cp = (@as(u16, s[i] & 0x0f) << 12) |
            (@as(u16, s[i + 1] & 0x3f) << 6) |
            @as(u16, s[i + 2] & 0x3f);
        if (cp < 0xd800 or cp > 0xdfff) return null;
        return cp;
    }

    fn isHighSurrogate(unit: u16) bool {
        return unit >= 0xd800 and unit <= 0xdbff;
    }

    fn isLowSurrogate(unit: u16) bool {
        return unit >= 0xdc00 and unit <= 0xdfff;
    }

    fn utf8SeqLen(bytes: []const u8, i: usize) usize {
        const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch return 1;
        if (i + n > bytes.len) return 1;
        return if (std.unicode.utf8ValidateSlice(bytes[i .. i + n])) n else 1;
    }

    fn isWellFormedStringValue(s: []const u8) bool {
        var i: usize = 0;
        while (i < s.len) {
            if (wtf8SurrogateAt(s, i)) |first| {
                if (isHighSurrogate(first)) {
                    if (wtf8SurrogateAt(s, i + 3)) |second| if (isLowSurrogate(second)) {
                        i += 6;
                        continue;
                    };
                }
                return false;
            }
            i += utf8SeqLen(s, i);
        }
        return true;
    }

    /// Parse the token stream as a Module: a Module is always strict, and its
    /// top level additionally permits `import`/`export` declarations.
    pub fn parseModule(self: *Parser) ParseError!*Node {
        const program = if (self.regex_validation_arena != null)
            self.parseModuleInner()
        else
            parse: {
                var validation_arena = std.heap.ArenaAllocator.init(self.scratch_allocator);
                defer validation_arena.deinit();
                self.regex_validation_arena = &validation_arena;
                defer self.regex_validation_arena = null;
                break :parse self.parseModuleInner();
            } catch |err| return self.streamError(err).?;
        if (self.streamError(null)) |err| return err;
        return program;
    }

    fn parseModuleInner(self: *Parser) ParseError!*Node {
        self.module = true;
        self.strict = true;
        // HTML-like comments (Annex B B.1.3) are Script-only; a Module must reject
        // `<!--` / `-->`. The Script-goal lexer records their first exact offset;
        // rejecting that observation preserves the Module lexical goal without
        // discarding and rebuilding an attacker-proportional token stream.
        if (self.html_comment_offset) |offset| {
            self.last_error_offset = offset;
            return ParseError.UnexpectedToken;
        }
        // A Module is an async context for `await` at the top level (top-level
        // await). Nested non-async functions reset this via `parseFnBody`.
        self.in_async = true;
        // Module top level permits `using`/`await using` (unlike a Script's).
        self.using_allowed = true;
        var stmts: std.ArrayListUnmanaged(*Node) = .empty;
        while (!self.check(.eof)) {
            try stmts.append(self.arena, try self.parseModuleItem());
        }
        try self.checkModuleEarlyErrors(stmts.items);
        try self.checkPendingCoverErrors();
        return self.alloc(.{ .program = stmts.items });
    }

    /// A ModuleItem: an `import`/`export` declaration or an ordinary statement.
    fn parseModuleItem(self: *Parser) ParseError!*Node {
        const t = self.cur();
        if (t.kind == .identifier) {
            // `import` declaration — but `import(` (dynamic) and `import.meta`
            // are expressions, so only treat it as a declaration otherwise.
            if (std.mem.eql(u8, t.text, "import") and !self.peekIs(1, .lparen) and !self.peekIs(1, .dot))
                return self.parseImportDecl();
            if (std.mem.eql(u8, t.text, "export")) return self.parseExportDecl();
        }
        return self.parseStatement();
    }

    /// `import "spec";` | `import default, * as ns, { a as b } from "spec";`
    fn parseImportDecl(self: *Parser) ParseError!*Node {
        _ = self.advance(); // `import`
        var entries: std.ArrayListUnmanaged(ast.ImportEntry) = .empty;
        // Bare side-effect import: `import "spec";`
        if (self.check(.string)) {
            const spec = self.advance().text;
            const at = try self.parseImportAttributesOpt();
            try self.consumeStatementTerminator();
            return self.alloc(.{ .import_decl = .{ .specifier = spec, .entries = &.{}, .attr_type = at } });
        }
        // Source-phase import: `import source x from "mod"`. The contextual
        // keyword is only recognized when a binding and following `from` are
        // present, so `import source from "mod"` remains a default import.
        if (self.checkContextual("source") and self.peekKind(1) == .identifier and self.peekIsKeyword(2, "from")) {
            _ = self.advance(); // source
            const name_token = self.advance();
            const name = name_token.text;
            if (self.isForbiddenBindingName(name)) return self.failWithToken(.unexpected_token, name_token);
            try entries.append(self.arena, .{ .imported = "source", .local = name });
            try self.expectContextual("from");
            const spec = if (self.check(.string)) self.advance().text else return self.failWithTokenReason(.expected_module_specifier);
            const at = try self.parseImportAttributesOpt();
            try self.consumeStatementTerminator();
            return self.alloc(.{ .import_decl = .{ .specifier = spec, .entries = entries.items, .attr_type = at } });
        }
        // Deferred namespace import: `import defer * as ns from "m"`. `defer` is
        // a contextual keyword recognized only when followed by `*` (otherwise it
        // is an ordinary default-import binding name, e.g. `import defer from …`).
        const deferred = self.checkContextual("defer") and self.peekKind(1) == .star;
        if (deferred) _ = self.advance(); // consume `defer`
        // Default binding: `import name ...`
        if (self.check(.identifier)) {
            const name_token = self.advance();
            const name = name_token.text;
            if (self.isForbiddenBindingName(name)) return self.failWithToken(.unexpected_token, name_token);
            try entries.append(self.arena, .{ .imported = "default", .local = name });
            _ = self.match(.comma);
        }
        // `* as ns` namespace, or `{ ... }` named bindings.
        if (self.check(.star)) {
            _ = self.advance();
            try self.expectContextual("as");
            const ns_token = self.advance();
            if (ns_token.kind != .identifier) return self.failWithToken(.expected_import_binding, ns_token);
            const ns = ns_token.text;
            if (self.isForbiddenBindingName(ns)) return self.failWithToken(.unexpected_token, ns_token);
            try entries.append(self.arena, .{ .imported = "*", .local = ns, .namespace = true });
        } else if (self.check(.lbrace)) {
            try self.parseNamedImports(&entries);
        }
        try self.expectContextual("from");
        const spec = if (self.check(.string)) self.advance().text else return self.failWithTokenReason(.expected_module_specifier);
        const at = try self.parseImportAttributesOpt();
        try self.consumeStatementTerminator();
        return self.alloc(.{ .import_decl = .{ .specifier = spec, .entries = entries.items, .attr_type = at, .deferred = deferred } });
    }

    /// Static import attributes: `with { key: "value", ... }`. Validates the
    /// clause shape and duplicate keys, and returns the value of the `type`
    /// attribute (`""` when absent) — which selects the imported module's type
    /// (e.g. `"json"`).
    fn parseImportAttributesOpt(self: *Parser) ParseError![]const u8 {
        if (!self.checkContextual("with")) return "";
        _ = self.advance();
        try self.expect(.lbrace);
        var keys = self.secureStringMap(void);
        var type_value: []const u8 = "";
        while (!self.check(.rbrace)) {
            const key = try self.moduleExportName();
            if (keys.contains(key)) return ParseError.UnexpectedToken;
            try keys.put(self.arena, key, {});
            try self.expect(.colon);
            if (!self.check(.string)) return ParseError.UnexpectedToken;
            const val = self.advance().text;
            if (std.mem.eql(u8, key, "type")) type_value = val;
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbrace);
        return type_value;
    }

    /// `{ a, b as c, "str" as d }` import bindings.
    fn parseNamedImports(self: *Parser, entries: *std.ArrayListUnmanaged(ast.ImportEntry)) ParseError!void {
        try self.expect(.lbrace);
        while (!self.check(.rbrace)) {
            const imported_token = self.cur();
            const imported_is_string = self.cur().kind == .string;
            const imported = try self.moduleExportName();
            var local = imported;
            var local_token = imported_token;
            if (self.checkContextual("as")) {
                _ = self.advance();
                if (!self.check(.identifier)) return self.failWithTokenReason(.expected_import_binding);
                local_token = self.advance();
                local = local_token.text;
            } else if (imported_is_string) {
                return self.failWithTokenReason(.string_import_requires_alias);
            }
            if (self.isForbiddenBindingName(local)) return self.failWithToken(.unexpected_token, local_token);
            try entries.append(self.arena, .{ .imported = imported, .local = local });
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbrace);
    }

    /// `export` in all its forms.
    fn parseExportDecl(self: *Parser) ParseError!*Node {
        _ = self.advance(); // `export`
        const node = try self.arena.create(ast.ExportNode);
        node.* = .{};

        if (self.check(.star)) {
            // `export * from "m"` / `export * as ns from "m"`
            _ = self.advance();
            node.star = true;
            if (self.checkContextual("as")) {
                _ = self.advance();
                node.star_as = try self.moduleExportName();
            }
            try self.expectContextual("from");
            node.from = self.advance().text;
            _ = try self.parseImportAttributesOpt(); // export-from attributes: validated, not yet typed
            try self.consumeStatementTerminator();
            return self.alloc(.{ .export_decl = node });
        }
        if (self.check(.lbrace)) {
            // `export { a, b as c }` [from "m"]
            var entries: std.ArrayListUnmanaged(ast.ExportEntry) = .empty;
            var referenced_module_export_name = false;
            _ = self.advance(); // `{`
            while (!self.check(.rbrace)) {
                if (self.cur().kind == .string) referenced_module_export_name = true;
                const first = try self.moduleExportName();
                var exported = first;
                if (self.checkContextual("as")) {
                    _ = self.advance();
                    exported = try self.moduleExportName();
                }
                try entries.append(self.arena, .{ .local = first, .exported = exported });
                if (!self.match(.comma)) break;
            }
            try self.expect(.rbrace);
            if (self.checkContextual("from")) {
                _ = self.advance();
                node.from = self.advance().text;
                _ = try self.parseImportAttributesOpt(); // re-export attributes: validated, not yet typed
                // Re-export: the names are imported from the source module, not local.
                for (entries.items) |*e| {
                    e.imported = e.local;
                    e.local = "";
                }
            } else if (referenced_module_export_name) {
                return ParseError.UnexpectedToken;
            }
            node.entries = entries.items;
            try self.consumeStatementTerminator();
            return self.alloc(.{ .export_decl = node });
        }
        if (self.isContextual("default")) {
            _ = self.advance(); // `default`
            // `export default function/class …` binds a (possibly anonymous) name.
            if (self.isContextual("function") or (self.isContextual("async") and !self.cur().escaped_identifier and self.peekIsKeyword(1, "function"))) {
                // `export default function …` may be anonymous, so parse it as a
                // function *expression* (which permits no name).
                const is_async = self.isContextual("async");
                const decl = try self.parseFunctionExpr(is_async);
                decl.function.is_default_export_decl = true;
                decl.function.has_name_binding = false;
                node.default_expr = decl;
                node.default_name = decl.function.name;
                return self.alloc(.{ .export_decl = node });
            }
            if (self.isContextual("class")) {
                const cls = try self.parseClassExpr();
                node.default_expr = cls;
                node.default_name = cls.class_expr.name;
                return self.alloc(.{ .export_decl = node });
            }
            // `export default AssignmentExpression;`
            node.default_expr = try self.parseAssignment();
            try self.consumeStatementTerminator();
            return self.alloc(.{ .export_decl = node });
        }
        // `export <declaration>` — var/let/const/function/class. The declaration
        // also binds locally; its bound names become exports.
        const decl = try self.parseStatement();
        node.declaration = decl;
        return self.alloc(.{ .export_decl = node });
    }

    /// A ModuleExportName: an identifier or a string literal (ES2022).
    fn moduleExportName(self: *Parser) ParseError![]const u8 {
        const t = self.cur();
        if (t.kind != .identifier and t.kind != .string) return ParseError.UnexpectedToken;
        if (t.kind == .string and !isWellFormedStringValue(t.text)) return ParseError.UnexpectedToken;
        return self.advance().text;
    }

    /// Recursion that follows source nesting checks here first (#936). Deeply
    /// nested source overflowed the native stack and killed the process; below
    /// `stack_floor` this fails with `error.StackExhausted` instead, which
    /// JavaScript sees as a catchable `RangeError`.
    inline fn checkNesting(self: *const Parser) ParseError!void {
        if (stack_scan.stackAddress() <= self.stack_floor) return error.StackExhausted;
    }

    fn parseStatement(self: *Parser) ParseError!*Node {
        try self.checkNesting();
        const token = self.cur();
        const is_debugger = token.kind == .identifier and
            std.mem.eql(u8, token.text, "debugger") and !token.escaped_identifier;
        // Capture at entry: nested statements complete first, but statement entry
        // offsets are monotonic even when a production speculatively rewinds.
        const location = try self.statementLocationAt(token.pos);
        const node = try self.parseStatementInner();
        try self.statement_locations.append(self.arena, .{
            .node = node,
            .location = location,
            .debugger_statement = is_debugger,
        });
        return node;
    }

    fn parseStatementInner(self: *Parser) ParseError!*Node {
        // Consume the Statement-only marker: it applies to exactly this statement
        // (suppressing `let`-declaration recognition), never to a nested block.
        const suppress_let = self.suppress_let_decl;
        self.suppress_let_decl = false;
        // Empty statement: a bare `;` (also the trailing `;` after a class /
        // function declaration). Evaluates to a no-op (empty block).
        if (self.check(.semicolon)) {
            _ = self.advance();
            return self.alloc(.{ .block = &[_]*Node{} });
        }
        // A decorated class declaration: `@dec class C {…}`.
        if (self.check(.at)) {
            try self.parseDecorators();
            const cls = try self.parseClassExpr();
            if (cls.class_expr.name.len > 0)
                return self.alloc(.{ .var_decl = .{ .kind = .let, .name = cls.class_expr.name, .init = cls } });
            _ = self.match(.semicolon);
            return self.alloc(.{ .expr_stmt = cls });
        }
        const t = self.cur();
        if (t.kind == .identifier) {
            if (self.isEscapedReservedWord(t)) return self.failWithToken(.escaped_keyword, t);
            if (std.mem.eql(u8, t.text, "var")) return self.parseVarDecl(.@"var");
            if (std.mem.eql(u8, t.text, "let") and !t.escaped_identifier) {
                if (suppress_let) {
                    // Statement position (body of if/loop/with, label item): a
                    // LexicalDeclaration is not allowed, so `let` is an ordinary
                    // identifier — EXCEPT `let [`, the restricted ExpressionStatement
                    // production, which is a SyntaxError even with an intervening
                    // LineTerminator (the restriction has no [no LineTerminator]).
                    if (self.peekKind(1) == .lbracket) return self.failWithToken(.lexical_declaration_single_statement, self.tokenAt(self.pos + 1));
                } else if (self.letDeclAhead()) return self.parseVarDecl(.let);
            }
            if (std.mem.eql(u8, t.text, "const")) return self.parseVarDecl(.@"const");
            // `using x = e, …;` (explicit resource management): a block-scoped,
            // initializer-required declaration — parsed like `const` (disposal at
            // scope exit is not yet implemented). `using` not followed (on the
            // same line) by a binding identifier is an ordinary expression.
            if (std.mem.eql(u8, t.text, "using") and self.peekKind(1) == .identifier and
                self.noNewlineBefore(1) and !isReservedWord(self.tokens.items[self.pos + 1].text))
            {
                // A `using` declaration is only valid in a Block/function body or
                // at Module top level — not at Script top level or in a switch
                // CaseClause/DefaultClause.
                if (!self.using_allowed) return self.failWithReasonAt(.using_declaration_invalid_context, t.pos);
                return self.parseVarDeclDispose(.@"const", 1);
            }
            if (std.mem.eql(u8, t.text, "await") and self.peekIsKeyword(1, "using") and
                self.peekKind(2) == .identifier and self.noNewlineBefore(2))
            {
                if (!self.using_allowed) return self.failWithReasonAt(.using_declaration_invalid_context, t.pos);
                _ = self.advance(); // await
                return self.parseVarDeclDispose(.@"const", 2);
            }
            if (std.mem.eql(u8, t.text, "if")) return self.parseIf();
            if (std.mem.eql(u8, t.text, "while")) return self.parseWhile();
            if (std.mem.eql(u8, t.text, "do")) return self.parseDoWhile();
            if (std.mem.eql(u8, t.text, "for")) return self.parseFor();
            if (std.mem.eql(u8, t.text, "switch")) return self.parseSwitch();
            if (std.mem.eql(u8, t.text, "with")) {
                if (self.strict) return self.failWithReasonAt(.strict_with_statement, t.pos); // `with` is forbidden in strict mode
                _ = self.advance();
                try self.expect(.lparen);
                const obj = try self.parseExpression();
                try self.expect(.rparen);
                const body = try self.parseSubStatement(.loop_with);
                return self.alloc(.{ .with_stmt = .{ .obj = obj, .body = body } });
            }
            if (std.mem.eql(u8, t.text, "function")) return self.parseFunctionDecl(false);
            // `async function …` declaration (contextual keyword: `async`
            // immediately followed by `function`). `async [no LineTerminator here]
            // function` — a newline after `async` ends the statement, so `async`
            // becomes an ordinary identifier expression and `function …` is a
            // separate declaration. `async` followed by anything else is also an
            // ordinary expression statement (async arrow / identifier).
            if (std.mem.eql(u8, t.text, "async") and !t.escaped_identifier and self.peekIsKeyword(1, "function") and self.noNewlineBefore(1)) return self.parseFunctionDecl(true);
            if (std.mem.eql(u8, t.text, "return")) return self.parseReturn();
            if (std.mem.eql(u8, t.text, "throw")) return self.parseThrow();
            if (std.mem.eql(u8, t.text, "try")) return self.parseTry();
            if (std.mem.eql(u8, t.text, "debugger")) {
                _ = self.advance();
                try self.consumeStatementTerminator();
                return self.alloc(.debugger_stmt);
            }
            if (std.mem.eql(u8, t.text, "class")) {
                // `class C {...}` declaration binds C; anonymous class is an expr.
                const cls = try self.parseClassExpr();
                if (cls.class_expr.name.len > 0) {
                    return self.alloc(.{ .var_decl = .{ .kind = .let, .name = cls.class_expr.name, .init = cls } });
                }
                _ = self.match(.semicolon);
                return self.alloc(.{ .expr_stmt = cls });
            }
            if (std.mem.eql(u8, t.text, "break")) {
                _ = self.advance();
                const label_token = self.cur();
                const label = self.optionalLabel();
                _ = self.match(.semicolon);
                // Unlabeled `break` requires an enclosing loop or switch.
                if (label == null and self.iter_depth == 0 and self.switch_depth == 0) return self.failWithReasonAt(.break_outside_loop_or_switch, t.pos);
                if (label) |name| {
                    if (!labelListContains(self.active_labels.items, name)) return self.failWithToken(.undeclared_label, label_token);
                }
                return self.alloc(.{ .break_stmt = label });
            }
            if (std.mem.eql(u8, t.text, "continue")) {
                _ = self.advance();
                const label_token = self.cur();
                const label = self.optionalLabel();
                _ = self.match(.semicolon);
                // `continue` requires an enclosing loop (labeled or not).
                if (label) |name| {
                    if (!labelListContains(self.active_labels.items, name)) return self.failWithToken(.undeclared_label, label_token);
                    if (!labelListContains(self.continue_labels.items, name)) return self.failWithToken(.continue_non_loop_label, label_token);
                } else if (self.iter_depth == 0) {
                    return self.failWithReasonAt(.continue_outside_loop, t.pos);
                }
                return self.alloc(.{ .continue_stmt = label });
            }
            // Labeled statement: `label: stmt` (identifier directly followed by `:`).
            if (self.peekKind(1) == .colon and !self.isForbiddenLabelName(t.text)) {
                _ = self.advance(); // label
                _ = self.advance(); // ':'
                if (labelListContains(self.active_labels.items, t.text)) return self.failWithTokenDetail(.duplicate_label, self.cur(), t.text);
                try self.active_labels.append(self.arena, t.text);
                defer self.active_labels.items.len -= 1;
                const saved_pending = self.pending_labels.items.len;
                try self.pending_labels.append(self.arena, t.text);
                if (!self.statementCanInheritPendingLabels()) {
                    self.pending_labels.items.len = saved_pending;
                }
                defer self.pending_labels.items.len = saved_pending;
                const body = try self.parseSubStatement(.label_item);
                return self.alloc(.{ .labeled_stmt = .{ .label = t.text, .body = body } });
            }
        }
        if (t.kind == .lbrace) return self.parseBlock();

        const expr = try self.parseExpression();
        try self.consumeStatementTerminator();
        return self.alloc(.{ .expr_stmt = expr });
    }

    /// The position a single-statement body occupies, which governs whether a
    /// plain `function` declaration is allowed there (Annex B.3.2/B.3.4).
    const SubStmtCtx = enum {
        /// The consequent/alternate of an `if`. Annex B.3.4 permits a *direct*
        /// (unlabeled) sloppy `function` declaration here, but not a labeled one.
        if_clause,
        /// The body of a loop or `with`. No `function` declaration is allowed.
        loop_with,
        /// The item of a `label:`. Annex B.3.2 permits a sloppy `function`
        /// declaration (and nested labels ending in one).
        label_item,
    };

    /// A labeled statement, after peeling any number of labels, whose innermost
    /// item is a plain `function` declaration — the LabelledItem-is-a-function
    /// case from Annex B.3.2.
    fn statementFunctionDecl(node: *Node) ?*ast.FunctionNode {
        var n = node;
        while (n.* == .labeled_stmt) n = n.labeled_stmt.body;
        return if (n.* == .func_decl) n.func_decl else null;
    }

    fn labeledEndsInFunc(node: *Node) bool {
        return statementFunctionDecl(node) != null;
    }

    /// Parse the single-statement body of an `if`/`else`, loop, `with`, or
    /// labeled statement. The grammar allows a Statement there, NOT a
    /// Declaration: a lexical declaration (`let`/`const`/`using`) or a class
    /// declaration in that position is an early SyntaxError in every mode.
    ///
    /// A plain `function` declaration is special. In strict mode it is always a
    /// SyntaxError. In sloppy mode Annex B permits it as the *direct* body of an
    /// `if`/`else` clause (B.3.4) or as a `label:` item (B.3.2) — but never as a
    /// loop/`with` body, and a *labeled* function is never permitted as an
    /// `if`/loop/`with` body. Generator/async function declarations are never
    /// allowed in any single-statement position. (Plain `var` is allowed.) The
    /// check inspects what `parseStatement` actually produced, so `let`/`using`
    /// used as an identifier — which `parseStatement` parses as an expression —
    /// is never mistaken for a declaration.
    fn parseSubStatement(self: *Parser, ctx: SubStmtCtx) ParseError!*Node {
        // A Statement position: `let` here is an identifier, not a declaration.
        self.suppress_let_decl = true;
        const start_index = self.pos;
        const stmt = try self.parseStatement();
        switch (stmt.*) {
            .var_decl => |d| if (d.kind != .@"var") {
                const start_token = self.tokens.items[start_index];
                const reason: DiagnosticReason = if (std.mem.eql(u8, start_token.text, "class"))
                    .class_declaration_single_statement
                else
                    .unexpected_token;
                return self.failWithToken(reason, start_token);
            },
            .destructure_decl => |d| if (d.kind != .@"var") return self.failWithToken(.unexpected_token, self.tokens.items[start_index]),
            .func_decl => |f| {
                if (f.is_async) return self.failWithToken(.async_function_single_statement, self.functionKeywordFrom(start_index));
                if (self.strict) return self.failWithReasonAt(.strict_function_single_statement, self.functionKeywordFrom(start_index).pos);
                if (f.is_generator) return self.failWithToken(.generator_function_single_statement, self.functionMarkerFrom(start_index, .star));
                if (ctx == .loop_with) return self.failWithToken(.function_single_statement, self.functionKeywordFrom(start_index));
            },
            // A labeled function is only legal as a `label:` item (B.3.2), not as
            // the body of an `if`/loop/`with` (`if (x) lbl: function f(){}`).
            .labeled_stmt => if (ctx != .label_item and labeledEndsInFunc(stmt))
                return self.failWithToken(.function_single_statement, self.functionKeywordFrom(start_index)),
            else => {},
        }
        return stmt;
    }

    fn duplicateBindingReason(kind: ast.DeclKind) DiagnosticReason {
        return switch (kind) {
            .let => .duplicate_let_binding,
            .@"const" => .duplicate_const_binding,
            .@"var" => unreachable,
        };
    }

    /// A rejected single-statement function has already been parsed. Recover
    /// its grammar marker from the retained token stream only on that failure
    /// path; successful statements do no search or diagnostic formatting.
    fn functionMarkerFrom(self: *Parser, start_index: usize, kind: TokenKind) Token {
        const end = @min(self.pos + 1, self.tokens.items.len);
        for (self.tokens.items[start_index..end]) |token| {
            if (token.kind == kind) return token;
        }
        return self.tokens.items[start_index];
    }

    fn functionKeywordFrom(self: *Parser, start_index: usize) Token {
        const end = @min(self.pos + 1, self.tokens.items.len);
        for (self.tokens.items[start_index..end]) |token| {
            if (token.kind == .identifier and std.mem.eql(u8, token.text, "function")) return token;
        }
        return self.tokens.items[start_index];
    }

    /// Convert an array/object *literal* on the LHS of `=` into a destructuring
    /// pattern (the cover-grammar reinterpretation).
    fn litToPattern(self: *Parser, node: *Node) ParseError!*Node {
        try self.checkNesting();
        // A parenthesized array/object literal can't be a destructuring target.
        if (self.isParenWrapped(node)) return self.failWithReasonAt(.invalid_assignment, self.cur().pos);
        switch (node.*) {
            .array_lit => |elems| {
                if (self.rest_comma_arrays.get(self.secureHashState(), @intFromPtr(node))) |offset|
                    return self.failWithDiagnosticAt(.array_rest_pattern_closing, .token, ",", null, offset);
                var out: std.ArrayListUnmanaged(ast.ArrPatElem) = .empty;
                var rest: ?*Node = null;
                for (elems) |e| {
                    // A rest element (`...x`) must be last: nothing — not another
                    // element, elision, or rest — may follow it.
                    if (rest != null) return self.failWithReasonAt(.invalid_destructuring_assignment, self.cur().pos);
                    if (e.* == .elision) {
                        try out.append(self.arena, .{}); // elision / hole in `[ , a ] = …`
                    } else if (e.* == .spread) {
                        rest = try self.exprToTarget(e.spread);
                    } else if (e.* == .assign) {
                        if (self.isParenWrapped(e)) return self.failWithReasonAt(.invalid_destructuring_assignment, self.cur().pos);
                        try out.append(self.arena, .{ .target = try self.exprToTarget(e.assign.target), .default = e.assign.value });
                    } else {
                        try out.append(self.arena, .{ .target = try self.exprToTarget(e) });
                    }
                }
                return self.alloc(.{ .arr_pattern = .{ .elems = out.items, .rest = rest } });
            },
            .object_lit => |props| {
                // This object is being refined to a pattern, so a
                // CoverInitializedName it carries is legal (it becomes a default),
                // and duplicate `__proto__` keys are legal (just property names).
                _ = self.pending_cover_inits.remove(self.secureHashState(), @intFromPtr(node));
                _ = self.pending_proto_dup.remove(self.secureHashState(), @intFromPtr(node));
                var out: std.ArrayListUnmanaged(ast.ObjPatProp) = .empty;
                var rest_target: ?*ast.Node = null;
                var seen_spread = false;
                if (self.rest_comma_objects.get(self.secureHashState(), @intFromPtr(node))) |offset|
                    return self.failWithDiagnosticAt(.object_rest_pattern_comma, .token, ",", null, offset);
                for (props) |p| {
                    // An object rest property (`...rest`) must be the last member.
                    if (seen_spread) return self.failWithReasonAt(.invalid_destructuring_assignment, self.cur().pos);
                    if (p.is_spread) {
                        seen_spread = true;
                        // An object rest target must be a simple assignment target
                        // (an identifier or member) — `({...import.meta} = x)`,
                        // `({...(a+b)} = x)`, `({...[a]} = x)` are SyntaxErrors.
                        if (p.value.* != .identifier and p.value.* != .member and p.value.* != .super_member)
                            return self.failWithReasonAt(.invalid_destructuring_assignment, self.cur().pos);
                        if (p.value.* == .identifier and self.isForbiddenBindingName(p.value.identifier)) {
                            const name = p.value.identifier;
                            if (self.strict and isEvalOrArguments(name)) {
                                const reason: DiagnosticReason = if (std.mem.eql(u8, name, "eval")) .strict_modify_eval else .strict_modify_arguments;
                                return self.failWithDiagnosticAt(reason, .token, "}", null, self.sourceOffsetForSlice(name, self.cur().pos));
                            }
                            return self.failWithDiagnosticAt(.unexpected_token, .keyword, name, null, self.sourceOffsetForSlice(name, self.cur().pos));
                        }
                        rest_target = try self.exprToTarget(p.value);
                    } else if (p.value.* == .assign) {
                        if (self.isParenWrapped(p.value)) return self.failWithReasonAt(.invalid_destructuring_assignment, self.cur().pos);
                        try out.append(self.arena, .{ .key = p.key, .key_expr = p.key_expr, .target = try self.exprToTarget(p.value.assign.target), .default = p.value.assign.value });
                    } else {
                        try out.append(self.arena, .{ .key = p.key, .key_expr = p.key_expr, .target = try self.exprToTarget(p.value) });
                    }
                }
                return self.alloc(.{ .obj_pattern = .{ .props = out.items, .rest = rest_target } });
            },
            else => return self.failWithReasonAt(.invalid_destructuring_assignment, self.cur().pos),
        }
    }

    fn exprToTarget(self: *Parser, node: *Node) ParseError!*Node {
        try self.checkNesting();
        return switch (node.*) {
            .identifier => {
                if (self.isForbiddenBindingName(node.identifier))
                    return self.failWithDiagnosticAt(.unexpected_token, .keyword, node.identifier, null, self.sourceOffsetForSlice(node.identifier, self.cur().pos));
                return node;
            },
            .member, .super_member => node,
            .array_lit, .object_lit => try self.litToPattern(node),
            // Already a destructuring pattern — e.g. a nested assignment element
            // `[ {} = yield ]` whose inner `{} = …` was converted on the way up.
            .obj_pattern, .arr_pattern => node,
            else => self.failWithReasonAt(.invalid_destructuring_assignment, self.cur().pos),
        };
    }

    // ----- destructuring binding patterns ---------------------------------

    /// A binding target: an identifier or a nested object/array pattern.
    fn parseBindingTarget(self: *Parser) ParseError!*Node {
        try self.checkNesting();
        if (self.check(.lbrace)) return self.parseObjectPattern();
        if (self.check(.lbracket)) return self.parseArrayPattern();
        const name = self.advance();
        if (name.kind != .identifier) return ParseError.UnexpectedToken;
        if (self.isForbiddenBindingName(name.text)) return ParseError.UnexpectedToken;
        return self.alloc(.{ .identifier = name.text });
    }

    fn parseObjectPattern(self: *Parser) ParseError!*Node {
        try self.expect(.lbrace);
        var props: std.ArrayListUnmanaged(ast.ObjPatProp) = .empty;
        var rest: ?*Node = null;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            if (self.match(.ellipsis)) {
                const r = self.advance();
                // A BindingRestProperty target is a plain BindingIdentifier.
                if (r.kind != .identifier) return self.failWithToken(.expected_binding_element, r);
                if (self.isForbiddenBindingName(r.text)) {
                    const reason: DiagnosticReason = if (self.strict and isEvalOrArguments(r.text))
                        .strict_destructure_binding
                    else
                        .lexical_keyword_binding;
                    return self.failWithToken(reason, r);
                }
                rest = try self.alloc(.{ .identifier = r.text });
                break;
            }
            var key: []const u8 = "";
            var key_expr: ?*Node = null;
            var key_is_ident = false;
            var key_token: ?Token = null;
            if (self.match(.lbracket)) {
                key_expr = try self.parseAssignment();
                try self.expect(.rbracket);
            } else {
                const kt = self.advance();
                key_token = kt;
                key = switch (kt.kind) {
                    .identifier, .string => kt.text,
                    .number => try std.fmt.allocPrint(self.arena, "{d}", .{kt.number}),
                    else => return self.failWithToken(.expected_property_name, kt),
                };
                key_is_ident = kt.kind == .identifier;
            }
            // `{ key }` shorthand, or `{ key: target }`. A shorthand binds the
            // key as a BindingIdentifier, so the key must be an identifier token —
            // NOT a string/number literal (`{ '' }`, `{ 0 }`) or a computed key —
            // and must not be a reserved word (`{ break }`, `{ this }`, …),
            // including one spelled with a Unicode escape (`key` holds the decoded
            // text). A literal/computed key REQUIRES a `: target`.
            const target = if (self.match(.colon))
                try self.parseBindingTarget()
            else blk: {
                if (!key_is_ident) return self.failWithTokenReason(.expected_named_destructuring_colon);
                if (self.isForbiddenBindingName(key)) return self.failWithToken(.abbreviated_destructuring_keyword, key_token.?);
                break :blk try self.alloc(.{ .identifier = key });
            };
            const default = if (self.match(.assign)) try self.parseAssignment() else null;
            try props.append(self.arena, .{ .key = key, .key_expr = key_expr, .target = target, .default = default });
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbrace);
        return self.alloc(.{ .obj_pattern = .{ .props = props.items, .rest = rest } });
    }

    fn parseArrayPattern(self: *Parser) ParseError!*Node {
        try self.expect(.lbracket);
        var elems: std.ArrayListUnmanaged(ast.ArrPatElem) = .empty;
        var rest: ?*Node = null;
        while (!self.check(.rbracket) and !self.check(.eof)) {
            if (self.check(.comma)) { // elision / hole
                try elems.append(self.arena, .{});
                _ = self.advance();
                continue;
            }
            if (self.match(.ellipsis)) {
                rest = try self.parseBindingTarget();
                break;
            }
            const target = try self.parseBindingTarget();
            const default = if (self.match(.assign)) try self.parseAssignment() else null;
            try elems.append(self.arena, .{ .target = target, .default = default });
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbracket);
        return self.alloc(.{ .arr_pattern = .{ .elems = elems.items, .rest = rest } });
    }

    fn parseVarDecl(self: *Parser, kind: ast.DeclKind) ParseError!*Node {
        return self.parseVarDeclDispose(kind, 0);
    }

    fn parseForInitVarDecl(self: *Parser, kind: ast.DeclKind) ParseError!*Node {
        return self.parseForInitVarDeclDispose(kind, 0);
    }

    fn parseForInitVarDeclDispose(self: *Parser, kind: ast.DeclKind, dispose: u8) ParseError!*Node {
        const saved_no_in = self.no_in;
        self.no_in = true;
        defer self.no_in = saved_no_in;
        return self.parseVarDeclDispose(kind, dispose);
    }

    /// `dispose`: 0 = ordinary `var`/`let`/`const`, 1 = `using`, 2 = `await using`.
    fn parseVarDeclDispose(self: *Parser, kind: ast.DeclKind, dispose: u8) ParseError!*Node {
        const await_offset = if (dispose == 2 and self.pos > 0) self.tokens.items[self.pos - 1].pos else 0;
        _ = self.advance(); // var/let/const/using
        // One or more comma-separated declarators: `let a, {b} = obj, c = 1`.
        var decls: std.ArrayListUnmanaged(*Node) = .empty;
        while (true) {
            if (self.check(.lbrace) or self.check(.lbracket)) {
                if (dispose != 0) return ParseError.UnexpectedToken;
                const pattern = try self.parseBindingTarget();
                try self.expect(.assign);
                const init_expr = try self.parseAssignment();
                if (kind == .@"var") try self.noteVarPattern(pattern);
                try decls.append(self.arena, try self.alloc(.{ .destructure_decl = .{ .kind = kind, .pattern = pattern, .init = init_expr } }));
            } else {
                const name_tok = self.advance();
                if (name_tok.kind != .identifier) return ParseError.UnexpectedToken;
                // A reserved word may not be a binding name — including when spelled
                // with `\u` escapes (the lexer hands us the decoded text).
                if (self.isForbiddenBindingName(name_tok.text)) return ParseError.UnexpectedToken;
                // A lexical declaration's (let/const/using) BoundNames may not contain
                // `let`, in every mode — `let let`, `const x, let`.
                if (kind != .@"var" and std.mem.eql(u8, name_tok.text, "let")) return ParseError.UnexpectedToken;
                var init_expr: ?*Node = null;
                if (self.match(.assign)) {
                    init_expr = try self.parseAssignment();
                    nameAnon(init_expr.?, name_tok.text);
                } else if (kind == .@"const" or dispose != 0) {
                    // `const` and `using` declarations require an initializer.
                    return ParseError.UnexpectedToken;
                }
                if (kind == .@"var") try self.noteVarName(name_tok.text);
                try decls.append(self.arena, try self.alloc(.{ .var_decl = .{ .kind = kind, .name = name_tok.text, .init = init_expr, .dispose = dispose, .await_offset = await_offset } }));
            }
            if (!self.match(.comma)) break;
        }
        try self.consumeStatementTerminatorWithReason(.expected_semicolon_after_variable_declaration);
        // A single declarator stays a bare declaration; multiples become a
        // transparent declaration group (NOT a block — no new scope).
        if (decls.items.len == 1) return decls.items[0];
        return self.alloc(.{ .decl_group = decls.items });
    }

    fn parseBlock(self: *Parser) ParseError!*Node {
        try self.expect(.lbrace);
        // A Block's StatementList permits `using`/`await using` declarations.
        const saved_using = self.using_allowed;
        self.using_allowed = true;
        defer self.using_allowed = saved_using;
        var stmts: std.ArrayListUnmanaged(*Node) = .empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            try stmts.append(self.arena, try self.parseStatement());
        }
        try self.expect(.rbrace);
        return self.alloc(.{ .block = stmts.items });
    }

    fn parseIf(self: *Parser) ParseError!*Node {
        _ = self.advance(); // if
        try self.expectWithTokenReason(.lparen, .expected_if_condition);
        const cond = try self.parseExpression();
        try self.expect(.rparen);
        const cons = try self.parseSubStatement(.if_clause);
        var alt: ?*Node = null;
        if (isKeyword(self.cur(), "else")) {
            _ = self.advance();
            alt = try self.parseSubStatement(.if_clause);
        }
        return self.alloc(.{ .if_stmt = .{ .cond = cond, .consequent = cons, .alternate = alt } });
    }

    /// Parse a loop body, tracking that `break`/`continue` are now legal.
    fn parseLoopBody(self: *Parser) ParseError!*Node {
        const saved_pending = self.pending_labels.items.len;
        const saved_continue = self.continue_labels.items.len;
        for (self.pending_labels.items) |label|
            try self.continue_labels.append(self.arena, label);
        self.pending_labels.items.len = 0;
        self.iter_depth += 1;
        defer {
            self.iter_depth -= 1;
            self.pending_labels.items.len = saved_pending;
            self.continue_labels.items.len = saved_continue;
        }
        return self.parseSubStatement(.loop_with);
    }

    fn parseWhile(self: *Parser) ParseError!*Node {
        _ = self.advance(); // while
        try self.expect(.lparen);
        const cond = try self.parseExpression();
        try self.expect(.rparen);
        const body = try self.parseLoopBody();
        return self.alloc(.{ .while_stmt = .{ .cond = cond, .body = body } });
    }

    fn parseDoWhile(self: *Parser) ParseError!*Node {
        _ = self.advance(); // do
        const body = try self.parseLoopBody();
        if (!isKeyword(self.cur(), "while")) return ParseError.ExpectedToken;
        _ = self.advance(); // while
        try self.expect(.lparen);
        const cond = try self.parseExpression();
        try self.expect(.rparen);
        _ = self.match(.semicolon);
        return self.alloc(.{ .do_while_stmt = .{ .body = body, .cond = cond } });
    }

    fn parseFor(self: *Parser) ParseError!*Node {
        _ = self.advance(); // for
        // `for await (x of asyncIterable)` — only inside an async function.
        var is_await = false;
        var await_offset: usize = 0;
        if (self.in_async and isKeyword(self.cur(), "await")) {
            await_offset = self.advance().pos;
            is_await = true;
        }
        try self.expect(.lparen);

        // Detect `for (... in/of ...)`. Save position so we can fall back to a
        // classic `for (init; cond; update)` if it isn't an iteration form.
        const save = self.pos;
        const statement_location_save = self.statementLocationCheckpoint();
        const error_offset_save = self.last_error_offset;
        const error_reason_save = self.last_error_reason;
        const error_token_save = self.last_error_token;
        var decl_kind: ?ast.DeclKind = null;
        var is_using = false;
        var using_binding_index: ?usize = null;
        var dispose: u8 = 0; // 1 = `using`, 2 = `await using` (for a for-of head)
        if (isKeyword(self.cur(), "var")) {
            decl_kind = .@"var";
            _ = self.advance();
        } else if (self.letDeclAhead()) {
            decl_kind = .let;
            _ = self.advance();
        } else if (isKeyword(self.cur(), "const")) {
            decl_kind = .@"const";
            _ = self.advance();
        } else if (isKeyword(self.cur(), "using") and self.peekKind(1) == .identifier and
            !self.peekIsKeyword(1, "of") and self.noNewlineBefore(1))
        {
            // `for (using x of …)` (but `for (using of …)` has `using` as the var).
            decl_kind = .@"const";
            is_using = true;
            dispose = 1;
            using_binding_index = self.pos + 1;
            _ = self.advance();
        } else if (isKeyword(self.cur(), "await") and self.peekIsKeyword(1, "using") and
            self.peekKind(2) == .identifier and self.noNewlineBefore(1) and self.noNewlineBefore(2))
        {
            // `for (await using x of …)`; `x` may itself be the contextual name
            // `of`, so consume both declaration keywords before parsing target.
            decl_kind = .@"const";
            is_using = true;
            dispose = 2;
            using_binding_index = self.pos + 2;
            await_offset = self.advance().pos;
            _ = self.advance(); // using
        }
        const classic_using_of_decl =
            self.pos == save and
            isKeyword(self.cur(), "using") and
            self.peekIsKeyword(1, "of") and
            self.peekKind(2) == .assign;
        const classic_async_of_arrow =
            self.pos == save and
            isKeyword(self.cur(), "async") and
            self.peekIsKeyword(1, "of") and
            self.peekKind(2) == .arrow;
        // `for (async of …)` — a plain for-of forbids a bare, unescaped `async`
        // token directly before `of` (lookahead restriction). `for await`,
        // a parenthesized `(async)`, and an escaped `async` are all unaffected,
        // and `for (async of => …)` is the async-arrow classic form above.
        if (!is_await and self.pos == save and decl_kind == null and
            isKeyword(self.cur(), "async") and !self.cur().escaped_identifier and
            self.peekIsKeyword(1, "of") and self.peekKind(2) != .arrow)
            return self.failWithToken(.unexpected_token, self.tokenAt(self.pos + 1));
        // Iteration form `for ([decl] target in/of iterable)`, where `target`
        // is an identifier, a destructuring pattern, or (assignment form) a
        // member expression. Parse a target, then require `in`/`of`; otherwise
        // rewind to `save` and parse a classic `for(;;)`.
        // A head that does not parse as a target is retried as a classic
        // `for(;;)` below, but running out of stack or memory is not a parse
        // failure: retrying repeats the same descent (at every enclosing head,
        // so the work doubles per level) and a `for await` head would report it
        // as a SyntaxError (#936).
        const for_target = if (classic_using_of_decl or classic_async_of_arrow or try self.classicForHeadAhead()) null else self.tryForTarget(decl_kind) catch |err| switch (err) {
            error.StackExhausted, error.OutOfMemory => return err,
            else => null,
        };
        if (for_target) |target| {
            var var_init: ?*Node = null;
            var var_init_offset: ?usize = null;
            if (!self.strict and decl_kind != null and decl_kind.? == .@"var" and target.* == .identifier and self.check(.assign)) {
                var_init_offset = self.advance().pos;
                const saved_no_in = self.no_in;
                self.no_in = true;
                var_init = try self.parseExpression();
                self.no_in = saved_no_in;
                nameAnon(var_init.?, target.identifier);
            }
            // `in`/`of` written with a Unicode escape (`of`) is never the
            // contextual keyword, so it cannot introduce an iteration head.
            const at_iter = !self.cur().escaped_identifier and
                (isKeyword(self.cur(), "in") or isKeyword(self.cur(), "of"));
            if (at_iter) {
                // A lexical (`let`/`const`) for-in/of head binds the target's names
                // and must have no duplicates: `for (let [x, x] of …)` is an error.
                if (decl_kind) |k| if (k != .@"var") try self.checkNoDuplicateBindings(target);
                const iteration_token = self.advance(); // consume in/of
                const is_of = isKeyword(iteration_token, "of");
                // A `using`/`await using` head is valid only in a for-of/-await-of,
                // never a for-in: `for (using x in obj)` is a SyntaxError.
                if (is_using and !is_of)
                    return self.failWithToken(.using_for_in, self.tokenAt(using_binding_index.?));
                if (is_await and !is_of) return self.failWithToken(.for_await_in, iteration_token);
                if (var_init_offset) |offset| if (is_of) return self.failWithReasonAt(.for_of_initializer, offset);
                // `for-in` takes an Expression, `for-of` an AssignmentExpression.
                const iterable = if (is_of) try self.parseAssignment() else try self.parseExpression();
                try self.expect(.rparen);
                const body = if (decl_kind != null and decl_kind.? != .@"var") body: {
                    var head: std.ArrayListUnmanaged([]const u8) = .empty;
                    try self.addPatternNames(&head, target);
                    break :body try self.parseLexicalForBody(head.items);
                } else body: {
                    // A `var` target is itself a VarDeclaredName of the enclosing
                    // var scope, so an enclosing lexical `for` has to see it.
                    if (decl_kind != null) try self.noteVarPattern(target);
                    break :body try self.parseLoopBody();
                };
                return self.alloc(.{ .for_in = .{
                    .decl_kind = decl_kind,
                    .target = target,
                    .var_init = var_init,
                    .iterable = iterable,
                    .body = body,
                    .is_of = is_of,
                    .is_await = is_await,
                    .dispose = dispose,
                    .await_offset = await_offset,
                } });
            }
        }
        if (is_await) return self.failForAwaitClassicHead();
        self.pos = save; // not an iteration form — rewind and parse a classic for
        self.current_token = &self.tokens.items[self.pos];
        // Discard locations for function bodies reached while refining the cover
        // grammar. The discarded AST is arena-owned but unreachable; publishing
        // its nodes would create ghost debugger locations and leave the forward
        // source cursor ahead of the real classic-for parse.
        self.restoreStatementLocationCheckpoint(statement_location_save);
        self.last_error_offset = error_offset_save;
        self.last_error_reason = error_reason_save;
        self.last_error_token = error_token_save;

        var init_node: ?*Node = null;
        if (self.match(.semicolon)) {
            // empty initializer
        } else if (isKeyword(self.cur(), "var")) {
            init_node = try self.parseForInitVarDecl(.@"var"); // consumes the ';'
        } else if (self.letDeclAhead()) {
            init_node = try self.parseForInitVarDecl(.let);
        } else if (isKeyword(self.cur(), "const")) {
            init_node = try self.parseForInitVarDecl(.@"const");
        } else if (isKeyword(self.cur(), "using") and self.peekKind(1) == .identifier and self.noNewlineBefore(1)) {
            // `for (using x = e; …)` — a using declaration head (the `using of`
            // lookahead restriction applies only to for-of, not the classic for).
            init_node = try self.parseForInitVarDeclDispose(.@"const", 1);
        } else if (isKeyword(self.cur(), "await") and self.peekIsKeyword(1, "using") and
            self.peekKind(2) == .identifier and self.noNewlineBefore(1) and self.noNewlineBefore(2))
        {
            _ = self.advance(); // await
            init_node = try self.parseForInitVarDeclDispose(.@"const", 2);
        } else {
            // A classic for-init is `[~In]`: a top-level `in` is forbidden here.
            self.no_in = true;
            init_node = try self.parseExpression();
            self.no_in = false;
            try self.expect(.semicolon);
        }
        var cond: ?*Node = null;
        if (!self.check(.semicolon)) cond = try self.parseExpression();
        try self.expect(.semicolon);
        var update: ?*Node = null;
        if (!self.check(.rparen)) update = try self.parseExpression();
        try self.expect(.rparen);
        const body = if (init_node) |ini| body: {
            var head: std.ArrayListUnmanaged([]const u8) = .empty;
            try self.collectLexicalDeclNames(ini, &head);
            if (head.items.len == 0) break :body try self.parseLoopBody();
            break :body try self.parseLexicalForBody(head.items);
        } else try self.parseLoopBody();
        if (init_node) |ini| try self.checkNoDuplicateLexicalDeclNames(ini);
        return self.alloc(.{ .for_stmt = .{ .init = init_node, .cond = cond, .update = update, .body = body } });
    }

    /// A malformed `for await` head is known to be classic because the existing
    /// structural lookahead found its top-level semicolon. Locate that cached
    /// token only on the rejected path so valid loops do not pay for a second
    /// scan.
    fn failForAwaitClassicHead(self: *Parser) ParseError {
        var depth: usize = 0;
        var index = self.pos;
        while (true) : (index += 1) {
            const token = self.tokenAt(index);
            switch (token.kind) {
                .lparen, .lbracket, .lbrace => depth += 1,
                .rparen => {
                    if (depth == 0) break;
                    depth -= 1;
                },
                .rbracket, .rbrace => depth -|= 1,
                .semicolon => if (depth == 0) return self.failWithToken(.for_await_semicolon, token),
                .eof => break,
                else => {},
            }
        }
        return self.failWithTokenReason(.for_await_semicolon);
    }

    /// Whether the head starting at the cursor is a classic `for (init; cond; update)`.
    ///
    /// A classic head always has a `;` at the head's own bracket depth, and an
    /// iteration head never does: a `;` belonging to anything nested is inside a
    /// parenthesis, bracket or brace, and a template substitution or regular
    /// expression is a single token, so neither can contribute one here.
    ///
    /// Answering before the head is parsed is what keeps it parsed *once*. The
    /// iteration form used to be tried first and rewound on failure, which
    /// re-parsed every nested function body in the head -- and a `for` nested
    /// inside one of those bodies repeated that at its own level, so the work
    /// and the arena both doubled per level (#939).
    fn classicForHeadAhead(self: *Parser) ParseError!bool {
        const start_offset = self.cur().pos;
        const saved_lexer = self.lexer;
        const saved_token_len = self.tokens.items.len;
        const saved_lex_error = self.lex_error;
        const saved_lex_error_offset = self.lex_error_offset;
        const saved_html_comment_offset = self.html_comment_offset;

        // Keep a successful lookahead's token cache: nested for heads depend on
        // that one-pass frontier for #939's linear growth. The fork protects the
        // committed structural stacks. A slash-dependent scan discards the
        // cache and restores the exact committed scanner before the bounded
        // two-goal source scan resolves the head shape.
        self.lexer = try saved_lexer.fork(self.arena);
        self.lex_error = null;
        const classic = self.classicForHeadAheadSpeculative();
        var saw_slash = false;
        for (self.tokens.items[self.pos..]) |token| {
            if (isSlashToken(token.kind)) {
                saw_slash = true;
                break;
            }
        }
        if (self.lex_error == null and !saw_slash) return classic;

        self.tokens.items.len = saved_token_len;
        self.lexer = saved_lexer;
        self.lex_error = saved_lex_error;
        self.lex_error_offset = saved_lex_error_offset;
        self.html_comment_offset = saved_html_comment_offset;
        return self.sourceClassicForHead(start_offset);
    }

    fn classicForHeadAheadSpeculative(self: *Parser) bool {
        var depth: usize = 0;
        var i = self.pos;
        while (true) : (i += 1) {
            switch (self.tokenAt(i).kind) {
                .lparen, .lbracket, .lbrace => depth += 1,
                .rparen => {
                    // The head's own `)`: no `;` above it, so this is an
                    // iteration head (or a malformed one, which the target parse
                    // reports as it did before).
                    if (depth == 0) return false;
                    depth -= 1;
                },
                .rbracket, .rbrace => depth -|= 1,
                .semicolon => if (depth == 0) return true,
                .eof => return false,
                else => {},
            }
        }
        return false;
    }

    fn sourceClassicForHead(self: *Parser, start_offset: usize) ParseError!bool {
        var pending: std.ArrayListUnmanaged(ParenScanState) = .empty;
        defer pending.deinit(self.scratch_allocator);
        var visited = std.AutoHashMapUnmanaged(ParenScanState, void).empty;
        defer visited.deinit(self.scratch_allocator);
        try pending.append(self.scratch_allocator, .{ .offset = start_offset, .depth = 0 });

        while (pending.pop()) |initial| {
            var state = initial;
            while (state.offset < self.source.len) {
                const entry = try visited.getOrPut(self.scratch_allocator, state);
                if (entry.found_existing) break;
                const c = self.source[state.offset];
                if (c == '\'' or c == '"') {
                    state.offset = scanQuotedSource(self.source, state.offset, c) orelse break;
                    continue;
                }
                if (c == '`') {
                    state.offset = scanTemplateSource(self.source, state.offset) orelse break;
                    continue;
                }
                if (c == '/' and state.offset + 1 < self.source.len and self.source[state.offset + 1] == '/') {
                    state.offset += 2;
                    while (state.offset < self.source.len and lex.lineTerminatorLen(self.source, state.offset) == null) state.offset += 1;
                    continue;
                }
                if (c == '/' and state.offset + 1 < self.source.len and self.source[state.offset + 1] == '*') {
                    const end = std.mem.indexOfPos(u8, self.source, state.offset + 2, "*/") orelse break;
                    state.offset = end + 2;
                    continue;
                }
                if (c == '/') {
                    if (scanRegexSource(self.source, state.offset)) |regex_end|
                        try pending.append(self.scratch_allocator, .{ .offset = regex_end, .depth = state.depth });
                    state.offset += if (state.offset + 1 < self.source.len and self.source[state.offset + 1] == '=') 2 else 1;
                    continue;
                }
                switch (c) {
                    '(', '[', '{' => state.depth += 1,
                    ')' => {
                        if (state.depth == 0) break;
                        state.depth -= 1;
                    },
                    ']', '}' => state.depth -|= 1,
                    ';' => if (state.depth == 0) return true,
                    else => {},
                }
                state.offset += 1;
            }
        }
        return false;
    }

    /// Parse a `for-in`/`for-of` loop target (the part between the optional
    /// declaration keyword and `in`/`of`): an identifier, a destructuring
    /// pattern, or — in the assignment form (no `decl_kind`) — a member
    /// expression. Returns null when the head clearly isn't an iteration target
    /// (so the caller falls back to a classic `for(;;)`).
    fn tryForTarget(self: *Parser, decl_kind: ?ast.DeclKind) ParseError!?*Node {
        if (self.check(.lbrace) or self.check(.lbracket)) {
            if (decl_kind != null) return try self.parseBindingTarget();
            const start = self.pos;
            // Assignment form: an array/object literal cover is a destructuring
            // target only when the head is immediately an in/of form. Otherwise
            // let a classic for initializer parse the left-hand-side expression.
            const node = try self.parsePostfix();
            if (node.* == .member or node.* == .super_member) return node;
            if (isKeyword(self.cur(), "in") or isKeyword(self.cur(), "of")) return try self.litToPattern(node);
            self.pos = start;
            self.current_token = &self.tokens.items[self.pos];
            return null;
        }
        if (decl_kind != null) {
            // A declaration binds a single BindingIdentifier.
            if (self.check(.identifier)) {
                const name = self.cur().text;
                if (self.isForbiddenBindingName(name)) return ParseError.UnexpectedToken;
                return try self.alloc(.{ .identifier = self.advance().text });
            }
            return null;
        }
        // Assignment form: a LeftHandSideExpression that must be a valid
        // assignment target. Anything else (a call, `this`, a literal, …) makes
        // this not an iteration form, so the caller rewinds and it becomes a
        // syntax error in the classic-`for` path.
        const node = try self.parsePostfix();
        return switch (node.*) {
            .identifier, .member, .super_member => node,
            .call => if (!self.strict) node else null,
            else => null,
        };
    }

    fn parseSwitch(self: *Parser) ParseError!*Node {
        _ = self.advance(); // switch
        try self.expect(.lparen);
        const disc = try self.parseExpression();
        try self.expect(.rparen);
        try self.expect(.lbrace);
        // Inside a switch, unlabeled `break` is legal (but not `continue`).
        self.switch_depth += 1;
        // A CaseClause/DefaultClause StatementList forbids `using`/`await using`
        // (only a nested Block re-enables it); the discriminant/case tests are
        // expressions, so resetting here is safe.
        const saved_using = self.using_allowed;
        self.using_allowed = false;
        defer {
            self.switch_depth -= 1;
            self.using_allowed = saved_using;
        }
        var cases: std.ArrayListUnmanaged(ast.SwitchCase) = .empty;
        // A CaseBlock may contain at most one DefaultClause (early error 13.12.1).
        var seen_default = false;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            var test_expr: ?*Node = null;
            if (isKeyword(self.cur(), "case")) {
                _ = self.advance();
                test_expr = try self.parseExpression();
            } else if (isKeyword(self.cur(), "default")) {
                if (seen_default) return ParseError.UnexpectedToken;
                seen_default = true;
                _ = self.advance();
            } else return ParseError.UnexpectedToken;
            try self.expect(.colon);
            // Statements until the next case/default/closing brace.
            var body: std.ArrayListUnmanaged(*Node) = .empty;
            while (!self.check(.rbrace) and !self.check(.eof) and
                !isKeyword(self.cur(), "case") and !isKeyword(self.cur(), "default"))
            {
                try body.append(self.arena, try self.parseStatement());
            }
            try cases.append(self.arena, .{ .@"test" = test_expr, .body = body.items });
        }
        try self.expect(.rbrace);
        return self.alloc(.{ .switch_stmt = .{ .disc = disc, .cases = cases.items } });
    }

    fn parseReturn(self: *Parser) ParseError!*Node {
        // `return` is only valid inside a function body.
        if (self.fn_depth == 0) return self.failWithReasonAt(.return_outside_function, self.cur().pos);
        _ = self.advance(); // return
        var arg: ?*Node = null;
        if (!self.hasLineTerminatorBefore(0) and !self.check(.semicolon) and !self.check(.rbrace) and !self.check(.eof)) {
            arg = try self.parseExpression();
        }
        _ = self.match(.semicolon);
        return self.alloc(.{ .return_stmt = arg });
    }

    fn parseThrow(self: *Parser) ParseError!*Node {
        _ = self.advance(); // throw
        if (self.hasLineTerminatorBefore(0)) return ParseError.UnexpectedToken;
        const arg = try self.parseExpression();
        _ = self.match(.semicolon);
        return self.alloc(.{ .throw_stmt = arg });
    }

    /// Catch-clause early errors (14.15.1): the CatchParameter's BoundNames must
    /// be unique (`catch ([x, x]) {}`) and must not also appear in the catch
    /// block's LexicallyDeclaredNames — a `let`/`const`/`class` or a block-level
    /// function declaration that reuses a catch-bound name (`catch (e) { let e; }`,
    /// `catch (e) { function e(){} }`) is a SyntaxError. (Annex B.3.5 still lets a
    /// body `var` match a simple catch parameter, so `var` is not checked here.)
    fn checkCatchClause(self: *Parser, param: *Node, block: *Node) ParseError!void {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        try self.addPatternNames(&names, param);
        var bound = self.secureStringMap(void);
        for (names.items) |n| {
            if (n.len == 0) continue;
            if (bound.contains(n)) return self.failWithNameAt(.duplicate_catch_binding, n, self.cur().pos);
            try bound.put(self.arena, n, {});
        }
        if (bound.count() == 0 or block.* != .block) return;
        for (block.block) |s| switch (s.*) {
            .var_decl => |d| if (d.kind != .@"var" and bound.contains(d.name)) {
                const reason: DiagnosticReason = if (d.init != null and d.init.?.* == .class_expr)
                    .duplicate_class_binding
                else
                    duplicateBindingReason(d.kind);
                return self.failWithNameAt(reason, d.name, self.statementStartOffset(s));
            },
            .destructure_decl => |d| if (d.kind != .@"var") {
                var bn: std.ArrayListUnmanaged([]const u8) = .empty;
                try self.addPatternNames(&bn, d.pattern);
                for (bn.items) |n| {
                    if (bound.contains(n)) {
                        const closing: []const u8 = switch (d.pattern.*) {
                            .obj_pattern => "}",
                            .arr_pattern => "]",
                            else => "",
                        };
                        return self.failWithDiagnosticAt(
                            .duplicate_catch_destructuring,
                            .token,
                            closing,
                            n,
                            self.sourceOffsetForSlice(n, self.statementStartOffset(s)),
                        );
                    }
                }
            },
            .decl_group => |g| for (g) |d2| {
                if (d2.* == .var_decl and d2.var_decl.kind != .@"var" and bound.contains(d2.var_decl.name))
                    return self.failWithNameAt(duplicateBindingReason(d2.var_decl.kind), d2.var_decl.name, self.statementStartOffset(s));
            },
            .func_decl => |fnode| if (fnode.name.len > 0 and bound.contains(fnode.name))
                return self.failWithNameAt(.catch_function_shadow, fnode.name, self.statementStartOffset(s)),
            .labeled_stmt => if (statementFunctionDecl(s)) |fnode| {
                if (fnode.name.len > 0 and bound.contains(fnode.name))
                    return self.failWithNameAt(.catch_function_shadow, fnode.name, self.statementStartOffset(s));
            },
            .class_expr => |c| if (c.name.len > 0 and bound.contains(c.name))
                return self.failWithNameAt(.duplicate_class_binding, c.name, self.statementStartOffset(s)),
            else => {},
        };
    }

    fn parseTry(self: *Parser) ParseError!*Node {
        _ = self.advance(); // try
        const block = try self.parseBlock();
        var catch_param: ?*Node = null;
        var catch_block: ?*Node = null;
        var finally_block: ?*Node = null;
        if (isKeyword(self.cur(), "catch")) {
            _ = self.advance();
            if (self.match(.lparen)) {
                catch_param = try self.parseBindingTarget(); // identifier or destructuring pattern
                try self.expect(.rparen);
            }
            catch_block = try self.parseBlock();
            if (catch_param) |p| try self.checkCatchClause(p, catch_block.?);
        }
        if (isKeyword(self.cur(), "finally")) {
            _ = self.advance();
            finally_block = try self.parseBlock();
        }
        if (catch_block == null and finally_block == null) return ParseError.UnexpectedToken;
        const node = try self.arena.create(ast.TryNode);
        node.* = .{ .block = block, .catch_param = catch_param, .catch_block = catch_block, .finally_block = finally_block };
        return self.alloc(.{ .try_stmt = node });
    }

    /// Parse `(p1, p2 = default, ...rest)` into a slice of parameters.
    fn parseParamList(self: *Parser) ParseError![]const ast.Param {
        return self.parseParamListForAccessor(.none);
    }

    fn parseParamListForAccessor(self: *Parser, accessor: ast.AccessorKind) ParseError![]const ast.Param {
        try self.expect(.lparen);
        // MethodDefinition / PropertySetParameterList: a getter has no
        // parameters and a setter has one FormalParameter, not FormalParameters.
        // Validate here: a later AST arity check loses trailing commas and may
        // diagnose a body error before the invalid parameter list.
        if (accessor == .get and !self.check(.rparen)) return self.failWithTokenReason(.getter_parameters);
        if (accessor == .set and self.check(.rparen)) return self.failWithTokenReason(.setter_parameters);
        var params: std.ArrayListUnmanaged(ast.Param) = .empty;
        while (!self.check(.rparen) and !self.check(.eof)) {
            if (accessor == .set and (self.check(.ellipsis) or self.check(.comma)))
                return self.failWithTokenReason(.setter_parameter_pattern);
            const is_rest = self.match(.ellipsis);
            // Destructuring parameter: `function f({a}, [b])`, and rest
            // destructuring: `function f(...[a], ...{a})` (no default allowed
            // on a rest element, and it must be last).
            if (self.check(.lbrace) or self.check(.lbracket)) {
                const pat = try self.parseBindingTarget();
                const default = if (!is_rest and self.match(.assign)) try self.parseAssignment() else null;
                try params.append(self.arena, .{ .name = "", .pattern = pat, .default = default, .is_rest = is_rest });
                if (is_rest) break; // a rest parameter must be last
                if (accessor == .set and !self.check(.rparen)) return self.failWithTokenReason(.setter_parameters);
                if (!self.match(.comma)) break;
                continue;
            }
            const p = self.advance();
            if (p.kind != .identifier) return ParseError.UnexpectedToken;
            if (self.isForbiddenBindingName(p.text)) return ParseError.UnexpectedToken;
            var default: ?*Node = null;
            if (!is_rest and self.match(.assign)) default = try self.parseAssignment();
            try params.append(self.arena, .{ .name = p.text, .default = default, .is_rest = is_rest });
            if (is_rest) break; // a rest parameter must be last
            if (accessor == .set and !self.check(.rparen)) return self.failWithTokenReason(.setter_parameters);
            if (!self.match(.comma)) break;
        }
        if (accessor != .none and self.check(.eof)) return self.failWithTokenReason(.setter_parameters);
        try self.expect(.rparen);
        return params.items;
    }

    /// Parse a function/method's formal parameter list in that function's own
    /// [Yield, Await] context: a generator's parameters are [+Yield] and an async
    /// function's are [+Await], so `yield`/`await` is a reserved word there
    /// (`function* g(yield) {}`, `async function f(await) {}` are errors) and a
    /// YieldExpression/AwaitExpression among the parameter defaults
    /// (`function* g(a = yield) {}`, `async function f(a = await x) {}`) is the
    /// early error "FormalParameters Contains Yield/AwaitExpression". A function
    /// nested in a generator/async function gets its OWN context (it does not
    /// inherit), so `yield`/`await` is an ordinary identifier in its parameters
    /// again. (Arrows, which DO inherit, use parseParamList directly instead.)
    fn parseFunctionParamList(self: *Parser, is_gen: bool, is_async: bool) ParseError![]const ast.Param {
        return self.parseFunctionParamListForAccessor(is_gen, is_async, .none);
    }

    fn parseFunctionParamListForAccessor(self: *Parser, is_gen: bool, is_async: bool, accessor: ast.AccessorKind) ParseError![]const ast.Param {
        const saved_async = self.in_async;
        const saved_gen = self.in_generator;
        self.new_target_depth += 1;
        self.in_async = is_async;
        self.in_generator = is_gen;
        defer {
            self.in_async = saved_async;
            self.in_generator = saved_gen;
            self.new_target_depth -= 1;
        }
        const params = try self.parseParamListForAccessor(accessor);
        if (is_gen or is_async) {
            try self.forbidYieldAwaitInParams(params, is_gen, is_async);
        }
        return params;
    }

    /// Validate a dynamic Function constructor's joined parameter string as a
    /// standalone FormalParameters parse. The caller supplies source shaped like
    /// `(params)`; requiring EOF prevents comments/templates in `params` from
    /// consuming the constructor-inserted boundary before the body parse.
    pub fn parseDynamicFunctionParams(self: *Parser, is_gen: bool, is_async: bool) ParseError!void {
        _ = try self.parseFunctionParamList(is_gen, is_async);
        if (!self.check(.eof)) return ParseError.UnexpectedToken;
    }

    /// CreateDynamicFunction requires the supplied body text to remain inside
    /// the synthesized function. A body that closes the function early can make
    /// the assembled wrapper parse successfully, so require the parse to contain
    /// exactly that one function expression with the complete expected span.
    pub fn validateDynamicFunctionProgram(self: *Parser, program: *const Node, expected_source: []const u8) ParseError!void {
        if (program.* != .program or program.program.len != 1) return self.fail(ParseError.UnexpectedToken);
        const statement = program.program[0];
        if (statement.* != .expr_stmt or statement.expr_stmt.* != .function)
            return self.fail(ParseError.UnexpectedToken);
        const parsed_source = statement.expr_stmt.function.source;
        if (parsed_source.len != expected_source.len or parsed_source.ptr != expected_source.ptr)
            return self.fail(ParseError.UnexpectedToken);
    }

    fn isEvalOrArguments(name: []const u8) bool {
        return std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments");
    }

    fn recordArgumentsUse(self: *Parser, name: []const u8) void {
        if (self.current_arguments_use) |uses_arguments| {
            if (std.mem.eql(u8, name, "arguments")) uses_arguments.* = true;
        }
    }

    fn recordDirectEvalUse(self: *Parser, callee: *const Node) void {
        if (callee.* != .identifier or !std.mem.eql(u8, callee.identifier, "eval")) return;
        if (self.current_direct_eval_use) |uses_direct_eval| uses_direct_eval.* = true;
    }

    fn isAnnexBCallAssignmentTarget(node: *const Node) bool {
        return node.* == .call;
    }

    /// Strict-mode early errors on a formal parameter list: a parameter named
    /// `eval`/`arguments`, or any duplicate parameter name, is a SyntaxError.
    fn validateStrictParams(self: *Parser, params: []const ast.Param) ParseError!void {
        var simple_count: u32 = 0;
        for (params) |p| if (p.pattern == null) {
            if (simple_count == std.math.maxInt(u32)) return error.OutOfMemory;
            simple_count += 1;
        };

        // The parser already owns the complete FormalParameters slice. Reserve
        // its exact simple-name count once so an attacker-sized unique list
        // cannot force geometric allocation and repeated rehashing. Zero and
        // one name need only the semantic checks below and allocate no index.
        var seen = self.secureStringMap(void);
        defer seen.deinit(self.scratch_allocator);
        if (simple_count > 1) try seen.ensureTotalCapacity(self.scratch_allocator, simple_count);
        for (params) |p| {
            if (p.pattern != null) continue;
            if (std.mem.eql(u8, p.name, "eval") or std.mem.eql(u8, p.name, "arguments"))
                return self.failWithReasonAt(.invalid_strict_parameters, self.sourceOffsetForSlice(p.name, self.cur().pos));
            if (isStrictReservedBinding(p.name))
                return self.failWithReasonAt(.invalid_strict_parameters, self.sourceOffsetForSlice(p.name, self.cur().pos));
            if (simple_count == 1) continue;
            const entry = try seen.getOrPut(self.scratch_allocator, p.name);
            if (entry.found_existing)
                return self.failWithReasonAt(.invalid_strict_parameters, self.sourceOffsetForSlice(p.name, self.cur().pos));
        }
    }

    /// UniqueFormalParameters: duplicate simple parameter names are an early
    /// error for arrow functions and method definitions in EVERY mode (unlike
    /// ordinary functions, which permit them in sloppy mode with a simple param
    /// list). Mirrors the duplicate-name scan in validateStrictParams; pattern
    /// params are not simple names and are skipped (their own binding-dup rule is
    /// separate), so no valid parameter list is rejected.
    fn checkDuplicateParams(self: *Parser, params: []const ast.Param) ParseError!void {
        // BoundNames of the parameter list must contain no duplicates — including
        // names bound inside destructuring patterns, so `([a], {a}) => {}` and
        // `({a, a}) => {}` are early errors.
        var seen = self.secureStringMap(void);
        for (params) |p| {
            var names: std.ArrayListUnmanaged([]const u8) = .empty;
            if (p.pattern) |pat| try self.addPatternNames(&names, pat) else if (p.name.len > 0) try names.append(self.arena, p.name);
            for (names.items) |n| {
                if (seen.contains(n)) return ParseError.UnexpectedToken;
                try seen.put(self.arena, n, {});
            }
        }
    }

    /// A "simple parameter list" contains only single BindingIdentifiers — no
    /// defaults, rest, or destructuring. A function whose body opens with its
    /// OWN "use strict" directive must have a simple parameter list, an early
    /// error in every mode; this reports whether the list is non-simple.
    fn hasNonSimpleParams(params: []const ast.Param) bool {
        for (params) |p| {
            if (p.pattern != null or p.is_rest or p.default != null) return true;
        }
        return false;
    }

    /// An ordinary `function`/`function*`/`async function[*]` has no
    /// [[HomeObject]] and no `super` binding, so a SuperCall (`super()`) or
    /// SuperProperty (`super.x`) anywhere in its parameters or body — including
    /// inside a nested arrow, which inherits the absent binding — is an early
    /// SyntaxError (`arguments` stays legal). The scan stops at nested ordinary
    /// functions/classes/methods, which establish their own `super`.
    fn forbidSuperInFunction(self: *Parser, body: *Node, params: []const ast.Param) ParseError!void {
        const saved_args = self.scan_allow_arguments;
        const saved_prop = self.scan_forbid_super_property;
        self.scan_allow_arguments = true;
        self.scan_forbid_super_property = true;
        defer {
            self.scan_allow_arguments = saved_args;
            self.scan_forbid_super_property = saved_prop;
        }
        try self.scanSuperAndArgsInParams(params);
        try self.scanSuperAndArgs(body);
    }

    fn parseFunctionDecl(self: *Parser, is_async: bool) ParseError!*Node {
        const start = self.pos;
        if (is_async) _ = self.advance(); // async
        _ = self.advance(); // function
        const is_gen = self.match(.star); // `function*` / `async function*`
        const name_tok = self.advance();
        if (name_tok.kind != .identifier) return self.failWithReasonAt(.function_name_required, name_tok.pos);
        if (self.strict and (isStrictReservedBinding(name_tok.text) or isEvalOrArguments(name_tok.text)))
            return self.failWithToken(.strict_function_name, name_tok);
        if (self.isForbiddenBindingName(name_tok.text)) return self.failWithToken(.function_keyword_name, name_tok);
        var uses_arguments = false;
        var uses_direct_eval = false;
        var uses_direct_eval_in_parameters = false;
        var uses_direct_eval_in_body = false;
        const saved_arguments_use = self.current_arguments_use;
        const saved_direct_eval_use = self.current_direct_eval_use;
        self.current_arguments_use = &uses_arguments;
        self.current_direct_eval_use = &uses_direct_eval_in_parameters;
        defer {
            self.current_arguments_use = saved_arguments_use;
            self.current_direct_eval_use = saved_direct_eval_use;
        }
        const params = try self.parseFunctionParamList(is_gen, is_async);
        self.current_direct_eval_use = &uses_direct_eval_in_body;
        const own_use_strict_token = self.peekUseStrictToken();
        const own_use_strict = own_use_strict_token != null;
        // This function's strictness: inherited OR its own "use strict" prologue.
        // Captured BEFORE parseFnBody, which clobbers `last_fn_strict` when it
        // parses nested functions (so it can't be used to stamp THIS function).
        const fn_strict = self.strict or own_use_strict;
        const body = try self.parseFnBody(is_gen, is_async);
        if (own_use_strict and hasNonSimpleParams(params))
            return self.failWithReasonAt(.strict_directive_non_simple_parameters, own_use_strict_token.?.pos);
        if (fn_strict and (isStrictReservedBinding(name_tok.text) or isEvalOrArguments(name_tok.text)))
            return self.failWithToken(.strict_function_name, name_tok);
        if (fn_strict) try self.validateStrictParams(params);
        try self.forbidSuperInFunction(body, params);
        // A generator/async function, or ANY function with a non-simple parameter
        // list (a default/rest/destructuring), has UniqueFormalParameters:
        // duplicate names are an error in every mode. Only a plain function with a
        // simple list permits sloppy duplicates (handled by validateStrictParams
        // in strict mode).
        if (is_gen or is_async or hasNonSimpleParams(params)) try self.checkDuplicateParams(params);
        try self.checkParamBodyConflict(params, body);
        uses_direct_eval = uses_direct_eval_in_parameters or uses_direct_eval_in_body;
        const fnode = try self.arena.create(ast.FunctionNode);
        fnode.* = .{ .name = name_tok.text, .params = params, .body = body, .source = self.sourceFrom(start), .is_expr_body = false, .is_generator = is_gen, .is_async = is_async, .is_strict = fn_strict, .uses_arguments = uses_arguments, .uses_direct_eval = uses_direct_eval, .uses_direct_eval_in_parameters = uses_direct_eval_in_parameters, .uses_direct_eval_in_body = uses_direct_eval_in_body };
        return self.alloc(.{ .func_decl = fnode });
    }

    /// `function [name](params) { body }` in expression position.
    fn parseFunctionExpr(self: *Parser, is_async: bool) ParseError!*Node {
        const start = self.pos;
        if (is_async) _ = self.advance(); // async
        _ = self.advance(); // function
        const is_gen = self.match(.star); // `function*` / `async function*`
        var name: []const u8 = "";
        if (self.check(.identifier) and !std.mem.eql(u8, self.cur().text, "")) {
            // Optional name (anything that isn't the opening paren).
            if (!self.check(.lparen)) {
                // A FunctionExpression's name is a BindingIdentifier scoped to the
                // function's OWN [Yield, Await] (a generator expr uses [+Yield],
                // a plain function expr [~Yield]), not the surrounding context —
                // so `function* g(){ (function yield(){}) }` is valid.
                const saved_gen = self.in_generator;
                const saved_async = self.in_async;
                self.in_generator = is_gen;
                self.in_async = is_async;
                const forbidden = self.isForbiddenBindingName(self.cur().text);
                self.in_generator = saved_gen;
                self.in_async = saved_async;
                if (forbidden) return ParseError.UnexpectedToken;
                name = self.advance().text;
            }
        }
        var uses_arguments = false;
        var uses_direct_eval = false;
        var uses_direct_eval_in_parameters = false;
        var uses_direct_eval_in_body = false;
        const saved_arguments_use = self.current_arguments_use;
        const saved_direct_eval_use = self.current_direct_eval_use;
        self.current_arguments_use = &uses_arguments;
        self.current_direct_eval_use = &uses_direct_eval_in_parameters;
        defer {
            self.current_arguments_use = saved_arguments_use;
            self.current_direct_eval_use = saved_direct_eval_use;
        }
        const params = try self.parseFunctionParamList(is_gen, is_async);
        self.current_direct_eval_use = &uses_direct_eval_in_body;
        const own_use_strict = self.peekUseStrict();
        const fn_strict = self.strict or own_use_strict; // captured before parseFnBody (see parseFunctionDecl)
        const body = try self.parseFnBody(is_gen, is_async);
        if (own_use_strict and hasNonSimpleParams(params)) return ParseError.UnexpectedToken;
        if (fn_strict and name.len > 0 and (isStrictReservedBinding(name) or isEvalOrArguments(name))) return ParseError.UnexpectedToken;
        if (fn_strict) try self.validateStrictParams(params);
        try self.forbidSuperInFunction(body, params);
        // A generator/async function, or ANY function with a non-simple parameter
        // list (a default/rest/destructuring), has UniqueFormalParameters:
        // duplicate names are an error in every mode. Only a plain function with a
        // simple list permits sloppy duplicates (handled by validateStrictParams
        // in strict mode).
        if (is_gen or is_async or hasNonSimpleParams(params)) try self.checkDuplicateParams(params);
        try self.checkParamBodyConflict(params, body);
        uses_direct_eval = uses_direct_eval_in_parameters or uses_direct_eval_in_body;
        const fnode = try self.arena.create(ast.FunctionNode);
        fnode.* = .{ .name = name, .params = params, .body = body, .source = self.sourceFrom(start), .is_expr_body = false, .has_name_binding = name.len > 0, .is_generator = is_gen, .is_async = is_async, .is_strict = fn_strict, .uses_arguments = uses_arguments, .uses_direct_eval = uses_direct_eval, .uses_direct_eval_in_parameters = uses_direct_eval_in_parameters, .uses_direct_eval_in_body = uses_direct_eval_in_body };
        return self.alloc(.{ .function = fnode });
    }

    /// Parse a function/method `{ body }`, recognizing `yield`/`await` as yield/
    /// await expressions iff `is_gen`/`is_async`. A function body opens fresh
    /// generator/async contexts (an inner non-generator function nested in a
    /// generator does not see `yield` as a keyword), restored on the way out.
    fn parseFnBody(self: *Parser, is_gen: bool, is_async: bool) ParseError!*Node {
        // A function body is its own var scope: its `var`s are not the
        // VarDeclaredNames of an enclosing `for` body (#933 item 8).
        const saved_for_body_vars = self.for_body_vars;
        self.for_body_vars = null;
        defer self.for_body_vars = saved_for_body_vars;
        const saved_gen = self.in_generator;
        const saved_async = self.in_async;
        const saved_strict = self.strict;
        const saved_iter = self.iter_depth;
        const saved_switch = self.switch_depth;
        const saved_labels = self.takeLabelContext();
        self.in_generator = is_gen;
        self.in_async = is_async;
        // A function body opens a fresh control-flow context: `return` is now
        // legal and `break`/`continue` can't target an outer loop/switch.
        self.fn_depth += 1;
        self.new_target_depth += 1;
        self.iter_depth = 0;
        self.switch_depth = 0;
        // A function is strict if it lexically inherits strictness or its own
        // body opens with a `"use strict"` directive prologue. Detect it up
        // front so nested functions parsed within inherit correctly.
        self.strict = saved_strict or self.peekUseStrict();
        self.last_fn_strict = self.strict;
        // A function body is `[+In]`, even nested in a for-init's `[~In]` context.
        const saved_no_in = self.no_in;
        self.no_in = false;
        defer {
            self.in_generator = saved_gen;
            self.in_async = saved_async;
            self.strict = saved_strict;
            self.fn_depth -= 1;
            self.new_target_depth -= 1;
            self.iter_depth = saved_iter;
            self.switch_depth = saved_switch;
            self.restoreLabelContext(saved_labels);
            self.no_in = saved_no_in;
        }
        const body = try self.parseBlock();
        // Checked here, with this body's strictness and context still in
        // force, rather than by the post-parse scope walk (#930 family 1).
        try self.checkFunctionBodyDeclarations(body);
        return body;
    }

    /// Does a `"use strict"` directive lead the body about to be parsed? The
    /// current token is the opening `{`; a directive prologue is a leading run of
    /// string-literal expression statements, so scan those (skipping the `{` and
    /// statement-separating `;`) and stop at the first non-directive token.
    fn peekUseStrictToken(self: *Parser) ?Token {
        var i = self.pos;
        if (self.tokenAt(i).kind != .lbrace) return null;
        i += 1;
        while (self.tokenAt(i).kind == .string) {
            const t = self.tokenAt(i);
            // A "use strict" directive must be the EXACT source `'use strict'` /
            // `"use strict"` — no escapes or line continuations. The decoded text
            // matching isn't enough (`'use \strict'` decodes to "use strict" but
            // is not a directive), so require the raw lexeme to be just the quoted
            // text: end - pos == text.len + 2 (the two quote characters).
            if (std.mem.eql(u8, t.text, "use strict") and t.end - t.pos == t.text.len + 2) return t;
            i += 1;
            if (self.tokenAt(i).kind == .semicolon) i += 1;
        }
        return null;
    }

    fn peekUseStrict(self: *Parser) bool {
        return self.peekUseStrictToken() != null;
    }

    /// `yield [expr]` / `yield* expr`. Only reached inside a generator body.
    fn parseYield(self: *Parser) ParseError!*Node {
        _ = self.advance(); // yield
        // `yield [no LineTerminator here] * AssignmentExpression`: a `*` on the
        // next line is not part of the yield, so `yield \n * x` is a SyntaxError
        // (the orphaned `*` fails to parse as the yield's operand below).
        const delegate = self.noNewlineBefore(0) and self.match(.star);
        var arg: ?*Node = null;
        // `yield [no LineTerminator here] AssignmentExpression`: a newline after a
        // plain `yield` ends it (the next line is a separate statement), so
        // `yield \n x` yields undefined. `yield*` always takes an operand (its
        // newline restriction, before the `*`, was already enforced above).
        if (delegate or (self.noNewlineBefore(0) and self.startsExpression())) {
            arg = try self.parseAssignment();
        }
        return self.alloc(.{ .yield_expr = .{ .argument = arg, .delegate = delegate } });
    }

    fn parseRegexLiteralFromSlash(self: *Parser) ParseError!*Node {
        const token = self.curRegExp();
        if (token.kind != .regex) return ParseError.UnexpectedToken;
        _ = self.advance();
        try self.validateRegexLiteral(token.text, token.flags, token.pos);
        return self.alloc(.{ .regex_literal = .{ .pattern = token.text, .flags = token.flags } });
    }

    /// Whether the current token can begin an expression (used to decide if a
    /// bare `yield`/`return` has an operand). Conservative: treats clause
    /// terminators as non-starters.
    fn startsExpression(self: *Parser) bool {
        return switch (self.cur().kind) {
            .rparen, .rbracket, .rbrace, .comma, .semicolon, .colon, .eof => false,
            else => true,
        };
    }

    // ----- expressions ----------------------------------------------------

    fn parseExpression(self: *Parser) ParseError!*Node {
        var e = try self.parseAssignment();
        // The comma operator (only at true expression positions — arg lists,
        // array/object elements, and declarators use parseAssignment directly).
        while (self.check(.comma)) {
            _ = self.advance();
            const rhs = try self.parseAssignment();
            e = try self.alloc(.{ .sequence = .{ .first = e, .second = rhs } });
        }
        return e;
    }

    fn parseAssignment(self: *Parser) ParseError!*Node {
        try self.checkNesting();
        // `yield` is an AssignmentExpression-level production inside generators.
        if (self.in_generator and isKeyword(self.cur(), "yield")) return self.parseYield();
        // Async arrows: `async x => ...` and `async (a, b) => ...`. (`async` here
        // is a contextual keyword; a `=>` must follow its parameter list.)
        // An escaped `async` (`async`) is never the contextual keyword, so it
        // cannot begin an async arrow; a LineTerminator after `async` also breaks
        // the `async [no LineTerminator here] ArrowParameters` form (`async\n(x)=>`
        // is a call, not an arrow).
        if (isKeyword(self.cur(), "async") and !self.cur().escaped_identifier and self.noNewlineBefore(1)) {
            const start = self.pos;
            if (self.peekKind(1) == .identifier and self.peekKind(2) == .arrow and
                !isAlwaysReservedBinding(self.tokens.items[self.pos + 1].text) and
                !(self.strict and isStrictReservedBinding(self.tokens.items[self.pos + 1].text)))
            {
                _ = self.advance(); // async
                const param = self.advance().text;
                // An async arrow's parameter is [+Await]: `await` is reserved.
                if (std.mem.eql(u8, param, "await")) return ParseError.UnexpectedToken;
                const params = try self.arena.dupe(ast.Param, &.{.{ .name = param }});
                return self.parseArrowBody(params, true, start, false);
            }
            if (self.peekKind(1) == .lparen and try self.arrowAheadAt(self.pos + 1)) {
                _ = self.advance(); // async
                var uses_direct_eval_in_parameters = false;
                const saved_direct_eval_use = self.current_direct_eval_use;
                self.current_direct_eval_use = &uses_direct_eval_in_parameters;
                const params = try self.parseAsyncArrowParams();
                self.current_direct_eval_use = saved_direct_eval_use;
                if (uses_direct_eval_in_parameters) {
                    if (saved_direct_eval_use) |use| use.* = true;
                }
                return self.parseArrowBody(params, true, start, uses_direct_eval_in_parameters);
            }
        }
        // Arrow functions: `x => ...` and `(a, b) => ...`.
        if (self.check(.identifier) and self.peekKind(1) == .arrow) {
            const start = self.pos;
            // No LineTerminator is allowed between the parameter and `=>`
            // (the `[no LineTerminator here]` ASI restriction): `x \n => x` is a
            // SyntaxError. The single binding must also be a legal name (not
            // `eval`/`arguments`/a reserved word in the current strict/[Yield,
            // Await] context).
            if (!self.noNewlineBefore(1)) return ParseError.UnexpectedToken;
            const param = self.advance().text;
            if (self.isForbiddenBindingName(param)) return ParseError.UnexpectedToken;
            const params = try self.arena.dupe(ast.Param, &.{.{ .name = param }});
            return self.parseArrowBody(params, false, start, false);
        }
        if (self.check(.lparen) and try self.arrowAhead()) {
            const start = self.pos;
            var uses_direct_eval_in_parameters = false;
            const saved_direct_eval_use = self.current_direct_eval_use;
            self.current_direct_eval_use = &uses_direct_eval_in_parameters;
            const params = try self.parseParamList();
            self.current_direct_eval_use = saved_direct_eval_use;
            if (uses_direct_eval_in_parameters) {
                if (saved_direct_eval_use) |use| use.* = true;
            }
            // An arrow inherits [Yield]/[Await], so a YieldExpression (in a
            // generator) or AwaitExpression (in an async function/module) among
            // its parameter defaults is an early error: `function* g(){ (x =
            // yield) => {}; }`.
            if (self.in_generator or self.in_async or self.module) {
                try self.forbidYieldAwaitInParams(params, self.in_generator, self.in_async or self.module);
            }
            return self.parseArrowBody(params, false, start, uses_direct_eval_in_parameters);
        }

        const expression_start = self.pos;
        const left = try self.parseConditional();
        if (self.check(.assign)) {
            // An array/object literal on the LHS is a destructuring pattern.
            const target = switch (left.*) {
                .identifier, .member, .super_member => left,
                .call => if (!self.strict and isAnnexBCallAssignmentTarget(left)) left else return self.failWithReasonAt(.invalid_assignment, self.cur().pos),
                .array_lit, .object_lit => self.litToPattern(left) catch |err| {
                    if (err == ParseError.InvalidAssignmentTarget and
                        (self.last_error_reason == .invalid_destructuring_assignment or self.last_error_reason == .invalid_assignment))
                        self.last_error_offset = self.tokens.items[expression_start].pos;
                    return err;
                },
                else => return self.failWithReasonAt(.invalid_assignment, self.cur().pos),
            };
            // Strict mode forbids assigning to `eval`/`arguments`.
            if (self.strict and target.* == .identifier and isEvalOrArguments(target.identifier))
                return self.failWithReasonAt(if (std.mem.eql(u8, target.identifier, "eval")) .strict_modify_eval else .strict_modify_arguments, self.tokens.items[expression_start].pos);
            // A parenthesized LHS (`(f) = function(){}`) is not an IdentifierRef,
            // so NamedEvaluation does not apply — the function stays anonymous.
            const assign_pos = self.pos;
            const lhs_paren = self.isParenWrapped(target) or
                (target.* == .identifier and self.paren_assign_target_name != null and std.mem.eql(u8, target.identifier, self.paren_assign_target_name.?)) or
                (target.* == .identifier and self.parenWrappedIdentifierBefore(assign_pos, target.identifier));
            self.paren_assign_target_name = null;
            _ = self.advance();
            const value = try self.parseAssignment();
            if (target.* == .identifier and !lhs_paren) nameAnon(value, target.identifier); // `f = function(){}`
            if (target.* == .member) target.member.source = self.sourceFrom(expression_start);
            return self.alloc(.{ .assign = .{ .target = target, .value = value, .target_parenthesized = lhs_paren } });
        }
        // Compound assignment `a op= b` desugars to `a = a op b`.
        const compound: ?ast.BinaryOp = switch (self.cur().kind) {
            .plus_eq => .add,
            .minus_eq => .sub,
            .star_eq => .mul,
            .slash_eq => .div,
            .percent_eq => .mod,
            .star_star_eq => .pow,
            .shl_eq => .shl,
            .shr_eq => .shr,
            .ushr_eq => .ushr,
            .amp_eq => .bit_and,
            .pipe_eq => .bit_or,
            .caret_eq => .bit_xor,
            else => null,
        };
        if (compound) |op| {
            if (left.* != .identifier and left.* != .member and left.* != .super_member and
                (self.strict or !isAnnexBCallAssignmentTarget(left)))
                return self.failWithReasonAt(.invalid_assignment, self.cur().pos);
            if (self.strict and left.* == .identifier and isEvalOrArguments(left.identifier))
                return self.failWithReasonAt(if (std.mem.eql(u8, left.identifier, "eval")) .strict_modify_eval else .strict_modify_arguments, self.tokens.items[expression_start].pos);
            _ = self.advance();
            const rhs = try self.parseAssignment();
            return self.alloc(.{ .op_assign = .{ .target = left, .op = op, .value = rhs } });
        }
        // Logical assignment retains one LeftHandSide Reference across GetValue,
        // the short-circuit decision, RHS evaluation, and possible PutValue.
        const logassign: ?ast.LogicalOp = switch (self.cur().kind) {
            .amp_amp_eq => .@"and",
            .pipe_pipe_eq => .@"or",
            .qq_eq => .nullish,
            else => null,
        };
        if (logassign) |op| {
            if (left.* != .identifier and left.* != .member and left.* != .super_member)
                return self.failWithReasonAt(.invalid_assignment, self.cur().pos);
            if (self.strict and left.* == .identifier and isEvalOrArguments(left.identifier))
                return self.failWithReasonAt(if (std.mem.eql(u8, left.identifier, "eval")) .strict_modify_eval else .strict_modify_arguments, self.tokens.items[expression_start].pos);
            // A parenthesized LHS (`(a) ||= function(){}`) is not an IdentifierRef,
            // so NamedEvaluation does not apply (mirrors the plain-`=` check above).
            const assign_pos = self.pos;
            const lhs_paren = self.isParenWrapped(left) or
                (left.* == .identifier and self.paren_assign_target_name != null and std.mem.eql(u8, left.identifier, self.paren_assign_target_name.?)) or
                (left.* == .identifier and self.parenWrappedIdentifierBefore(assign_pos, left.identifier));
            self.paren_assign_target_name = null;
            _ = self.advance();
            const rhs = try self.parseAssignment();
            // NamedEvaluation: `a ||= function(){}` names the anonymous RHS "a".
            if (left.* == .identifier and !lhs_paren) nameAnon(rhs, left.identifier);
            return self.alloc(.{ .logical_assign = .{ .target = left, .op = op, .value = rhs } });
        }
        return left;
    }

    fn peekKind(self: *Parser, ahead: usize) TokenKind {
        return self.tokenAt(self.pos + ahead).kind;
    }

    /// True if the token `ahead` of the cursor is an identifier with text `word`
    /// (i.e. one of the contextual keywords the lexer emits as identifiers).
    fn peekIsKeyword(self: *Parser, ahead: usize, word: []const u8) bool {
        const t = self.tokenAt(self.pos + ahead);
        return t.kind == .identifier and std.mem.eql(u8, t.text, word);
    }

    /// True when an `async` modifier begins a method/property: `async name(...)`,
    /// `async *gen(...)`, or `async [computed](...)`. A bare `async` property
    /// (`{ async }`, `{ async: 1 }`, `{ async() {} }`) is *not* a modifier.
    fn asyncMethodAhead(self: *Parser) bool {
        // An escaped `async` (`async`) is never the contextual keyword, and a
        // LineTerminator after `async` breaks the `async [no LineTerminator here]
        // MethodName` form (`async` then becomes a property/field name).
        if (self.cur().escaped_identifier) return false;
        if (!isKeyword(self.cur(), "async")) return false;
        if (!self.noNewlineBefore(1)) return false;
        return switch (self.peekKind(1)) {
            .identifier, .string, .number, .private_name, .lbracket, .star => true,
            else => false,
        };
    }

    /// Precondition: current token is `(`. Returns true if its matching `)` is
    /// immediately followed by `=>` (i.e. this is an arrow parameter list, not
    /// a parenthesized expression).
    fn arrowAhead(self: *Parser) ParseError!bool {
        return self.arrowAheadAt(self.pos);
    }

    /// Like `arrowAhead`, but scanning a `(` that begins at token index `start`
    /// (used to peek past an `async` modifier: `async (params) => …`).
    fn arrowAheadAt(self: *Parser, start: usize) ParseError!bool {
        const open_offset = self.tokenAt(start).pos;
        if (self.arrow_lookahead.get(open_offset)) |cached| return cached;
        const saved_lexer = self.lexer;
        const saved_token_len = self.tokens.items.len;
        const saved_lex_error = self.lex_error;
        const saved_lex_error_offset = self.lex_error_offset;
        const saved_html_comment_offset = self.html_comment_offset;
        const saved_paren_close = self.paren_close;

        var lookahead_arena = std.heap.ArenaAllocator.init(self.scratch_allocator);
        defer lookahead_arena.deinit();
        const scan = scan: {
            self.lexer = try saved_lexer.fork(lookahead_arena.allocator());
            self.lex_error = null;
            self.paren_close = null;
            defer {
                self.tokens.items.len = saved_token_len;
                self.lexer = saved_lexer;
                self.lex_error = saved_lex_error;
                self.lex_error_offset = saved_lex_error_offset;
                self.html_comment_offset = saved_html_comment_offset;
                self.paren_close = saved_paren_close;
            }

            const close = try self.matchingParen(start);
            const guessed = if (close) |index| self.tokenAt(index + 1).kind == .arrow else false;
            const scan_end = if (close) |index| @min(index + 1, self.tokens.items.len) else self.tokens.items.len;
            var saw_slash = false;
            for (self.tokens.items[start..scan_end]) |token| {
                if (isSlashToken(token.kind)) {
                    saw_slash = true;
                    break;
                }
            }
            const ambiguous = self.lex_error != null or saw_slash;
            if (!ambiguous) {
                if (self.paren_close) |table| {
                    for (self.tokens.items, 0..) |token, index| {
                        if (token.kind != .lparen or index >= table.len) continue;
                        const close_index = table[index];
                        if (close_index == no_matching_paren) continue;
                        try self.arrow_lookahead.put(
                            self.arena,
                            token.pos,
                            self.tokenAt(@as(usize, close_index) + 1).kind == .arrow,
                        );
                    }
                } else try self.arrow_lookahead.put(self.arena, open_offset, guessed);
            }
            break :scan .{
                .guessed = guessed,
                .ambiguous = ambiguous,
            };
        };

        if (!scan.ambiguous) return scan.guessed;
        return self.sourceParenFollowedByArrow(open_offset);
    }

    const ParenScanState = struct { offset: usize, depth: usize };

    fn isSlashToken(kind: TokenKind) bool {
        return kind == .slash or kind == .slash_eq or kind == .regex;
    }

    /// Resolve a slash-ambiguous arrow lookahead without committing either
    /// lexical interpretation. Each slash contributes its division continuation
    /// and, when a complete literal exists, its RegExp continuation. Equal
    /// (offset, depth) states converge, so repeated ambiguity remains bounded by
    /// the source span rather than multiplying paths.
    fn sourceParenFollowedByArrow(self: *Parser, open_offset: usize) ParseError!bool {
        var pending: std.ArrayListUnmanaged(ParenScanState) = .empty;
        defer pending.deinit(self.scratch_allocator);
        var visited = std.AutoHashMapUnmanaged(ParenScanState, void).empty;
        defer visited.deinit(self.scratch_allocator);
        try pending.append(self.scratch_allocator, .{ .offset = open_offset + 1, .depth = 1 });

        while (pending.pop()) |initial| {
            var state = initial;
            while (state.offset < self.source.len) {
                const entry = try visited.getOrPut(self.scratch_allocator, state);
                if (entry.found_existing) break;

                const c = self.source[state.offset];
                if (c == '\'' or c == '"') {
                    state.offset = scanQuotedSource(self.source, state.offset, c) orelse break;
                    continue;
                }
                if (c == '`') {
                    state.offset = scanTemplateSource(self.source, state.offset) orelse break;
                    continue;
                }
                if (c == '/' and state.offset + 1 < self.source.len and self.source[state.offset + 1] == '/') {
                    state.offset += 2;
                    while (state.offset < self.source.len and lex.lineTerminatorLen(self.source, state.offset) == null) state.offset += 1;
                    continue;
                }
                if (c == '/' and state.offset + 1 < self.source.len and self.source[state.offset + 1] == '*') {
                    const end = std.mem.indexOfPos(u8, self.source, state.offset + 2, "*/") orelse break;
                    state.offset = end + 2;
                    continue;
                }
                if (c == '/') {
                    if (scanRegexSource(self.source, state.offset)) |regex_end|
                        try pending.append(self.scratch_allocator, .{ .offset = regex_end, .depth = state.depth });
                    state.offset += if (state.offset + 1 < self.source.len and self.source[state.offset + 1] == '=') 2 else 1;
                    continue;
                }
                if (c == '(') {
                    state.depth += 1;
                } else if (c == ')') {
                    state.depth -= 1;
                    if (state.depth == 0) {
                        var after = state.offset + 1;
                        while (after < self.source.len and std.ascii.isWhitespace(self.source[after])) after += 1;
                        if (after + 1 < self.source.len and self.source[after] == '=' and self.source[after + 1] == '>') return true;
                        break;
                    }
                }
                state.offset += 1;
            }
        }
        return false;
    }

    fn scanQuotedSource(source: []const u8, start: usize, quote: u8) ?usize {
        var i = start + 1;
        while (i < source.len) {
            if (source[i] == '\\') {
                i += 2;
                continue;
            }
            if (source[i] == quote) return i + 1;
            if (lex.lineTerminatorLen(source, i) != null) return null;
            i += 1;
        }
        return null;
    }

    fn scanTemplateSource(source: []const u8, start: usize) ?usize {
        var i = start + 1;
        while (i < source.len) {
            if (source[i] == '\\') {
                i += 2;
                continue;
            }
            if (source[i] == '`') return i + 1;
            if (source[i] == '$' and i + 1 < source.len and source[i + 1] == '{') {
                i = scanTemplateSubstitutionSource(source, i + 2) orelse return null;
                continue;
            }
            i += 1;
        }
        return null;
    }

    fn scanTemplateSubstitutionSource(source: []const u8, start: usize) ?usize {
        var i = start;
        var brace_depth: usize = 0;
        while (i < source.len) {
            const c = source[i];
            if (c == '\'' or c == '"') {
                i = scanQuotedSource(source, i, c) orelse return null;
                continue;
            }
            if (c == '`') {
                i = scanTemplateSource(source, i) orelse return null;
                continue;
            }
            if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
                i += 2;
                while (i < source.len and lex.lineTerminatorLen(source, i) == null) i += 1;
                continue;
            }
            if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
                const end = std.mem.indexOfPos(u8, source, i + 2, "*/") orelse return null;
                i = end + 2;
                continue;
            }
            switch (c) {
                '{' => brace_depth += 1,
                '}' => {
                    if (brace_depth == 0) return i + 1;
                    brace_depth -= 1;
                },
                else => {},
            }
            i += 1;
        }
        return null;
    }

    fn scanRegexSource(source: []const u8, start: usize) ?usize {
        var i = start + 1;
        var in_class = false;
        while (i < source.len) {
            if (lex.lineTerminatorLen(source, i) != null) return null;
            switch (source[i]) {
                '\\' => i += 2,
                '[' => {
                    in_class = true;
                    i += 1;
                },
                ']' => {
                    in_class = false;
                    i += 1;
                },
                '/' => {
                    if (!in_class) {
                        i += 1;
                        while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_' or source[i] == '$')) i += 1;
                        return i;
                    }
                    i += 1;
                },
                else => i += 1,
            }
        }
        return null;
    }

    const no_matching_paren = std.math.maxInt(u32);
    /// Nesting a lookahead may cross before the parser indexes every paren.
    /// Every `(` of an AssignmentExpression asks for its match, so `N` nested
    /// parentheses rescanned the rest of the group `N` times -- quadratic, and
    /// on the path that fails at the stack floor each of those scans covered the
    /// whole remaining source (#933 item 8b). Real code never nests this deep,
    /// so it keeps the plain scan and never allocates the index.
    const deep_paren_nesting = 64;

    /// Token index of the `)` matching the `(` at `start`, or null when the
    /// parentheses are unbalanced.
    fn matchingParen(self: *Parser, start: usize) ParseError!?usize {
        if (self.paren_close) |table| {
            const close = table[start];
            return if (close == no_matching_paren) null else close;
        }
        var depth: usize = 0;
        var i = start;
        while (true) : (i += 1) {
            switch (self.tokenAt(i).kind) {
                .lparen => {
                    depth += 1;
                    if (depth > deep_paren_nesting and self.tokens.items.len < no_matching_paren) {
                        try self.indexParens();
                        return self.matchingParen(start);
                    }
                },
                .rparen => {
                    depth -= 1;
                    if (depth == 0) return i;
                },
                .eof => return null,
                else => {},
            }
        }
        return null;
    }

    /// Fill the disposable lookahead's token frontier, then record every `(`'s
    /// matching `)` in one pass. The index is used only while that frontier is
    /// stable; durable arrow results are translated to source offsets.
    fn indexParens(self: *Parser) ParseError!void {
        while (self.tokens.items.len == 0 or self.tokens.items[self.tokens.items.len - 1].kind != .eof) {
            const before = self.tokens.items.len;
            self.appendNextToken(.automatic);
            if (self.tokens.items.len == before) break;
        }
        if (self.pos < self.tokens.items.len) self.current_token = &self.tokens.items[self.pos];
        self.html_comment_offset = self.lexer.htmlCommentOffset();
        const table = try self.arena.alloc(u32, self.tokens.items.len);
        @memset(table, no_matching_paren);
        var open: std.ArrayListUnmanaged(u32) = .empty;
        defer open.deinit(self.scratch_allocator);
        for (self.tokens.items, 0..) |token, index| switch (token.kind) {
            .lparen => try open.append(self.scratch_allocator, @intCast(index)),
            .rparen => if (open.pop()) |opener| {
                table[opener] = @intCast(index);
            },
            else => {},
        };
        self.paren_close = table;
    }

    /// Parse an async arrow's `( params )` as [+Await] — `await` is reserved as a
    /// binding and an AwaitExpression among the defaults is the early error
    /// "FormalParameters Contains AwaitExpression" — while leaving the enclosing
    /// [Yield] context intact (an arrow inherits it, unlike an ordinary function).
    fn parseAsyncArrowParams(self: *Parser) ParseError![]const ast.Param {
        const saved_async = self.in_async;
        self.in_async = true;
        defer self.in_async = saved_async;
        const params = try self.parseParamList();
        try self.forbidYieldAwaitInParams(params, self.in_generator, true);
        return params;
    }

    fn parseArrowBody(self: *Parser, params: []const ast.Param, is_async: bool, start: usize, uses_direct_eval_in_parameters: bool) ParseError!*Node {
        // No LineTerminator is allowed between the parameter list and `=>`
        // (`() \n => {}` is a SyntaxError).
        if (!self.noNewlineBefore(0)) return ParseError.UnexpectedToken;
        try self.expect(.arrow);
        try self.checkDuplicateParams(params); // arrows forbid duplicate params in all modes

        const fnode = try self.arena.create(ast.FunctionNode);
        var uses_direct_eval_in_body = false;
        const saved_direct_eval_use = self.current_direct_eval_use;
        self.current_direct_eval_use = &uses_direct_eval_in_body;
        // An arrow's body opens its own async context (so `await` inside an
        // `async () => …` is recognized), restored on exit.
        const saved_async = self.in_async;
        const saved_gen = self.in_generator;
        const saved_strict = self.strict;
        const saved_iter = self.iter_depth;
        const saved_switch = self.switch_depth;
        const saved_no_in = self.no_in;
        const saved_labels = self.takeLabelContext();
        self.in_async = is_async;
        self.in_generator = false;
        self.fn_depth += 1;
        self.iter_depth = 0;
        self.switch_depth = 0;
        defer {
            self.in_async = saved_async;
            self.in_generator = saved_gen;
            self.strict = saved_strict;
            self.fn_depth -= 1;
            self.iter_depth = saved_iter;
            self.switch_depth = saved_switch;
            self.no_in = saved_no_in;
            self.restoreLabelContext(saved_labels);
            self.current_direct_eval_use = saved_direct_eval_use;
        }
        if (self.check(.lbrace)) {
            // A block-bodied arrow is a FunctionBody, not an AssignmentExpression,
            // so `in` is available again even inside a classic for initializer.
            self.no_in = false;
            const own_use_strict = self.peekUseStrict();
            if (own_use_strict and hasNonSimpleParams(params)) return ParseError.UnexpectedToken;
            self.strict = saved_strict or own_use_strict;
            if (own_use_strict) try self.validateStrictParams(params);
            // Its own var scope, like any function body (#933 item 8).
            const saved_for_body_vars = self.for_body_vars;
            self.for_body_vars = null;
            defer self.for_body_vars = saved_for_body_vars;
            const arrow_body = try self.parseBlock();
            try self.checkFunctionBodyDeclarations(arrow_body);
            fnode.* = .{ .params = params, .body = arrow_body, .is_expr_body = false, .is_arrow = true, .is_async = is_async, .is_strict = self.strict };
            try self.checkParamBodyConflict(params, fnode.body);
        } else {
            fnode.* = .{ .params = params, .body = try self.parseAssignment(), .is_expr_body = true, .is_arrow = true, .is_async = is_async, .is_strict = saved_strict };
        }
        fnode.uses_direct_eval_in_parameters = uses_direct_eval_in_parameters;
        fnode.uses_direct_eval_in_body = uses_direct_eval_in_body;
        fnode.uses_direct_eval = uses_direct_eval_in_parameters or uses_direct_eval_in_body;
        if (fnode.uses_direct_eval) {
            if (saved_direct_eval_use) |use| use.* = true;
        }
        fnode.source = self.sourceFrom(start);
        return self.alloc(.{ .function = fnode });
    }

    fn parseConditional(self: *Parser) ParseError!*Node {
        const cond = try self.parseBinary(0);
        if (self.match(.question)) {
            // The consequent of `?:` is always `[+In]`; the alternate inherits the
            // outer `[?In]` (so in a for-init `true ? 0 : 0 in {}` is an error).
            const saved_no_in = self.no_in;
            self.no_in = false;
            const cons = try self.parseAssignment();
            self.no_in = saved_no_in;
            try self.expect(.colon);
            const alt = try self.parseAssignment();
            return self.alloc(.{ .conditional = .{ .cond = cond, .consequent = cons, .alternate = alt } });
        }
        return cond;
    }

    const BinInfo = struct { bp: u8, binary: ?ast.BinaryOp = null, logical: ?ast.LogicalOp = null, right_assoc: bool = false };

    /// Binding info for the current token, including keyword operators
    /// (`instanceof`) that the lexer emits as plain identifiers. Binding powers
    /// follow JS precedence: `||` < `&&` < `|` < `^` < `&` < equality <
    /// relational < shift < additive < multiplicative < `**`.
    fn curBinInfo(self: *Parser) ?BinInfo {
        if (isKeyword(self.cur(), "instanceof")) return .{ .bp = 7, .binary = .instanceof };
        // `[~In]` (classic for-init): a top-level `in` is not a binary operator.
        if (!self.no_in and isKeyword(self.cur(), "in")) return .{ .bp = 7, .binary = .in_op };
        return binInfo(self.cur().kind);
    }

    fn binInfo(kind: TokenKind) ?BinInfo {
        return switch (kind) {
            .qq => .{ .bp = 1, .logical = .nullish },
            .pipe_pipe => .{ .bp = 1, .logical = .@"or" },
            .amp_amp => .{ .bp = 2, .logical = .@"and" },
            .pipe => .{ .bp = 3, .binary = .bit_or },
            .caret => .{ .bp = 4, .binary = .bit_xor },
            .amp => .{ .bp = 5, .binary = .bit_and },
            .eq => .{ .bp = 6, .binary = .eq },
            .neq => .{ .bp = 6, .binary = .neq },
            .eq_strict => .{ .bp = 6, .binary = .eq_strict },
            .neq_strict => .{ .bp = 6, .binary = .neq_strict },
            .lt => .{ .bp = 7, .binary = .lt },
            .le => .{ .bp = 7, .binary = .le },
            .gt => .{ .bp = 7, .binary = .gt },
            .ge => .{ .bp = 7, .binary = .ge },
            .shl => .{ .bp = 8, .binary = .shl },
            .shr => .{ .bp = 8, .binary = .shr },
            .ushr => .{ .bp = 8, .binary = .ushr },
            .plus => .{ .bp = 9, .binary = .add },
            .minus => .{ .bp = 9, .binary = .sub },
            .star => .{ .bp = 10, .binary = .mul },
            .slash => .{ .bp = 10, .binary = .div },
            .percent => .{ .bp = 10, .binary = .mod },
            .star_star => .{ .bp = 11, .binary = .pow, .right_assoc = true },
            else => null,
        };
    }

    /// The right operand of a binary operator. Only this recursion follows the
    /// source (`2 ** 2 ** …` is right-associative), so the nesting check sits
    /// here rather than on every operand the expression parser visits (#936).
    fn parseBinaryOperand(self: *Parser, min_bp: u8) ParseError!*Node {
        try self.checkNesting();
        return self.parseBinary(min_bp);
    }

    /// The operand of a prefix operator, which nests once per operator
    /// (`!!!…x`). Guarded here for the same reason as `parseBinaryOperand`.
    fn parseUnaryOperand(self: *Parser) ParseError!*Node {
        try self.checkNesting();
        return self.parseUnary();
    }

    fn parseBinary(self: *Parser, min_bp: u8) ParseError!*Node {
        // `#field in obj`: a private name is a valid primary only as the LHS of
        // `in` (a private brand check) — a RelationalExpression (bp 7). It can't
        // be the right operand of another relational op (`#a in #b in c` has the
        // middle `#b` in RHS position), so only recognize it when a relational
        // expression may start here (min_bp <= 7). Keep it distinct from an
        // IdentifierReference so later validation retains its exact offset.
        var left = if (min_bp <= 7 and !self.no_in and self.check(.private_name) and self.peekIsKeyword(1, "in")) blk: {
            const name = self.advance();
            if (!self.in_class) return self.failUndeclaredPrivateName(name);
            break :blk try self.alloc(.{ .private_identifier = .{ .name = name.text, .offset = name.pos } });
        } else try self.parseUnary();
        // `??` may not be combined with `||`/`&&` without parentheses
        // (CoalesceExpression and LogicalORExpression are distinct productions):
        // `a ?? b || c`, `a && b ?? c` are SyntaxErrors. Track, within this single
        // precedence level, whether a `??` and an `||`/`&&` both appear — a
        // parenthesized operand parses in a nested call, so it never trips this.
        var seen_coalesce = false;
        var seen_logical = false;
        while (self.curBinInfo()) |info| {
            if (info.bp < min_bp) break;
            if (info.logical) |lop| {
                if (lop == .nullish) {
                    if (seen_logical) return ParseError.UnexpectedToken;
                    seen_coalesce = true;
                } else {
                    if (seen_coalesce) return ParseError.UnexpectedToken;
                    seen_logical = true;
                }
            }
            _ = self.advance();
            // A `??` operand is a BitwiseORExpression, so it binds tighter than
            // `&&`/`||` — parse the right side above the logical level so an
            // unparenthesized `a ?? b && c` leaves `&& c` for the loop to reject.
            const next_min: u8 = if (info.logical == .nullish) 3 else if (info.right_assoc) info.bp else info.bp + 1;
            const right = try self.parseBinaryOperand(next_min);
            if (info.logical) |lop| {
                left = try self.alloc(.{ .logical = .{ .op = lop, .left = left, .right = right } });
            } else {
                left = try self.alloc(.{ .binary = .{ .op = info.binary.?, .left = left, .right = right } });
            }
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*Node {
        // `await expr` — a unary operator, only inside an async function body.
        // An escaped `await` (`await`) is never the keyword (the leftover
        // identifier is then rejected as a reserved reference in its context).
        if (self.in_async and !self.cur().escaped_identifier and isKeyword(self.cur(), "await")) {
            const await_token = self.advance();
            const operand = try self.parseUnaryOperand();
            try self.rejectExponentAfterUnary();
            return self.alloc(.{ .await_expr = .{ .argument = operand, .offset = await_token.pos } });
        }
        if (self.check(.plus_plus) or self.check(.minus_minus)) {
            const inc = self.cur().kind == .plus_plus;
            const operator_offset = self.cur().pos;
            _ = self.advance();
            const operand_offset = self.cur().pos;
            const operand = try self.parseUnaryOperand();
            // The operand of a prefix `++`/`--` must be a simple assignment
            // target (identifier or member access) — `++import(x)`, `++f()`,
            // `++1` are early SyntaxErrors.
            if (operand.* != .identifier and operand.* != .member and operand.* != .super_member and
                (self.strict or !isAnnexBCallAssignmentTarget(operand)))
                return self.failWithReasonAt(if (inc) .invalid_prefix_increment else .invalid_prefix_decrement, operator_offset);
            // Strict mode forbids updating `eval`/`arguments` (they are not valid
            // assignment targets): `"use strict"; ++eval;` is a SyntaxError.
            if (self.strict and operand.* == .identifier and isEvalOrArguments(operand.identifier))
                return self.failWithReasonAt(if (std.mem.eql(u8, operand.identifier, "eval")) .strict_modify_eval else .strict_modify_arguments, operand_offset);
            return self.alloc(.{ .update = .{ .inc = inc, .prefix = true, .target = operand } });
        }
        const t = self.cur();
        if (isKeyword(t, "delete")) {
            const delete_start = self.pos;
            _ = self.advance();
            const operand = try self.parseUnaryOperand();
            // Strict mode: `delete` of an unqualified identifier is a SyntaxError.
            if (self.strict and operand.* == .identifier) return ParseError.UnexpectedToken;
            // ECMA-262 13.5.1.1 includes private OptionalChain references. Only
            // unwrap the chain boundary: a public outer property, call result,
            // or comma-expression value is not itself a private reference.
            const reference = if (operand.* == .optional_chain) operand.optional_chain else operand;
            if (reference.* == .member and reference.member.property.len > 0 and reference.member.property[0] == '#') {
                const err = self.failWithReasonAt(.private_field_delete, t.pos);
                self.last_error_token = .{ .kind = .token, .text = reference.member.property };
                return err;
            }
            try self.rejectExponentAfterUnary();
            if (operand.* == .member) {
                operand.member.source = self.sourceFrom(delete_start);
            } else if (operand.* == .optional_chain and operand.optional_chain.* == .member) {
                operand.optional_chain.member.source = self.sourceFrom(delete_start);
            }
            return self.alloc(.{ .delete_expr = operand });
        }
        const op: ?ast.UnaryOp = switch (t.kind) {
            .minus => .neg,
            .plus => .pos,
            .bang => .not,
            .tilde => .bit_not,
            else => if (isKeyword(t, "typeof"))
                ast.UnaryOp.typeof
            else if (isKeyword(t, "void"))
                ast.UnaryOp.void_op
            else
                null,
        };
        if (op) |o| {
            _ = self.advance();
            const operand = try self.parseUnaryOperand();
            try self.rejectExponentAfterUnary();
            return self.alloc(.{ .unary = .{ .op = o, .operand = operand } });
        }
        return self.parsePostfix();
    }

    /// `ExponentiationExpression : UpdateExpression ** ...` — the left operand of
    /// `**` must be an UpdateExpression, never an unparenthesized UnaryExpression.
    /// So a `**` immediately following a just-parsed unary operator's operand
    /// (`-x ** 2`, `typeof x ** 2`, `await x ** 2`) is an early SyntaxError;
    /// parenthesizing (`(-x) ** 2`) or using an UpdateExpression (`++x ** 2`)
    /// avoids it. (Prefix `++`/`--` do not call this — they are UpdateExpressions.)
    fn rejectExponentAfterUnary(self: *Parser) ParseError!void {
        if (self.check(.star_star)) return ParseError.UnexpectedToken;
    }

    fn parsePostfix(self: *Parser) ParseError!*Node {
        // The first token of the LeftHandSideExpression, so a call suffix can
        // retain its exact source span (see `callSourceFrom`).
        const start_token = self.pos;
        const e = try self.parsePrimary();
        const m = try self.parseMemberTail(e, start_token);
        if ((self.check(.plus_plus) or self.check(.minus_minus)) and !self.hasLineTerminatorBefore(0)) {
            const inc = self.cur().kind == .plus_plus;
            // A postfix `++`/`--` target must be a simple assignment target —
            // `import(x)++`, `f()++`, `1++` are early SyntaxErrors.
            if (m.* != .identifier and m.* != .member and m.* != .super_member and
                (self.strict or !isAnnexBCallAssignmentTarget(m)))
                return self.failWithReasonAt(if (inc) .invalid_postfix_increment else .invalid_postfix_decrement, self.cur().pos);
            // Strict mode forbids updating `eval`/`arguments`: `"use strict";
            // eval++;` is a SyntaxError.
            if (self.strict and m.* == .identifier and isEvalOrArguments(m.identifier))
                return self.failWithReasonAt(if (std.mem.eql(u8, m.identifier, "eval")) .strict_postfix_eval else .strict_postfix_arguments, self.tokens.items[start_token].pos);
            _ = self.advance();
            return self.alloc(.{ .update = .{ .inc = inc, .prefix = false, .target = m } });
        }
        return m;
    }

    const MemberName = struct { text: []const u8, offset: usize };

    fn failUndeclaredPrivateName(self: *Parser, token: Token) ParseError {
        const err = self.failWithReasonAt(.undeclared_private_name, token.pos);
        self.last_error_token = .{ .kind = .token, .text = token.text };
        return err;
    }

    fn parseMemberName(self: *Parser) ParseError!MemberName {
        const name = self.advance();
        if (name.kind != .identifier and name.kind != .private_name) return ParseError.UnexpectedToken;
        if (name.kind == .private_name and !self.in_class) return self.failUndeclaredPrivateName(name);
        return .{ .text = name.text, .offset = name.pos };
    }

    /// A CallExpression's own source text and the byte length of its callee.
    const CallSource = struct { text: []const u8 = "", callee_len: u32 = 0 };

    /// The exact source of a just-parsed CallExpression plus the byte length of
    /// its callee prefix within that text. JavaScriptCore's `is not a function`
    /// diagnostic slices the callee from its first token up to the `(` — or the
    /// `?.` of an optional call — rather than to the end of the last callee
    /// token, so `a  .  b  (1)` names the callee `a  .  b  `.
    fn callSourceFrom(self: *Parser, start_token: usize, callee_end_token: usize) CallSource {
        const text = self.sourceFrom(start_token);
        if (text.len == 0 or start_token >= self.tokens.items.len or callee_end_token >= self.tokens.items.len)
            return .{};
        const lo = self.tokens.items[start_token].pos;
        const hi = self.tokens.items[callee_end_token].pos;
        if (hi < lo or hi - lo > text.len) return .{ .text = text };
        return .{ .text = text, .callee_len = @intCast(hi - lo) };
    }

    /// Consume a chain of `.prop`, `[expr]`, `?.…`, and `(args)` operators on `e`.
    /// `start_token` indexes the first token of `start`, so a call suffix can
    /// slice back to the beginning of its own callee expression.
    fn parseMemberTail(self: *Parser, start: *Node, start_token: usize) ParseError!*Node {
        var e = start;
        var has_optional = false;
        while (true) {
            // Bounds the callee text of a call suffix opening at this token.
            const suffix_token = self.pos;
            if (self.match(.dot)) {
                const name = try self.parseMemberName();
                e = try self.alloc(.{ .member = .{ .object = e, .property = name.text, .property_offset = name.offset, .source = self.sourceFrom(start_token) } });
            } else if (self.match(.question_dot)) {
                has_optional = true;
                if (self.check(.lparen)) {
                    const args = try self.parseArgs();
                    const source = self.callSourceFrom(start_token, suffix_token);
                    e = try self.alloc(.{ .call = .{
                        .callee = e,
                        .args = args,
                        .optional = true,
                        .source = source.text,
                        .callee_len = source.callee_len,
                    } });
                } else if (self.match(.lbracket)) {
                    const saved_no_in = self.no_in; // a computed key is `[+In]`
                    self.no_in = false;
                    const idx = try self.parseExpression();
                    self.no_in = saved_no_in;
                    try self.expect(.rbracket);
                    e = try self.alloc(.{ .member = .{ .object = e, .computed = idx, .optional = true, .source = self.sourceFrom(start_token) } });
                } else {
                    const name = try self.parseMemberName();
                    e = try self.alloc(.{ .member = .{ .object = e, .property = name.text, .property_offset = name.offset, .optional = true, .source = self.sourceFrom(start_token) } });
                }
            } else if (self.match(.lbracket)) {
                const saved_no_in = self.no_in; // a computed key is `[+In]`
                self.no_in = false;
                const idx = try self.parseExpression();
                self.no_in = saved_no_in;
                try self.expect(.rbracket);
                e = try self.alloc(.{ .member = .{ .object = e, .computed = idx, .source = self.sourceFrom(start_token) } });
            } else if (self.check(.lparen)) {
                const args = try self.parseArgs();
                if (!has_optional) self.recordDirectEvalUse(e);
                const source = self.callSourceFrom(start_token, suffix_token);
                e = try self.alloc(.{ .call = .{
                    .callee = e,
                    .args = args,
                    .source = source.text,
                    .callee_len = source.callee_len,
                } });
            } else if (self.check(.template_no_substitution) or self.check(.template_head)) {
                // A tagged template may not appear in an optional chain
                // (`a?.b`tmpl`` is a SyntaxError) — short-circuiting a tag call is
                // disallowed.
                if (has_optional) return ParseError.UnexpectedToken;
                // Tagged template: `tag`...`` — call `tag` with the cooked-string
                // array (carrying `raw`) and the substitution values.
                const tmpl = self.advance();
                e = try self.parseTaggedTemplate(e, tmpl, start_token);
            } else break;
        }
        if (has_optional) e = try self.alloc(.{ .optional_chain = e });
        return e;
    }

    fn parseArgs(self: *Parser) ParseError![]*Node {
        try self.expect(.lparen);
        const saved_no_in = self.no_in; // arguments are `[+In]`
        self.no_in = false;
        defer self.no_in = saved_no_in;
        var args: std.ArrayListUnmanaged(*Node) = .empty;
        while (!self.check(.rparen) and !self.check(.eof)) {
            try args.append(self.arena, try self.parseSpreadable());
            if (!self.match(.comma)) break;
        }
        try self.expect(.rparen);
        return args.items;
    }

    /// An array element or call argument, which may be a `...spread`.
    fn parseSpreadable(self: *Parser) ParseError!*Node {
        if (self.match(.ellipsis)) return self.alloc(.{ .spread = try self.parseAssignment() });
        return self.parseAssignment();
    }

    /// `new Callee(args)` — the callee is a member expression *without* a call
    /// (the first `(...)` is the constructor's argument list). Any trailing
    /// `.prop` / call chain is handled by the enclosing `parseMemberTail`.
    fn parseNew(self: *Parser) ParseError!*Node {
        try self.checkNesting();
        const new_start_token = self.pos;
        _ = self.advance(); // new
        if (self.in_async and isKeyword(self.cur(), "await")) return ParseError.UnexpectedToken;
        // `new.target` meta-property.
        if (self.match(.dot)) {
            const m = self.cur();
            // `target` is a contextual keyword here — it may not be escaped
            // (`new.\u0074arget` is not the NewTarget grammar).
            if (m.kind == .identifier and (m.escaped_identifier or !std.mem.eql(u8, m.text, "target")))
                return self.failWithTokenReason(.new_target_invalid_identifier);
            _ = self.advance();
            if (m.kind != .identifier) return ParseError.UnexpectedToken;
            // Keep the NewTarget early error attached to its own source token.
            // Template substitutions now share this parser and its offsets.
            if (self.new_target_depth == 0)
                return self.failWithReasonAt(if (self.fn_depth > 0) .new_target_in_global_arrow else .new_target_outside_function, self.tokens.items[new_start_token].pos);
            return self.alloc(.new_target_expr);
        }
        const parenthesized_callee = self.check(.lparen);
        var callee = if (parenthesized_callee) blk: {
            _ = self.advance();
            const expr = try self.parseExpression();
            try self.expect(.rparen);
            break :blk expr;
        } else try self.parsePrimary();
        // `new import(...)` is a SyntaxError: an ImportCall is a CallExpression,
        // not a valid MemberExpression operand for `new`. A parenthesized
        // ImportCall is a CoverParenthesizedExpression PrimaryExpression and is
        // therefore valid syntax (`new (import(x))`), failing later at runtime.
        // (`import.meta` parses to `.import_meta`, so `new import.meta.x()` is
        // unaffected.)
        if (!parenthesized_callee and callee.* == .import_call) return ParseError.UnexpectedToken;
        while (true) {
            if (self.match(.dot)) {
                // `new MemberExpression Arguments` includes private property
                // access; it has the same lexical-name gate as ordinary access.
                const name = try self.parseMemberName();
                callee = try self.alloc(.{ .member = .{ .object = callee, .property = name.text, .property_offset = name.offset, .source = self.sourceFrom(new_start_token) } });
            } else if (self.check(.question_dot)) {
                // `new o?.C()` / `new C?.()` is syntactically invalid; callers
                // must parenthesize the optional chain (`new (o?.C)()`).
                return ParseError.UnexpectedToken;
            } else if (self.match(.lbracket)) {
                const idx = try self.parseExpression();
                try self.expect(.rbracket);
                callee = try self.alloc(.{ .member = .{ .object = callee, .computed = idx, .source = self.sourceFrom(new_start_token) } });
            } else if (self.check(.template_no_substitution) or self.check(.template_head)) {
                // `new tag`tmpl`` parses as `new (tag`tmpl`)`: a tagged template is a
                // MemberExpression, so it binds to the `new` operand (the tag call
                // happens first, then `new` constructs its result).
                const tmpl = self.advance();
                callee = try self.parseTaggedTemplate(callee, tmpl, new_start_token);
            } else break;
        }
        const args: []*Node = if (self.check(.lparen)) try self.parseArgs() else &.{};
        return self.alloc(.{ .new_expr = .{ .callee = callee, .args = args, .source = self.sourceFrom(new_start_token) } });
    }

    /// Desugar a template literal's raw inner text into string concatenation:
    /// `` `a${x}b` `` becomes `("a" + x) + "b"`. The leading string makes the
    /// whole chain string-typed, so JS `+` applies ToString to each expression —
    /// exactly untagged-template semantics. Works on the tree-walker and the VM
    /// for free (it's just `add` nodes).
    /// Normalize template line terminators (the TRV rules): `<CR><LF>` and a
    /// lone `<CR>` both become a single `<LF>`. `<LS>`/`<PS>` are left as-is.
    fn normalizeTemplateRaw(arena: std.mem.Allocator, raw: []const u8) ParseError![]const u8 {
        const first_cr = std.mem.indexOfScalar(u8, raw, '\r') orelse return raw;

        // TRV changes CR to LF in place conceptually and removes only the LF
        // half of CRLF. Count those removals before allocating so the arena
        // retains exactly the normalized bytes, with no grow-and-transfer path.
        var normalized_len = raw.len;
        var cursor = first_cr;
        while (cursor < raw.len) {
            if (cursor + 1 < raw.len and raw[cursor + 1] == '\n') normalized_len -= 1;
            cursor = std.mem.indexOfScalarPos(u8, raw, cursor + 1, '\r') orelse raw.len;
        }

        const normalized = try arena.alloc(u8, normalized_len);
        var source_start: usize = 0;
        var output_start: usize = 0;
        cursor = first_cr;
        while (cursor < raw.len) {
            const span = raw[source_start..cursor];
            std.mem.copyForwards(u8, normalized[output_start .. output_start + span.len], span);
            output_start += span.len;
            normalized[output_start] = '\n';
            output_start += 1;
            source_start = cursor + 1;
            if (source_start < raw.len and raw[source_start] == '\n') source_start += 1;
            cursor = std.mem.indexOfScalarPos(u8, raw, source_start, '\r') orelse raw.len;
        }
        const suffix = raw[source_start..];
        std.mem.copyForwards(u8, normalized[output_start .. output_start + suffix.len], suffix);
        output_start += suffix.len;
        std.debug.assert(output_start == normalized.len);
        return normalized;
    }

    /// Cook one already-delimited quasi. Validation and sizing complete before
    /// the exact allocation, so untagged errors and tagged invalid escapes do
    /// not retain a partial cooked buffer.
    fn cookTemplateQuasi(self: *Parser, raw: []const u8, tagged: bool, source_raw: ?[]const u8) ParseError!?[]const u8 {
        var decoded = false;
        var multiple_escapes = false;
        var first_escape_start: usize = undefined;
        var first_escape: lex.DecodedEscape = undefined;
        var decoded_len: usize = 0;
        var cursor: usize = 0;
        var raw_start: usize = 0;
        while (cursor < raw.len) {
            if (raw[cursor] != '\\') {
                cursor += 1;
                continue;
            }
            if (cursor + 1 >= raw.len) {
                if (tagged) return null;
                return ParseError.UnexpectedToken;
            }
            if (templateEscapeDiagnostic(raw, cursor + 1)) |reason| {
                if (tagged) return null;
                if (source_raw) |original|
                    return self.failWithReasonAt(reason, self.templateEscapeSourceOffset(original, raw, cursor));
                return reason.parseError();
            }
            decoded_len += cursor - raw_start;
            const escape = lex.decodeEscape(raw, cursor + 1);
            if (!decoded) {
                first_escape_start = cursor;
                first_escape = escape;
            } else {
                multiple_escapes = true;
            }
            decoded = true;
            decoded_len += escape.len;
            cursor = escape.next;
            raw_start = cursor;
        }
        if (!decoded) return raw;

        decoded_len += raw.len - raw_start;
        const cooked = try self.arena.alloc(u8, decoded_len);
        var out: usize = 0;
        if (!multiple_escapes) {
            const prefix = raw[0..first_escape_start];
            std.mem.copyForwards(u8, cooked[out .. out + prefix.len], prefix);
            out += prefix.len;
            const bytes = first_escape.bytes[0..first_escape.len];
            std.mem.copyForwards(u8, cooked[out .. out + bytes.len], bytes);
            out += bytes.len;
            const suffix = raw[first_escape.next..];
            std.mem.copyForwards(u8, cooked[out .. out + suffix.len], suffix);
            out += suffix.len;
        } else {
            cursor = 0;
            while (cursor < raw.len) {
                const next_escape = std.mem.indexOfScalarPos(u8, raw, cursor, '\\') orelse raw.len;
                const span = raw[cursor..next_escape];
                std.mem.copyForwards(u8, cooked[out .. out + span.len], span);
                out += span.len;
                if (next_escape == raw.len) break;
                const escape = lex.decodeEscape(raw, next_escape + 1);
                const bytes = escape.bytes[0..escape.len];
                std.mem.copyForwards(u8, cooked[out .. out + bytes.len], bytes);
                out += bytes.len;
                cursor = escape.next;
            }
        }
        std.debug.assert(out == cooked.len);
        return cooked;
    }

    fn parseTemplate(self: *Parser, first: Token) ParseError!*Node {
        const first_raw = try normalizeTemplateRaw(self.arena, first.text);
        var node = try self.concatStr(null, (try self.cookTemplateQuasi(first_raw, false, first.text)).?);
        if (first.kind == .template_no_substitution) return node;
        std.debug.assert(first.kind == .template_head);

        while (true) {
            node = try self.concatExpr(node, try self.parseExpression());
            if (!self.check(.template_middle) and !self.check(.template_tail))
                return self.failWithTokenReason(.template_expression_tail);
            const quasi = self.advance();
            const raw = try normalizeTemplateRaw(self.arena, quasi.text);
            node = try self.concatStr(node, (try self.cookTemplateQuasi(raw, false, quasi.text)).?);
            if (quasi.kind == .template_tail) return node;
        }
    }

    /// Parse a tagged template from the same token stream as its surrounding
    /// expression. Temporary lists retain only pointers/slices and are released
    /// before return; final arrays own exact arena-sized storage.
    fn parseTaggedTemplate(self: *Parser, tag: *Node, first: Token, start_token: usize) ParseError!*Node {
        const first_raw = try normalizeTemplateRaw(self.arena, first.text);
        const first_cooked = try self.cookTemplateQuasi(first_raw, true, first.text);
        if (first.kind == .template_no_substitution) {
            const cooked = try self.arena.alloc(?[]const u8, 1);
            cooked[0] = first_cooked;
            const raws = try self.arena.alloc([]const u8, 1);
            raws[0] = first_raw;
            return self.alloc(.{ .tagged_template = .{
                .tag = tag,
                .cooked = cooked,
                .raw = raws,
                .exprs = &.{},
                .source = self.sourceFrom(start_token),
            } });
        }
        std.debug.assert(first.kind == .template_head);

        const Part = struct {
            cooked: ?[]const u8,
            raw: []const u8,
            expression_before: ?*Node,
        };
        var parts: std.ArrayListUnmanaged(Part) = .empty;
        defer parts.deinit(self.scratch_allocator);
        // One allocation covers the common case and all current representative
        // tagged-template rows. Larger sources grow geometrically without
        // rescanning their already parsed substitutions.
        try parts.ensureTotalCapacity(self.scratch_allocator, 8);
        parts.appendAssumeCapacity(.{ .cooked = first_cooked, .raw = first_raw, .expression_before = null });
        while (true) {
            const expression = try self.parseExpression();
            if (!self.check(.template_middle) and !self.check(.template_tail))
                return self.failWithTokenReason(.template_expression_tail);
            const quasi = self.advance();
            const raw = try normalizeTemplateRaw(self.arena, quasi.text);
            try parts.append(self.scratch_allocator, .{
                .cooked = try self.cookTemplateQuasi(raw, true, quasi.text),
                .raw = raw,
                .expression_before = expression,
            });
            if (quasi.kind == .template_tail) break;
        }

        const cooked = try self.arena.alloc(?[]const u8, parts.items.len);
        const raws = try self.arena.alloc([]const u8, parts.items.len);
        const exprs = try self.arena.alloc(*Node, parts.items.len - 1);
        for (parts.items, 0..) |part, index| {
            cooked[index] = part.cooked;
            raws[index] = part.raw;
            if (part.expression_before) |expression| exprs[index - 1] = expression;
        }
        return self.alloc(.{ .tagged_template = .{
            .tag = tag,
            .cooked = cooked,
            .raw = raws,
            .exprs = exprs,
            .source = self.sourceFrom(start_token),
        } });
    }

    /// Convert a cursor in the normalized TV/TRV byte sequence back to the
    /// original source. This only runs for a rejected untagged template; valid
    /// templates and accepted tagged invalid escapes do no location work.
    fn templateEscapeSourceOffset(self: *const Parser, original: []const u8, normalized: []const u8, normalized_offset: usize) usize {
        const base = self.sourceOffsetForSlice(original, 0);
        if (@intFromPtr(original.ptr) == @intFromPtr(normalized.ptr)) return base + normalized_offset;

        var source_cursor: usize = 0;
        var normalized_cursor: usize = 0;
        while (normalized_cursor < normalized_offset and source_cursor < original.len) {
            if (original[source_cursor] == '\r') {
                source_cursor += if (source_cursor + 1 < original.len and original[source_cursor + 1] == '\n') 2 else 1;
            } else {
                source_cursor += 1;
            }
            normalized_cursor += 1;
        }
        return base + source_cursor;
    }

    fn templateEscapeDiagnostic(raw: []const u8, i: usize) ?DiagnosticReason {
        if (lex.lineTerminatorLen(raw, i) != null or i >= raw.len) return null;
        switch (raw[i]) {
            'x' => {
                if (i + 2 >= raw.len or templateHexVal(raw[i + 1]) == null or templateHexVal(raw[i + 2]) == null)
                    return .malformed_template_hex_escape;
            },
            'u' => {
                if (i + 1 < raw.len and raw[i + 1] == '{') {
                    var j = i + 2;
                    var cp: u32 = 0;
                    var any = false;
                    while (j < raw.len and raw[j] != '}') : (j += 1) {
                        const h = templateHexVal(raw[j]) orelse return .malformed_template_unicode_escape;
                        cp = cp * 16 + h;
                        if (cp > 0x10FFFF) return .malformed_template_unicode_escape;
                        any = true;
                    }
                    if (!any or j >= raw.len or raw[j] != '}') return .malformed_template_unicode_escape;
                } else {
                    if (i + 4 >= raw.len) return .malformed_template_unicode_escape;
                    for (raw[i + 1 .. i + 5]) |c| if (templateHexVal(c) == null) return .malformed_template_unicode_escape;
                }
            },
            '0' => if (i + 1 < raw.len and std.ascii.isDigit(raw[i + 1])) return .template_numeric_escape,
            '1'...'9' => return .template_numeric_escape,
            else => {},
        }
        return null;
    }

    fn templateHexVal(c: u8) ?u32 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
    }

    fn concatStr(self: *Parser, node: ?*Node, bytes: []const u8) ParseError!*Node {
        // Template source and decoded buffers already share the parser arena
        // lifetime. Retain their exact slice instead of copying every quasi a
        // second time while building the concatenation AST.
        const s = try self.alloc(.{ .string = bytes });
        if (node) |n| return self.alloc(.{ .binary = .{ .op = .add, .left = n, .right = s } });
        return s;
    }

    fn concatExpr(self: *Parser, node: ?*Node, expr: *Node) ParseError!*Node {
        // A template substitution is ToString'd (string hint), not coerced via
        // `+` (default hint) — so `${ {valueOf,toString} }` uses toString.
        const coerced = try self.alloc(.{ .unary = .{ .op = .to_string, .operand = expr } });
        if (node) |n| return self.alloc(.{ .binary = .{ .op = .add, .left = n, .right = coerced } });
        return coerced;
    }

    /// A SuperCall (`super()`) is only legal in a derived class constructor, so
    /// one inside an object-literal method (concise method, getter, or setter) —
    /// in its body or a parameter default — is an early SyntaxError. A
    /// SuperProperty (`super.x`) and an `arguments` reference remain legal in a
    /// method, so only `super()` is rejected. Non-method property values
    /// (`{ m: function(){} }`, shorthands, spreads) have their own bindings and
    /// are not scanned.
    fn checkMethodNoSuperCall(self: *Parser, value: *Node) ParseError!void {
        if (value.* != .function or !value.function.is_method) return;
        const f = value.function;
        const saved_args = self.scan_allow_arguments;
        const saved_prop = self.scan_forbid_super_property;
        self.scan_allow_arguments = true; // `arguments` is legal in a method body
        self.scan_forbid_super_property = false; // `super.x` is legal in a method
        defer {
            self.scan_allow_arguments = saved_args;
            self.scan_forbid_super_property = saved_prop;
        }
        try self.scanSuperAndArgs(f.body);
        try self.scanSuperAndArgsInParams(f.params);
    }

    fn parseObjectLiteral(self: *Parser) ParseError!*Node {
        try self.expect(.lbrace);
        const saved_no_in = self.no_in; // object property values are `[+In]`
        self.no_in = false;
        defer self.no_in = saved_no_in;
        var has_cover_init = false;
        var seen_proto_colon = false;
        var duplicate_proto_offset: ?usize = null;
        var rest_comma_offset: ?usize = null;
        var props: std.ArrayListUnmanaged(ast.Property) = .empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            // Spread property `{ ...expr }`.
            if (self.match(.ellipsis)) {
                const e = try self.parseAssignment();
                try props.append(self.arena, .{ .value = e, .is_spread = true });
                if (!self.match(.comma)) break;
                if (rest_comma_offset == null)
                    rest_comma_offset = self.tokens.items[self.pos - 1].pos;
                continue;
            }
            // The first token of this member, so a method/accessor can capture its
            // exact source span for `Function.prototype.toString`.
            const member_start = self.pos;
            // Async method shorthand `{ async m() {} }` / `{ async *m() {} }`.
            const async_method = self.asyncMethodAhead();
            if (async_method) _ = self.advance(); // async
            // Generator method shorthand `{ *m() {} }` / `{ *[expr]() {} }`.
            const gen_method = self.match(.star);
            // Computed key: `{ [expr]: v }`.
            if (self.match(.lbracket)) {
                const key_expr = try self.parseAssignment();
                try self.expect(.rbracket);
                if (self.check(.lparen)) {
                    const fnode = try self.parseMethodTail("", gen_method, async_method, member_start, .none);
                    try props.append(self.arena, .{ .key_expr = key_expr, .value = fnode });
                } else {
                    try self.expect(.colon);
                    try props.append(self.arena, .{ .key_expr = key_expr, .value = try self.parseAssignment() });
                }
                if (!self.match(.comma)) break;
                continue;
            }
            // Accessor: `get x() {}` / `set x(v) {}` (get/set followed by a key).
            // An escaped `get`/`set` (`get`) is never the contextual keyword.
            if (!async_method and !gen_method and !self.cur().escaped_identifier and (isKeyword(self.cur(), "get") or isKeyword(self.cur(), "set")) and self.propNameAhead()) {
                const kind: ast.AccessorKind = if (isKeyword(self.cur(), "get")) .get else .set;
                _ = self.advance(); // get/set
                const property_token = self.cur();
                const pn = try self.parsePropertyName();
                // A private name (`#x`) is only a valid member name in a class
                // body, never in an object literal accessor (`({ get #x(){} })`).
                if (pn.key.len > 0 and pn.key[0] == '#') return self.failWithReasonAt(.private_accessor_outside_class, property_token.pos);
                const func = try self.parseMethodTail(pn.key, false, false, member_start, kind);
                try props.append(self.arena, .{ .key = pn.key, .key_expr = pn.expr, .value = func, .accessor = kind });
                if (!self.match(.comma)) break;
                continue;
            }
            const key_tok = self.advance();
            const key: []const u8 = switch (key_tok.kind) {
                .identifier, .string => key_tok.text,
                // A BigInt literal key (`1n`) is ToString'd from its exact value,
                // not the lossy f64.
                .number => if (key_tok.is_bigint)
                    (key_tok.bigint_text orelse try std.fmt.allocPrint(self.arena, "{d}", .{key_tok.bigint}))
                else
                    // A numeric LiteralPropertyName is ToString'd via Number::toString
                    // (so `0.0000001` keys as "1e-7", `1.0` as "1"), not Zig's `{d}`.
                    try value_mod.numberToString(self.arena, key_tok.number),
                else => return self.failWithToken(.expected_property_name, key_tok),
            };
            var val: *Node = undefined;
            var is_proto_colon = false;
            if (self.check(.lparen)) {
                // Method shorthand `{ m(args) { ... } }` -> a function value.
                val = try self.parseMethodTail(key, gen_method, async_method, member_start, .none);
            } else if (gen_method or async_method) {
                // A `*`/`async` modifier must introduce a method (a `(params){…}`
                // must follow the name): `({ *foo })`, `({ async async })` are
                // SyntaxErrors, not a property/shorthand named `foo`/`async`.
                return self.failWithTokenReason(.expected_method_parenthesis);
            } else if (self.match(.colon)) {
                // `__proto__: value` (identifier or string key, not computed) is a
                // prototype setter; two of them in one literal is an early error.
                if (std.mem.eql(u8, key, "__proto__")) {
                    if (seen_proto_colon and duplicate_proto_offset == null) duplicate_proto_offset = key_tok.pos;
                    seen_proto_colon = true;
                    is_proto_colon = true;
                }
                val = try self.parseAssignment();
                // The proto-setter form does NOT NamedEvaluate its value
                // (`{__proto__: function(){}}` leaves the function unnamed).
                if (!is_proto_colon) nameAnon(val, key); // `{ m: function(){} }` ⇒ name "m"
            } else if (key_tok.kind == .identifier) {
                if (isAlwaysReservedBinding(key) or (self.strict and isStrictReservedBinding(key)))
                    return self.failWithToken(.shorthand_keyword, key_tok);
                // A `{ yield }`/`{ await }` shorthand is an identifier reference/
                // binding, so `yield` is forbidden in a generator and `await` in
                // an async function/module/static block.
                if (self.in_generator and std.mem.eql(u8, key, "yield")) return self.failWithReasonAt(.yield_shorthand_generator, key_tok.pos);
                if ((self.in_async or self.module) and std.mem.eql(u8, key, "await")) return self.failWithReasonAt(.await_shorthand_async, key_tok.pos);
                self.recordArgumentsUse(key);
                const ident = try self.alloc(.{ .identifier = key });
                // Shorthand `{ a }`, or `{ a = default }` (a destructuring
                // default surfaced via the cover grammar).
                if (self.match(.assign)) {
                    // `{ a = default }` — a CoverInitializedName, valid only if
                    // this object is refined to an assignment pattern.
                    has_cover_init = true;
                    val = try self.alloc(.{ .assign = .{ .target = ident, .value = try self.parseAssignment() } });
                } else {
                    val = ident;
                }
            } else return self.failWithTokenReason(.expected_identifier_property_name);
            try props.append(self.arena, .{ .key = key, .value = val, .proto_setter = is_proto_colon });
            if (!self.match(.comma)) break;
        }
        try self.expect(.rbrace);
        for (props.items) |p| try self.checkMethodNoSuperCall(p.value);
        const node = try self.alloc(.{ .object_lit = props.items });
        if (has_cover_init) try self.pending_cover_inits.put(self.arena, self.secureHashState(), @intFromPtr(node), {});
        if (duplicate_proto_offset) |offset| try self.pending_proto_dup.put(self.arena, self.secureHashState(), @intFromPtr(node), offset);
        if (rest_comma_offset) |offset| try self.rest_comma_objects.put(self.arena, self.secureHashState(), @intFromPtr(node), offset);
        return node;
    }

    /// `super(args)` or `super.prop` / `super[expr]`. (`super.m(args)` is a
    /// super_member that the enclosing member-tail turns into a call.)
    fn parseSuper(self: *Parser) ParseError!*Node {
        const super_token = self.advance();
        if (self.check(.lparen)) {
            const call_offset = self.cur().pos;
            const args = try self.parseArgs();
            return self.alloc(.{ .super_call = .{ .args = args, .super_offset = super_token.pos, .call_offset = call_offset } });
        }
        if (self.match(.dot)) {
            const name = self.advance();
            if (name.kind != .identifier) return ParseError.UnexpectedToken;
            return self.alloc(.{ .super_member = .{ .property = name.text, .super_offset = super_token.pos } });
        }
        if (self.match(.lbracket)) {
            const idx = try self.parseExpression();
            try self.expect(.rbracket);
            return self.alloc(.{ .super_member = .{ .computed = idx, .super_offset = super_token.pos } });
        }
        return ParseError.UnexpectedToken;
    }

    /// `import(specifier ,opt)` / `import(specifier, options ,opt)` (dynamic
    /// import) or `import.meta`. The `import` keyword has already been peeked but
    /// not consumed.
    fn parseImportExpr(self: *Parser) ParseError!*Node {
        _ = self.advance(); // `import`
        // `import(spec, options)` arguments are `[+In]` (the `( … )` resets it).
        const saved_no_in = self.no_in;
        self.no_in = false;
        defer self.no_in = saved_no_in;
        var phase: []const u8 = "";
        if (self.match(.dot)) {
            const m = self.advance();
            if (m.kind != .identifier) return self.failWithToken(.import_call_arguments, m);
            // `import.meta` — meta-property. `import.source(x)` / `import.defer(x)`
            // — the source-phase-import / import-defer proposals; parse them as a
            // phased dynamic import (the phase doesn't change the AST here).
            // `import.meta` is only valid in Module code (a Script — including
            // eval, which is always Script goal — is a SyntaxError), and `meta`
            // may not be spelled with a Unicode escape.
            if (std.mem.eql(u8, m.text, "meta")) {
                if (m.escaped_identifier) return self.failWithToken(.import_meta_property, m);
                if (!self.module) return self.failWithReasonAt(.import_meta_module_only, m.pos);
                return self.alloc(.import_meta);
            }
            if (std.mem.eql(u8, m.text, "source") or std.mem.eql(u8, m.text, "defer")) {
                phase = m.text; // phased dynamic import; fall through to the call form
            } else return self.failWithToken(.import_meta_property, m);
        }
        try self.expectWithTokenReason(.lparen, .expected_import_call_parenthesis);
        // ImportCall requires exactly one AssignmentExpression specifier (no
        // empty `import()`, no leading spread), plus an optional second options
        // argument, plus an optional trailing comma.
        if (self.check(.rparen) or self.check(.ellipsis)) return self.failWithTokenReason(.unexpected_token);
        const spec = try self.parseAssignment();
        var options: ?*Node = null;
        if (self.match(.comma)) {
            if (!self.check(.rparen)) {
                if (self.check(.ellipsis)) return self.failWithTokenReason(.unexpected_token);
                options = try self.parseAssignment();
                _ = self.match(.comma); // optional trailing comma after 2nd arg
            }
        }
        try self.expect(.rparen);
        return self.alloc(.{ .import_call = .{ .specifier = spec, .options = options, .phase = phase } });
    }

    /// True when the next token starts a property name — used to tell an
    /// accessor (`get x`) from a method/property literally named `get`.
    fn propNameAhead(self: *Parser) bool {
        return switch (self.peekKind(1)) {
            // `private_name` lets `get #x()`/`set #x()` parse as accessors rather
            // than a method literally named `get`/`set`.
            .identifier, .string, .number, .lbracket, .private_name => true,
            else => false,
        };
    }

    /// Parse a property/method name: identifier/string/number, or a computed
    /// `[expr]`. Returns the static key (or "" if computed) and the computed expr.
    fn parsePropertyName(self: *Parser) ParseError!struct { key: []const u8, expr: ?*Node } {
        if (self.match(.lbracket)) {
            const e = try self.parseAssignment();
            try self.expect(.rbracket);
            return .{ .key = "", .expr = e };
        }
        const t = self.advance();
        const key: []const u8 = switch (t.kind) {
            .identifier, .string, .private_name => t.text,
            // A BigInt literal key (`1n`) is ToString'd from its exact value.
            .number => if (t.is_bigint)
                (t.bigint_text orelse try std.fmt.allocPrint(self.arena, "{d}", .{t.bigint}))
            else
                // ToString'd via Number::toString (`0.0000001` → "1e-7"), not `{d}`.
                try value_mod.numberToString(self.arena, t.number),
            else => return ParseError.UnexpectedToken,
        };
        return .{ .key = key, .expr = null };
    }

    /// `class [Name] { members }`. v1: constructor, instance methods, static
    /// methods, computed method names. `extends`/`super`/accessors are deferred
    /// (return a parse error, so such tests simply stay unparsed for now).
    /// Parse a leading decorator list `@dec @ns.x @call(args) @(expr)` and discard
    /// it (the syntax is accepted; decorator application is not implemented).
    fn parseDecorators(self: *Parser) ParseError!void {
        while (self.check(.at)) {
            _ = self.advance(); // @
            if (self.match(.lparen)) {
                _ = try self.parseExpression();
                try self.expect(.rparen);
            } else {
                if (!self.check(.identifier) and !self.check(.private_name)) return ParseError.UnexpectedToken;
                _ = self.advance(); // IdentifierReference
                while (self.check(.dot)) {
                    _ = self.advance();
                    if (!self.check(.identifier) and !self.check(.private_name)) return ParseError.UnexpectedToken;
                    _ = self.advance();
                }
                if (self.check(.lparen)) _ = try self.parseArgs(); // DecoratorCallExpression
            }
        }
    }

    fn parseClassExpr(self: *Parser) ParseError!*Node {
        // `class extends class extends …` nests through the heritage clause.
        try self.checkNesting();
        const start = self.pos;
        _ = self.advance(); // class
        // A class body (computed names, field initializers, method bodies) is
        // `[+In]`, even when the class expression appears in a for-init's `[~In]`.
        const saved_no_in = self.no_in;
        self.no_in = false;
        defer self.no_in = saved_no_in;
        // All parts of a class — its name, heritage, and body — are strict mode
        // code, so `class C extends (function(){ with({}); })() {}` is a
        // SyntaxError (a `with` in the heritage). Set strict before parsing them.
        const saved_strict = self.strict;
        self.strict = true;
        defer self.strict = saved_strict;
        var name: []const u8 = "";
        if (self.check(.identifier) and !isKeyword(self.cur(), "extends")) {
            // A class's BindingIdentifier is strict-mode code (`class let {}`,
            // `class yield {}`, `class await {}` in a module, … are SyntaxErrors);
            // `self.strict` is already forced true above.
            if (self.isForbiddenBindingName(self.cur().text)) return ParseError.UnexpectedToken;
            name = self.advance().text;
        }
        var superclass: ?*Node = null;
        if (isKeyword(self.cur(), "extends")) {
            _ = self.advance();
            // Superclass is a LeftHandSide expression (allow member/call chains).
            superclass = try self.parseUnary();
        }
        try self.expect(.lbrace);
        const saved_in_class = self.in_class;
        self.in_class = true;
        defer self.in_class = saved_in_class;
        var members: std.ArrayListUnmanaged(ast.ClassMember) = .empty;
        // Declaration offsets are needed only for early errors, not by the
        // runtime AST. Release this parallel inventory with parser scratch.
        var member_offsets: std.ArrayListUnmanaged(usize) = .empty;
        defer member_offsets.deinit(self.scratch_allocator);
        while (!self.check(.rbrace) and !self.check(.eof)) {
            if (self.match(.semicolon)) continue; // stray semicolons allowed
            // A class element may carry a leading decorator list (parsed and
            // discarded; decorators precede `static`).
            if (self.check(.at)) try self.parseDecorators();
            try member_offsets.append(self.scratch_allocator, self.cur().pos);
            var is_static = false;
            // An escaped `static` (`static`) is never the contextual keyword.
            if (isKeyword(self.cur(), "static") and !self.cur().escaped_identifier and self.peekKind(1) != .semicolon and self.peekKind(1) != .lparen and self.peekKind(1) != .assign) {
                is_static = true;
                _ = self.advance();
            }
            // `static { ... }` initialization block. It is its own scope with
            // `new.target` but no `yield`/`return`/`arguments`, and a SuperCall is
            // forbidden (SuperProperty is allowed). The body is [+Await], so
            // `await` is reserved (no `let await`, `class await {}`, `await;`) and
            // an AwaitExpression is the ContainsAwait early error.
            if (is_static and self.check(.lbrace)) {
                const saved_async = self.in_async;
                const saved_gen = self.in_generator;
                const saved_fn = self.fn_depth;
                const saved_iter = self.iter_depth;
                const saved_switch = self.switch_depth;
                // A static block is its own var scope (#933 item 8).
                const saved_for_body_vars = self.for_body_vars;
                self.for_body_vars = null;
                defer self.for_body_vars = saved_for_body_vars;
                const saved_labels = self.takeLabelContext();
                self.in_async = true; // [+Await]: `await` reserved in a static block
                self.in_generator = false;
                self.fn_depth = 0; // `return` is a SyntaxError in a static block
                // A static block is a fresh control-flow boundary: `break`/
                // `continue` may not target a loop/switch/label outside it.
                self.iter_depth = 0;
                self.switch_depth = 0;
                self.new_target_depth += 1;
                defer {
                    self.in_async = saved_async;
                    self.in_generator = saved_gen;
                    self.fn_depth = saved_fn;
                    self.iter_depth = saved_iter;
                    self.switch_depth = saved_switch;
                    self.restoreLabelContext(saved_labels);
                    self.new_target_depth -= 1;
                }
                const block = try self.parseBlock();
                // No super()/arguments, and no AwaitExpression (ContainsAwait).
                const saved_fa = self.scan_forbid_await;
                const saved_static_await = self.scan_static_block_await;
                self.scan_forbid_await = true;
                self.scan_static_block_await = true;
                defer {
                    self.scan_forbid_await = saved_fa;
                    self.scan_static_block_await = saved_static_await;
                }
                for (block.block) |s| try self.scanStatementListItem(s);
                // Own lexical scope, and its own var scope: nothing opened by the
                // enclosing class body's context is visible to a `var` in here.
                //
                // `funcs_lexical = false`: a ClassStaticBlockStatementList takes
                // its names from TopLevelLexicallyDeclaredNames and
                // TopLevelVarDeclaredNames, exactly as a FunctionBody does, so a
                // top-level function declaration here is VAR-scoped. Treating it
                // as lexical -- and, under the block's forced strictness, as rigid
                // -- rejected valid code (#929): `var f; function f(){}` and two
                // plain `function f(){}`. Functions in blocks NESTED inside the
                // static block are still lexical and still rigid.
                var lexical_scope = self.lexicalScope();
                defer lexical_scope.undo.deinit(self.scratch_allocator);
                try self.checkLexicalDupes(block.block, false, &lexical_scope);
                lexical_scope.assertBalanced();
                try members.append(self.arena, .{ .is_static = true, .static_block = block });
                continue;
            }
            // The method's source span for `Function.prototype.toString` starts at
            // its name/`get`/`set`/`async`/`*` — *after* any `static` (which is part
            // of the ClassElement, not the MethodDefinition's [[SourceText]]).
            const member_start = self.pos;
            // Async method: `async m() {}` / `static async m() {}` / `async *m() {}`.
            const async_method = self.asyncMethodAhead();
            if (async_method) _ = self.advance(); // async
            // Generator method: `*m() {}` / `static *m() {}` / `async *m() {}`.
            const gen_method = self.match(.star);
            // Accessor: `get x() {}` / `set x(v) {}`. An escaped `get`/`set`
            // (`get`) is never the contextual keyword.
            if (!async_method and !gen_method and !self.cur().escaped_identifier and (isKeyword(self.cur(), "get") or isKeyword(self.cur(), "set")) and self.propNameAhead()) {
                const kind: ast.AccessorKind = if (isKeyword(self.cur(), "get")) .get else .set;
                _ = self.advance(); // get/set
                const apn = try self.parsePropertyName();
                const func = try self.parseMethodTail(apn.key, false, false, member_start, kind);
                try members.append(self.arena, .{ .key = apn.key, .key_expr = apn.expr, .func = func, .is_static = is_static, .accessor = kind });
                continue;
            }
            // `accessor x` auto-accessor field (decorators proposal). `accessor`
            // is a contextual keyword only when an unescaped `accessor` is
            // followed, with no LineTerminator, by a property name — otherwise it
            // is itself the element name (`accessor;`, `accessor = 1`,
            // `accessor(){}`). Accepted and parsed as a field.
            const saw_auto_accessor = !async_method and !gen_method and isKeyword(self.cur(), "accessor") and
                !self.cur().escaped_identifier and self.noNewlineBefore(1) and self.propNameAhead();
            if (saw_auto_accessor) {
                _ = self.advance(); // accessor
            }
            const pn = try self.parsePropertyName();
            if (self.check(.lparen)) {
                // Method.
                const func = try self.parseMethodTail(pn.key, gen_method, async_method, member_start, .none);
                const is_ctor = !is_static and !gen_method and !async_method and pn.expr == null and std.mem.eql(u8, pn.key, "constructor");
                try members.append(self.arena, .{ .key = pn.key, .key_expr = pn.expr, .func = func, .is_static = is_static, .is_ctor = is_ctor });
            } else {
                // Field: `x;` or `x = init;`.
                const init_expr = if (self.match(.assign)) blk: {
                    // Field initializers do not inherit an enclosing async
                    // function's Await context; computed keys above still do.
                    const saved_async = self.in_async;
                    self.in_async = false;
                    defer self.in_async = saved_async;
                    break :blk try self.parseAssignment();
                } else null;
                // A FieldDefinition must be terminated by `;`, the closing `}`, or
                // ASI (a LineTerminator before the next element): `class C { x y }`
                // and `class C { #x #y }` are SyntaxErrors.
                if (!self.match(.semicolon) and !self.check(.rbrace) and self.noNewlineBefore(0))
                    return ParseError.UnexpectedToken;
                // Early error (15.7.1): a field Initializer may not contain a
                // SuperCall or an `arguments` reference.
                if (init_expr) |ie| {
                    const saved_field_diagnostic = self.scan_super_call_field_initializer;
                    self.scan_super_call_field_initializer = true;
                    defer self.scan_super_call_field_initializer = saved_field_diagnostic;
                    try self.scanSuperAndArgs(ie);
                }
                try members.append(self.arena, .{
                    .key = pn.key,
                    .key_expr = pn.expr,
                    .field_init = init_expr,
                    .is_static = is_static,
                    .is_field = true,
                    .is_auto_accessor = saw_auto_accessor and !(pn.expr == null and pn.key.len > 0 and pn.key[0] == '#'),
                });
            }
        }
        try self.expect(.rbrace);
        try self.checkPrivateNames(members.items, member_offsets.items);
        try self.checkClassMemberErrors(members.items, member_offsets.items, superclass != null);
        return self.alloc(.{ .class_expr = .{ .name = name, .superclass = superclass, .members = members.items, .source = self.sourceFrom(start) } });
    }

    /// Class element early errors (15.7.1) beyond private-name uniqueness:
    ///   - a SuperCall (`super()`) is allowed only in a derived class's
    ///     constructor; any other method/accessor/non-derived constructor body
    ///     containing one is a SyntaxError;
    ///   - a static element named `prototype` (non-computed, non-private) is a
    ///     SyntaxError;
    ///   - a `constructor` element that is an accessor, generator, or async
    ///     method is a SyntaxError (the constructor must be a plain method).
    fn checkClassMemberErrors(self: *Parser, members: []const ast.ClassMember, offsets: []const usize, has_superclass: bool) ParseError!void {
        // A class may define at most one constructor.
        var seen_ctor = false;
        for (members, offsets) |m, offset| if (m.is_ctor) {
            if (seen_ctor) return self.failWithReasonAt(.duplicate_constructor, offset);
            seen_ctor = true;
        };
        for (members, offsets) |m, offset| {
            const named = m.key_expr == null and m.key.len > 0;
            const not_private = named and m.key[0] != '#';
            if (m.is_static and not_private and std.mem.eql(u8, m.key, "prototype"))
                return self.failWithReasonAt(if (m.is_field) .static_prototype_field else .static_prototype_method, offset);
            // A field — instance or static — may not be named `constructor`
            // (15.7.1). A non-computed, non-private `constructor` field, however
            // its name is spelled (identifier or string literal), is an error.
            if (m.is_field and not_private and std.mem.eql(u8, m.key, "constructor"))
                return self.failWithReasonAt(.constructor_field, offset);
            if (m.is_field) continue;
            const mf = m.func orelse continue;
            if (mf.* != .function) continue;
            const fnode = mf.function;
            if (!m.is_static and not_private and std.mem.eql(u8, m.key, "constructor") and
                (m.accessor != .none or fnode.is_generator or fnode.is_async))
                return self.failWithReasonAt(if (m.accessor != .none) .constructor_accessor else if (fnode.is_async) .constructor_async else .constructor_generator, offset);
            // SuperCall is permitted only in the derived constructor.
            const is_derived_ctor = m.is_ctor and has_superclass;
            if (!is_derived_ctor) {
                const saved = self.scan_allow_arguments;
                self.scan_allow_arguments = true; // `arguments` is legal in a method body
                defer self.scan_allow_arguments = saved;
                try self.scanSuperAndArgs(fnode.body);
                try self.scanSuperAndArgsInParams(fnode.params);
            }
        }
    }

    /// Early error: a class may not declare the same private name twice, except
    /// for a single `get`/`set` pair at the same placement (both static or both
    /// instance). Any other repeat — get/get, set/set, method/method,
    /// field/anything, or a get+set split across static and instance — is a
    /// SyntaxError.
    fn checkPrivateNames(self: *Parser, members: []const ast.ClassMember, offsets: []const usize) ParseError!void {
        var private_count: usize = 0;
        for (members, offsets) |m, offset| {
            if (m.key_expr != null or m.key.len == 0 or m.key[0] != '#') continue;
            // A private name may not be `#constructor` (in any element form).
            if (std.mem.eql(u8, m.key, "#constructor"))
                return self.failWithReasonAt(if (m.is_field) .private_constructor_field else if (m.accessor != .none) .private_constructor_accessor else .private_constructor_method, offset);
            private_count += 1;
        }
        if (private_count < 2) return;

        // Sort transient member indexes by exact private-name bytes. This gives
        // attacker-controlled source a deterministic O(N log N) bound without
        // relying on predictable hash placement; the class member slice itself
        // stays in source order. Scratch backing is freeable on every exit.
        const private = try self.scratch_allocator.alloc(usize, private_count);
        defer self.scratch_allocator.free(private);
        var at: usize = 0;
        for (members, 0..) |m, index| {
            if (m.key_expr != null or m.key.len == 0 or m.key[0] != '#') continue;
            private[at] = index;
            at += 1;
        }
        std.mem.sort(usize, private, members, struct {
            fn lessThan(all: []const ast.ClassMember, left: usize, right: usize) bool {
                return switch (std.mem.order(u8, all[left].key, all[right].key)) {
                    .lt => true,
                    .gt => false,
                    .eq => left < right,
                };
            }
        }.lessThan);

        var group_start: usize = 0;
        while (group_start < private.len) {
            var group_end = group_start + 1;
            while (group_end < private.len and
                std.mem.eql(u8, members[private[group_start]].key, members[private[group_end]].key)) : (group_end += 1)
            {}
            const group_len = group_end - group_start;
            if (group_len > 1) {
                const previous = members[private[group_start]];
                const current = members[private[group_start + 1]];
                // A complementary get/set pair at the same placement is the only
                // allowed repeat.
                const pair = ((current.accessor == .get and previous.accessor == .set) or
                    (current.accessor == .set and previous.accessor == .get)) and
                    current.is_static == previous.is_static and !current.is_field and !previous.is_field;
                if (!pair) return self.failWithReasonAt(privateCollisionReason(previous, current), offsets[private[group_start + 1]]);
                if (group_len > 2) {
                    const third_index = private[group_start + 2];
                    // Both halves have already been declared. Any third use
                    // collides with an existing declaration of its own kind.
                    const third = members[third_index];
                    return self.failWithReasonAt(privateCollisionReason(third, third), offsets[third_index]);
                }
            }
            group_start = group_end;
        }
    }

    fn privateCollisionReason(previous: ast.ClassMember, current: ast.ClassMember) DiagnosticReason {
        if (current.is_field) return .duplicate_private_field;
        if (current.accessor == .none) return .duplicate_private_method;
        const complementary = (current.accessor == .get and previous.accessor == .set) or
            (current.accessor == .set and previous.accessor == .get);
        if (complementary and current.is_static != previous.is_static) {
            return if (current.is_static)
                if (current.accessor == .get) .static_getter_instance_setter else .static_setter_instance_getter
            else if (current.accessor == .get) .instance_getter_static_setter else .instance_setter_static_getter;
        }
        return .duplicate_private_accessor;
    }

    /// Whether the (eval) program's top-level declarations bind the name
    /// `arguments` — a `var` (hoisted out of nested blocks/control-flow, but not
    /// functions) or a top-level lexical / function / class declaration. Used to
    /// reject a direct eval that declares `arguments` inside a non-arrow
    /// function's parameter expression scope (an early error).
    pub fn evalDeclaresArguments(self: *Parser, stmts: []const *Node) ParseError!bool {
        var vars = self.secureStringMap(void);
        for (stmts) |s| try self.collectVarNames(s, &vars);
        if (vars.contains("arguments")) return true;
        // Top-level lexical / function / class named `arguments`.
        for (stmts) |s| switch (s.*) {
            .var_decl => |d| if (d.kind != .@"var" and std.mem.eql(u8, d.name, "arguments")) return true,
            .destructure_decl => |d| if (d.kind != .@"var") {
                var names: std.ArrayListUnmanaged([]const u8) = .empty;
                try self.addPatternNames(&names, d.pattern);
                for (names.items) |n| if (std.mem.eql(u8, n, "arguments")) return true;
            },
            .decl_group => |g| for (g) |d2| {
                if (d2.* == .var_decl and d2.var_decl.kind != .@"var" and std.mem.eql(u8, d2.var_decl.name, "arguments")) return true;
            },
            .func_decl => |f| if (std.mem.eql(u8, f.name, "arguments")) return true,
            .class_expr => |c| if (std.mem.eql(u8, c.name, "arguments")) return true,
            else => {},
        };
        return false;
    }

    /// Validate eval'd code against the syntactic restrictions it inherits:
    /// every top-level statement is scanned for a SuperCall (always forbidden in
    /// these eval contexts), plus an `arguments` reference (when
    /// `!allow_arguments`, e.g. a direct eval inside a class field initializer)
    /// and/or a SuperProperty (when `forbid_super_property`, e.g. an indirect
    /// eval, which is global code). Recurses into arrows and class heritage/
    /// computed names, but not ordinary functions or nested method bodies.
    /// Returns error.UnexpectedToken on a violation (the caller maps it to a
    /// SyntaxError *before* any of the eval'd code runs).
    pub fn scanEvalContext(self: *Parser, stmts: []const *Node, allow_arguments: bool, forbid_super_property: bool) ParseError!void {
        self.scan_allow_arguments = allow_arguments;
        self.scan_forbid_super_property = forbid_super_property;
        defer {
            self.scan_allow_arguments = false;
            self.scan_forbid_super_property = false;
        }
        for (stmts) |s| try self.scanSuperAndArgs(s);
    }

    /// Direct eval in a class field inherits the field initializer's
    /// SuperCall and `arguments` restrictions, including its diagnostic.
    pub fn scanEvalFieldContext(self: *Parser, stmts: []const *Node) ParseError!void {
        const saved_field_diagnostic = self.scan_super_call_field_initializer;
        self.scan_super_call_field_initializer = true;
        defer self.scan_super_call_field_initializer = saved_field_diagnostic;
        return self.scanEvalContext(stmts, false, false);
    }

    fn forbidYieldAwaitInParams(self: *Parser, params: []const ast.Param, forbid_yield: bool, forbid_await: bool) ParseError!void {
        const saved_args = self.scan_allow_arguments;
        const saved_call = self.scan_forbid_super_call;
        const saved_yield = self.scan_forbid_yield;
        const saved_await = self.scan_forbid_await;
        self.scan_allow_arguments = true;
        self.scan_forbid_super_call = false;
        self.scan_forbid_yield = forbid_yield;
        self.scan_forbid_await = forbid_await;
        defer {
            self.scan_allow_arguments = saved_args;
            self.scan_forbid_super_call = saved_call;
            self.scan_forbid_yield = saved_yield;
            self.scan_forbid_await = saved_await;
        }
        try self.scanSuperAndArgsInParams(params);
    }

    fn scanSuperAndArgsInParams(self: *Parser, params: []const ast.Param) ParseError!void {
        for (params) |param| {
            if (param.pattern) |pattern| try self.scanSuperAndArgsInPattern(pattern);
            if (param.default) |default| try self.scanSuperAndArgs(default);
        }
    }

    fn scanStatementListItem(self: *Parser, node: *Node) ParseError!void {
        if (!self.scan_static_block_await) return self.scanSuperAndArgs(node);
        const saved = self.scan_static_statement_list_item;
        self.scan_static_statement_list_item = true;
        defer self.scan_static_statement_list_item = saved;
        return self.scanSuperAndArgs(node);
    }

    /// ECMA-262 Contains/ContainsArguments descend into computed keys and
    /// initializers within patterns too. BindingIdentifier leaves are not
    /// IdentifierReferences; assignment member targets still evaluate their
    /// object/key expressions. Preserve the owning scan's function boundaries.
    fn scanSuperAndArgsInPattern(self: *Parser, pattern: *Node) ParseError!void {
        try self.checkNesting();
        switch (pattern.*) {
            .identifier => {},
            .obj_pattern => |p| {
                for (p.props) |prop| {
                    if (prop.key_expr) |key| try self.scanSuperAndArgs(key);
                    if (prop.default) |default| try self.scanSuperAndArgs(default);
                    try self.scanSuperAndArgsInPattern(prop.target);
                }
                if (p.rest) |rest| try self.scanSuperAndArgsInPattern(rest);
            },
            .arr_pattern => |p| {
                for (p.elems) |elem| {
                    if (elem.default) |default| try self.scanSuperAndArgs(default);
                    if (elem.target) |target| try self.scanSuperAndArgsInPattern(target);
                }
                if (p.rest) |rest| try self.scanSuperAndArgsInPattern(rest);
            },
            else => try self.scanSuperAndArgs(pattern),
        }
    }

    /// Scan an expression/statement subtree for a SuperCall (`super()`), and —
    /// unless `scan_allow_arguments` is set — an `arguments` reference. Used for
    /// two early errors: a class field Initializer may contain neither (15.7.1),
    /// and a method body other than a derived constructor may not contain a
    /// SuperCall. Each query follows its own function/class boundary: arrows
    /// inherit lexical bindings, class heritage/computed names use the outer
    /// context, and nested methods/initializers have their own super bindings.
    /// A left-deep chain scanned without recursing per link (#935); the visit
    /// order, and so the first error reported, matches the recursive form.
    noinline fn scanSuperAndArgsInChain(self: *Parser, top: *Node) ParseError!void {
        var spine: ast.ChainSpine(*Node) = .{};
        defer spine.deinit(self.scratch_allocator);
        try self.scanSuperAndArgs(try spine.collect(self.scratch_allocator, top));
        while (spine.pop()) |link| try self.scanSuperAndArgs(ast.chainRight(link));
    }

    fn scanSuperAndArgs(self: *Parser, node: *Node) ParseError!void {
        try self.checkNesting();
        const statement_list_item = self.scan_static_statement_list_item;
        self.scan_static_statement_list_item = false;
        defer self.scan_static_statement_list_item = statement_list_item;
        switch (node.*) {
            .obj_pattern, .arr_pattern => try self.scanSuperAndArgsInPattern(node),
            .identifier => |name| if (!self.scan_allow_arguments and std.mem.eql(u8, name, "arguments")) return ParseError.UnexpectedToken,
            .super_call => |call| {
                if (self.scan_forbid_super_call)
                    return self.failWithReasonAt(
                        if (self.scan_super_call_field_initializer) .super_call_field_initializer else .invalid_super,
                        if (self.scan_super_call_field_initializer) call.call_offset else call.super_offset,
                    );
                for (call.args) |arg| try self.scanSuperAndArgs(arg);
            },
            .unary => |u| try self.scanSuperAndArgs(u.operand),
            .delete_expr => |t| try self.scanSuperAndArgs(t),
            .update => |u| try self.scanSuperAndArgs(u.target),
            .await_expr => |a| {
                if (self.scan_forbid_await) return if (self.scan_static_block_await)
                    self.failWithReasonAt(.static_block_await_reference, a.offset)
                else
                    ParseError.UnexpectedToken;
                try self.scanSuperAndArgs(a.argument);
            },
            .yield_expr => |y| {
                if (self.scan_forbid_yield) return ParseError.UnexpectedToken;
                if (y.argument) |arg| try self.scanSuperAndArgs(arg);
            },
            .spread => |v| try self.scanSuperAndArgs(v),
            .optional_chain => |c| try self.scanSuperAndArgs(c),
            .binary, .logical, .sequence => try self.scanSuperAndArgsInChain(node),
            .assign => |a| {
                try self.scanSuperAndArgs(a.target);
                try self.scanSuperAndArgs(a.value);
            },
            .op_assign => |a| {
                try self.scanSuperAndArgs(a.target);
                try self.scanSuperAndArgs(a.value);
            },
            .logical_assign => |a| {
                try self.scanSuperAndArgs(a.target);
                try self.scanSuperAndArgs(a.value);
            },
            .conditional => |c| {
                try self.scanSuperAndArgs(c.cond);
                try self.scanSuperAndArgs(c.consequent);
                try self.scanSuperAndArgs(c.alternate);
            },
            .super_member => |m| {
                if (self.scan_forbid_super_property) return self.failWithReasonAt(.invalid_super, m.super_offset);
                if (m.computed) |computed| try self.scanSuperAndArgs(computed);
            },
            .call => |c| {
                try self.scanSuperAndArgs(c.callee);
                for (c.args) |arg| try self.scanSuperAndArgs(arg);
            },
            .new_expr => |n| {
                try self.scanSuperAndArgs(n.callee);
                for (n.args) |arg| try self.scanSuperAndArgs(arg);
            },
            .import_call => |i| {
                try self.scanSuperAndArgs(i.specifier);
                if (i.options) |options| try self.scanSuperAndArgs(options);
            },
            .tagged_template => |t| {
                try self.scanSuperAndArgs(t.tag);
                for (t.exprs) |expr| try self.scanSuperAndArgs(expr);
            },
            .member => |m| {
                try self.scanSuperAndArgs(m.object);
                if (m.computed) |computed| try self.scanSuperAndArgs(computed);
            },
            .object_lit => |props| for (props) |prop| {
                if (prop.key_expr) |key_expr| try self.scanSuperAndArgs(key_expr);
                try self.scanSuperAndArgs(prop.value);
            },
            .array_lit => |items| for (items) |item| try self.scanSuperAndArgs(item),
            // Arrow functions do NOT bind their own `arguments`/`super`, so a
            // `super()`/`arguments` inside one is still the field's — recurse into
            // arrow params' defaults and body. Ordinary functions have their own
            // bindings; class subexpressions use the separate boundary below.
            .function => |f| if (f.is_arrow) {
                // ECMA-262 8.5.1 Contains stops Await/Yield queries at the
                // entire arrow, while lexical SuperCall/SuperProperty queries
                // and 15.7.9 ContainsArguments cross both params and body.
                // Each arrow's own parameter early errors are checked during
                // parsing, independently of this enclosing query.
                if (self.scan_allow_arguments and !self.scan_forbid_super_call and !self.scan_forbid_super_property) return;
                const saved_await = self.scan_forbid_await;
                const saved_yield = self.scan_forbid_yield;
                self.scan_forbid_await = false;
                self.scan_forbid_yield = false;
                defer {
                    self.scan_forbid_await = saved_await;
                    self.scan_forbid_yield = saved_yield;
                }
                try self.scanSuperAndArgsInParams(f.params);
                try self.scanSuperAndArgs(f.body);
            },
            .class_expr => |c| {
                // ECMA-262 8.5.1 Contains and 8.5.2 ComputedPropertyContains:
                // heritage and computed names belong to the enclosing query,
                // even when the class's methods/initializers are boundaries.
                if (c.superclass) |sc| try self.scanSuperAndArgs(sc);
                for (c.members) |m| {
                    if (m.key_expr) |key_expr| try self.scanSuperAndArgs(key_expr);
                }
                if (self.scan_allow_arguments) return;
                // 15.7.9 ContainsArguments also visits fields and static blocks,
                // but must not carry the outer super/await/yield bans with it.
                const saved_call = self.scan_forbid_super_call;
                const saved_prop = self.scan_forbid_super_property;
                const saved_await = self.scan_forbid_await;
                const saved_yield = self.scan_forbid_yield;
                self.scan_forbid_super_call = false;
                self.scan_forbid_super_property = false;
                self.scan_forbid_await = false;
                self.scan_forbid_yield = false;
                defer {
                    self.scan_forbid_super_call = saved_call;
                    self.scan_forbid_super_property = saved_prop;
                    self.scan_forbid_await = saved_await;
                    self.scan_forbid_yield = saved_yield;
                }
                for (c.members) |m| {
                    if (m.field_init) |field_init| try self.scanSuperAndArgs(field_init);
                    if (m.static_block) |static_block| try self.scanSuperAndArgs(static_block);
                }
            },
            // Statement nodes (an arrow's block body):
            .block => |stmts| for (stmts) |s| try self.scanStatementListItem(s),
            .expr_stmt => |e| {
                if (self.scan_static_block_await and statement_list_item and e.* == .await_expr and !self.isParenWrapped(e))
                    return self.failWithReasonAt(.static_block_await_statement, e.await_expr.offset);
                try self.scanSuperAndArgs(e);
            },
            .return_stmt => |r| if (r) |v| try self.scanSuperAndArgs(v),
            .throw_stmt => |t| try self.scanSuperAndArgs(t),
            .var_decl => |d| {
                // ClassStaticBlock Contains `await` includes asynchronous
                // disposal, whose keyword is a flag rather than an expression.
                if (self.scan_forbid_await and d.dispose == 2) return if (self.scan_static_block_await)
                    self.failWithReasonAt(.static_block_await_statement, d.await_offset)
                else
                    ParseError.UnexpectedToken;
                if (d.init) |ini| try self.scanSuperAndArgs(ini);
            },
            .destructure_decl => |d| {
                try self.scanSuperAndArgsInPattern(d.pattern);
                try self.scanSuperAndArgs(d.init);
            },
            .decl_group => |g| for (g) |d2| try self.scanSuperAndArgs(d2),
            .if_stmt => |i| {
                try self.scanSuperAndArgs(i.cond);
                try self.scanSuperAndArgs(i.consequent);
                if (i.alternate) |a| try self.scanSuperAndArgs(a);
            },
            .while_stmt => |w| {
                try self.scanSuperAndArgs(w.cond);
                try self.scanSuperAndArgs(w.body);
            },
            .do_while_stmt => |w| {
                try self.scanSuperAndArgs(w.body);
                try self.scanSuperAndArgs(w.cond);
            },
            .for_stmt => |fo| {
                if (fo.init) |ini| try self.scanSuperAndArgs(ini);
                if (fo.cond) |c| try self.scanSuperAndArgs(c);
                if (fo.update) |u| try self.scanSuperAndArgs(u);
                try self.scanSuperAndArgs(fo.body);
            },
            .for_in => |fo| {
                if (self.scan_forbid_await and fo.is_await) return if (self.scan_static_block_await)
                    self.failWithReasonAt(.static_block_for_await, fo.await_offset)
                else
                    ParseError.UnexpectedToken;
                if (self.scan_forbid_await and fo.dispose == 2) return if (self.scan_static_block_await)
                    self.failWithReasonAt(.static_block_await_reference, fo.await_offset)
                else
                    ParseError.UnexpectedToken;
                try self.scanSuperAndArgsInPattern(fo.target);
                if (fo.var_init) |ini| try self.scanSuperAndArgs(ini);
                try self.scanSuperAndArgs(fo.iterable);
                try self.scanSuperAndArgs(fo.body);
            },
            .labeled_stmt => |l| try self.scanSuperAndArgs(l.body),
            .export_decl => |e| {
                if (e.declaration) |decl| try self.scanSuperAndArgs(decl);
                if (e.default_expr) |expr| try self.scanSuperAndArgs(expr);
            },
            .with_stmt => |w| {
                // Contains follows both children: a with environment does not
                // introduce a lexical super/arguments binding boundary.
                try self.scanSuperAndArgs(w.obj);
                try self.scanSuperAndArgs(w.body);
            },
            .try_stmt => |t| {
                try self.scanSuperAndArgs(t.block);
                if (t.catch_param) |param| try self.scanSuperAndArgsInPattern(param);
                if (t.catch_block) |c| try self.scanSuperAndArgs(c);
                if (t.finally_block) |fb| try self.scanSuperAndArgs(fb);
            },
            .switch_stmt => |sw| {
                try self.scanSuperAndArgs(sw.disc);
                for (sw.cases) |cs| {
                    if (cs.@"test") |t| try self.scanSuperAndArgs(t);
                    for (cs.body) |s| try self.scanSuperAndArgs(s);
                }
            },
            // .func_decl and leaf nodes: stop. Ordinary functions are lexical
            // boundaries; class children are handled explicitly above.
            else => {},
        }
    }

    fn isPrivateNameText(name: []const u8) bool {
        return name.len > 0 and name[0] == '#';
    }

    fn requirePrivateName(
        self: *Parser,
        declared: *SecureStringMapUnmanaged(void),
        name: []const u8,
        offset: usize,
    ) ParseError!void {
        if (isPrivateNameText(name) and !declared.contains(name)) {
            if (self.eval_private_names) |outer| if (outer.contains(name)) return;
            const err = self.failWithReasonAt(.undeclared_private_name, offset);
            self.last_error_token = .{ .kind = .token, .text = name };
            return err;
        }
    }

    fn checkPrivateUsesInPattern(
        self: *Parser,
        declared: *SecureStringMapUnmanaged(void),
        pattern: *Node,
    ) ParseError!void {
        try self.checkNesting();
        switch (pattern.*) {
            .obj_pattern => |p| for (p.props) |prop| {
                if (prop.key_expr) |key_expr| try self.checkPrivateUsesInNode(declared, key_expr);
                if (prop.default) |default| try self.checkPrivateUsesInNode(declared, default);
                try self.checkPrivateUsesInPattern(declared, prop.target);
            },
            .arr_pattern => |p| {
                for (p.elems) |elem| {
                    if (elem.target) |target| try self.checkPrivateUsesInPattern(declared, target);
                    if (elem.default) |default| try self.checkPrivateUsesInNode(declared, default);
                }
                if (p.rest) |rest| try self.checkPrivateUsesInPattern(declared, rest);
            },
            else => {},
        }
    }

    fn checkPrivateUsesInParams(
        self: *Parser,
        declared: *SecureStringMapUnmanaged(void),
        params: []const ast.Param,
    ) ParseError!void {
        for (params) |param| {
            if (param.pattern) |pattern| try self.checkPrivateUsesInPattern(declared, pattern);
            if (param.default) |default| try self.checkPrivateUsesInNode(declared, default);
        }
    }

    /// A left-deep chain checked without recursing per link (#935); the visit
    /// order, and so the first error reported, matches the recursive form.
    noinline fn checkPrivateUsesInChain(
        self: *Parser,
        declared: *SecureStringMapUnmanaged(void),
        top: *Node,
    ) ParseError!void {
        var spine: ast.ChainSpine(*Node) = .{};
        defer spine.deinit(self.scratch_allocator);
        try self.checkPrivateUsesInNode(declared, try spine.collect(self.scratch_allocator, top));
        while (spine.pop()) |link| try self.checkPrivateUsesInNode(declared, ast.chainRight(link));
    }

    fn checkPrivateUsesInNode(
        self: *Parser,
        declared: *SecureStringMapUnmanaged(void),
        node: *Node,
    ) ParseError!void {
        try self.checkNesting();
        switch (node.*) {
            .identifier => {},
            .private_identifier => |private| try self.requirePrivateName(declared, private.name, private.offset),
            .unary => |u| try self.checkPrivateUsesInNode(declared, u.operand),
            .delete_expr => |target| try self.checkPrivateUsesInNode(declared, target),
            .update => |u| try self.checkPrivateUsesInNode(declared, u.target),
            .binary, .logical, .sequence => try self.checkPrivateUsesInChain(declared, node),
            .assign => |a| {
                try self.checkPrivateUsesInNode(declared, a.target);
                try self.checkPrivateUsesInNode(declared, a.value);
            },
            .op_assign => |a| {
                try self.checkPrivateUsesInNode(declared, a.target);
                try self.checkPrivateUsesInNode(declared, a.value);
            },
            .logical_assign => |a| {
                // AllPrivateIdentifiersValid visits even the short-circuited
                // RHS; validation is static, not conditional on evaluation.
                try self.checkPrivateUsesInNode(declared, a.target);
                try self.checkPrivateUsesInNode(declared, a.value);
            },
            .conditional => |c| {
                try self.checkPrivateUsesInNode(declared, c.cond);
                try self.checkPrivateUsesInNode(declared, c.consequent);
                try self.checkPrivateUsesInNode(declared, c.alternate);
            },
            .function => |f| {
                try self.checkPrivateUsesInParams(declared, f.params);
                try self.checkPrivateUsesInNode(declared, f.body);
            },
            .yield_expr => |y| if (y.argument) |arg| try self.checkPrivateUsesInNode(declared, arg),
            .await_expr => |a| try self.checkPrivateUsesInNode(declared, a.argument),
            .super_call => |call| for (call.args) |arg| try self.checkPrivateUsesInNode(declared, arg),
            .super_member => |m| if (m.computed) |computed| try self.checkPrivateUsesInNode(declared, computed),
            .call => |c| {
                try self.checkPrivateUsesInNode(declared, c.callee);
                for (c.args) |arg| try self.checkPrivateUsesInNode(declared, arg);
            },
            .new_expr => |n| {
                try self.checkPrivateUsesInNode(declared, n.callee);
                for (n.args) |arg| try self.checkPrivateUsesInNode(declared, arg);
            },
            .tagged_template => |t| {
                try self.checkPrivateUsesInNode(declared, t.tag);
                for (t.exprs) |expr| try self.checkPrivateUsesInNode(declared, expr);
            },
            .member => |m| {
                try self.checkPrivateUsesInNode(declared, m.object);
                try self.requirePrivateName(declared, m.property, m.property_offset);
                if (m.computed) |computed| try self.checkPrivateUsesInNode(declared, computed);
            },
            .optional_chain => |chain| try self.checkPrivateUsesInNode(declared, chain),
            .object_lit => |props| for (props) |prop| {
                if (prop.key_expr) |key_expr| try self.checkPrivateUsesInNode(declared, key_expr);
                try self.checkPrivateUsesInNode(declared, prop.value);
            },
            .array_lit => |items| for (items) |item| try self.checkPrivateUsesInNode(declared, item),
            .spread => |value| try self.checkPrivateUsesInNode(declared, value),
            .obj_pattern, .arr_pattern => try self.checkPrivateUsesInPattern(declared, node),
            .var_decl => |d| if (d.init) |init_expr| try self.checkPrivateUsesInNode(declared, init_expr),
            .destructure_decl => |d| {
                try self.checkPrivateUsesInPattern(declared, d.pattern);
                try self.checkPrivateUsesInNode(declared, d.init);
            },
            .func_decl => |f| {
                try self.checkPrivateUsesInParams(declared, f.params);
                try self.checkPrivateUsesInNode(declared, f.body);
            },
            .return_stmt => |ret| if (ret) |value| try self.checkPrivateUsesInNode(declared, value),
            .throw_stmt => |value| try self.checkPrivateUsesInNode(declared, value),
            .try_stmt => |t| {
                try self.checkPrivateUsesInNode(declared, t.block);
                if (t.catch_param) |param| try self.checkPrivateUsesInPattern(declared, param);
                if (t.catch_block) |catch_block| try self.checkPrivateUsesInNode(declared, catch_block);
                if (t.finally_block) |finally_block| try self.checkPrivateUsesInNode(declared, finally_block);
            },
            .expr_stmt => |expr| try self.checkPrivateUsesInNode(declared, expr),
            .block => |stmts| for (stmts) |stmt| try self.checkPrivateUsesInNode(declared, stmt),
            .decl_group => |decls| for (decls) |decl| try self.checkPrivateUsesInNode(declared, decl),
            .if_stmt => |stmt| {
                try self.checkPrivateUsesInNode(declared, stmt.cond);
                try self.checkPrivateUsesInNode(declared, stmt.consequent);
                if (stmt.alternate) |alt| try self.checkPrivateUsesInNode(declared, alt);
            },
            .while_stmt => |stmt| {
                try self.checkPrivateUsesInNode(declared, stmt.cond);
                try self.checkPrivateUsesInNode(declared, stmt.body);
            },
            .do_while_stmt => |stmt| {
                try self.checkPrivateUsesInNode(declared, stmt.body);
                try self.checkPrivateUsesInNode(declared, stmt.cond);
            },
            .for_stmt => |stmt| {
                if (stmt.init) |init_node| try self.checkPrivateUsesInNode(declared, init_node);
                if (stmt.cond) |cond| try self.checkPrivateUsesInNode(declared, cond);
                if (stmt.update) |update| try self.checkPrivateUsesInNode(declared, update);
                try self.checkPrivateUsesInNode(declared, stmt.body);
            },
            .for_in => |stmt| {
                try self.checkPrivateUsesInNode(declared, stmt.target);
                if (stmt.var_init) |ini| try self.checkPrivateUsesInNode(declared, ini);
                try self.checkPrivateUsesInNode(declared, stmt.iterable);
                try self.checkPrivateUsesInNode(declared, stmt.body);
            },
            .switch_stmt => |stmt| {
                try self.checkPrivateUsesInNode(declared, stmt.disc);
                for (stmt.cases) |case| {
                    if (case.@"test") |case_test| try self.checkPrivateUsesInNode(declared, case_test);
                    for (case.body) |body| try self.checkPrivateUsesInNode(declared, body);
                }
            },
            .with_stmt => |stmt| {
                try self.checkPrivateUsesInNode(declared, stmt.obj);
                try self.checkPrivateUsesInNode(declared, stmt.body);
            },
            .labeled_stmt => |stmt| try self.checkPrivateUsesInNode(declared, stmt.body),
            .export_decl => |e| {
                if (e.declaration) |decl| try self.checkPrivateUsesInNode(declared, decl);
                if (e.default_expr) |expr| try self.checkPrivateUsesInNode(declared, expr);
            },
            .import_call => |i| {
                try self.checkPrivateUsesInNode(declared, i.specifier);
                if (i.options) |options| try self.checkPrivateUsesInNode(declared, options);
            },
            .class_expr => |c| {
                // The heritage (`extends <expr>`) is evaluated in the ENCLOSING
                // private environment, not the class's own — so a private name
                // there must already be in scope (`class C extends class { x =
                // this.#foo; } { #foo; }` is a SyntaxError). The members,
                // conversely, see the class's own private names too.
                if (c.superclass) |sc| try self.checkPrivateUsesInNode(declared, sc);
                try self.checkPrivateNameUses(declared, c.members);
            },
            else => {},
        }
    }

    fn checkPrivateUsesInProgram(self: *Parser, stmts: []const *Node) ParseError!void {
        var declared = self.secureStringMap(void);
        for (stmts) |stmt| try self.checkPrivateUsesInNode(&declared, stmt);
        // Each class extends this map in place and unwinds on the way out, so
        // anything left here is a scope that failed to roll back.
        std.debug.assert(declared.count() == 0);
    }

    fn checkPrivateNameUses(
        self: *Parser,
        declared: *SecureStringMapUnmanaged(void),
        members: []const ast.ClassMember,
    ) ParseError!void {
        // #926: extend the enclosing environment in place and unwind it, rather
        // than copying every inherited name into a fresh per-class map. The
        // copy made a linear source quadratic in time AND in retained arena
        // bytes -- N nested classes over N inherited names performed N*N
        // insertions that the arena never released. `requirePrivateName` only
        // ever asks `contains`, so an undo log is observationally identical to
        // the copy.
        //
        // Shadowing falls out of insert-if-absent for free: a name an ancestor
        // already declared is not inserted here, so it is not removed here
        // either, and it correctly outlives this class. Inserting
        // unconditionally would make an inner `#x` delete the outer one.
        var added: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (added.items) |name| _ = declared.remove(name);
            added.deinit(self.scratch_allocator);
        }
        // Counted first so the undo log is reserved to the exact number of
        // private declarations: reserving `members.len` charged every class an
        // allocation, including the common one that declares no private name
        // at all and therefore never records an undo.
        var private_declarations: usize = 0;
        for (members) |member| {
            if (member.key_expr == null and isPrivateNameText(member.key)) private_declarations += 1;
        }
        // Reserved before the first insertion so recording an insertion cannot
        // fail after the name is already visible: a half-recorded insertion
        // would leak the name to later siblings as a missing SyntaxError.
        if (private_declarations != 0)
            try added.ensureTotalCapacity(self.scratch_allocator, private_declarations);
        for (members) |member| {
            if (member.key_expr == null and isPrivateNameText(member.key)) {
                // A legal accessor pair declares the same name twice, so the
                // second `get`/`set` member must not record a second undo.
                const result = try declared.getOrPut(self.arena, member.key);
                if (!result.found_existing) {
                    result.value_ptr.* = {};
                    added.appendAssumeCapacity(member.key);
                }
            }
        }
        for (members) |member| {
            if (member.key_expr) |key_expr| try self.checkPrivateUsesInNode(declared, key_expr);
            if (member.func) |func| try self.checkPrivateUsesInNode(declared, func);
            if (member.field_init) |field_init| try self.checkPrivateUsesInNode(declared, field_init);
            if (member.static_block) |static_block| try self.checkPrivateUsesInNode(declared, static_block);
        }
    }

    /// Parse `(params) { body }` after a method name, returning a function node.
    /// `is_gen` marks a generator method (`*m() {}`).
    fn parseMethodTail(self: *Parser, name: []const u8, is_gen: bool, is_async: bool, start: usize, accessor: ast.AccessorKind) ParseError!*Node {
        var uses_arguments = false;
        var uses_direct_eval = false;
        var uses_direct_eval_in_parameters = false;
        var uses_direct_eval_in_body = false;
        const saved_arguments_use = self.current_arguments_use;
        const saved_direct_eval_use = self.current_direct_eval_use;
        self.current_arguments_use = &uses_arguments;
        self.current_direct_eval_use = &uses_direct_eval_in_parameters;
        defer {
            self.current_arguments_use = saved_arguments_use;
            self.current_direct_eval_use = saved_direct_eval_use;
        }
        const params = try self.parseFunctionParamListForAccessor(is_gen, is_async, accessor);
        self.current_direct_eval_use = &uses_direct_eval_in_body;
        try self.checkDuplicateParams(params); // method definitions forbid duplicate params in all modes
        const own_use_strict = self.peekUseStrict();
        const fn_strict = self.strict or own_use_strict; // captured before parseFnBody (see parseFunctionDecl)
        const body = try self.parseFnBody(is_gen, is_async);
        if (own_use_strict and hasNonSimpleParams(params)) return ParseError.UnexpectedToken;
        if (fn_strict) try self.validateStrictParams(params);
        try self.checkParamBodyConflict(params, body);
        uses_direct_eval = uses_direct_eval_in_parameters or uses_direct_eval_in_body;
        const fnode = try self.arena.create(ast.FunctionNode);
        fnode.* = .{ .name = name, .params = params, .body = body, .source = self.sourceFrom(start), .is_expr_body = false, .is_generator = is_gen, .is_async = is_async, .is_strict = fn_strict, .is_method = true, .uses_arguments = uses_arguments, .uses_direct_eval = uses_direct_eval, .uses_direct_eval_in_parameters = uses_direct_eval_in_parameters, .uses_direct_eval_in_body = uses_direct_eval_in_body };
        return self.alloc(.{ .function = fnode });
    }

    fn parseArrayLiteral(self: *Parser) ParseError!*Node {
        try self.expect(.lbracket);
        const saved_no_in = self.no_in; // array elements are `[+In]`
        self.no_in = false;
        defer self.no_in = saved_no_in;
        var elems: std.ArrayListUnmanaged(*Node) = .empty;
        var rest_comma_offset: ?usize = null;
        while (!self.check(.rbracket) and !self.check(.eof)) {
            // Elision / hole: a bare `,` yields an empty slot (v1: undefined, as
            // arrays are dense). `[ , x ]`, `[1, , 3]`, `[,]`.
            if (self.check(.comma)) {
                try elems.append(self.arena, try self.alloc(.elision));
                _ = self.advance();
                continue;
            }
            const el = try self.parseSpreadable();
            try elems.append(self.arena, el);
            if (!self.match(.comma)) break;
            // A comma after a spread is fine in a literal but invalid when the
            // cover grammar is refined to a rest element in a pattern.
            if (el.* == .spread and rest_comma_offset == null)
                rest_comma_offset = self.tokens.items[self.pos - 1].pos;
        }
        try self.expect(.rbracket);
        const node = try self.alloc(.{ .array_lit = elems.items });
        if (rest_comma_offset) |offset|
            try self.rest_comma_arrays.put(self.arena, self.secureHashState(), @intFromPtr(node), offset);
        return node;
    }

    fn parsePrimary(self: *Parser) ParseError!*Node {
        if (self.check(.identifier)) {
            if (self.isEscapedReservedWord(self.cur())) return ParseError.UnexpectedToken;
            const w = self.cur().text;
            if (std.mem.eql(u8, w, "function")) return self.parseFunctionExpr(false);
            // `async [no LineTerminator here] function` — a newline after `async`
            // breaks the async-function-expression form (`async` is then a plain
            // identifier reference).
            if (std.mem.eql(u8, w, "async") and !self.cur().escaped_identifier and self.peekIsKeyword(1, "function") and self.noNewlineBefore(1)) return self.parseFunctionExpr(true);
            if (std.mem.eql(u8, w, "new")) return self.parseNew();
            if (std.mem.eql(u8, w, "class")) return self.parseClassExpr();
            if (std.mem.eql(u8, w, "super")) return self.parseSuper();
            if (std.mem.eql(u8, w, "import")) return self.parseImportExpr();
        }
        // A decorated class expression: `@dec class {…}`.
        if (self.check(.at)) {
            try self.parseDecorators();
            return self.parseClassExpr();
        }
        if (self.check(.regex) or self.check(.slash) or self.check(.slash_eq)) return self.parseRegexLiteralFromSlash();
        if (self.check(.lbrace)) return self.parseObjectLiteral();
        if (self.check(.lbracket)) return self.parseArrayLiteral();
        const t = self.advance();
        switch (t.kind) {
            .number => {
                // Legacy octal / non-octal-decimal literals are SyntaxErrors in strict mode.
                if (self.strict and t.legacy_octal) return ParseError.UnexpectedToken;
                if (t.is_bigint) return self.alloc(.{ .bigint_lit = .{ .value = t.bigint, .text = t.bigint_text } });
                return self.alloc(.{ .number = t.number });
            },
            .string => {
                // A string with a legacy octal / non-octal-decimal escape is a
                // SyntaxError in strict mode.
                if (self.strict and t.legacy_octal) return ParseError.UnexpectedToken;
                return self.alloc(.{ .string = t.text });
            },
            .template_no_substitution, .template_head => return self.parseTemplate(t),
            .regex => {
                // A regex literal's pattern and flags are early errors: validate
                // them at parse time so an invalid literal fails the parse (the
                // `phase: parse` negative tests rely on this), matching the same
                // compile the interpreter runs eagerly at evaluation.
                try self.validateRegexLiteral(t.text, t.flags, t.pos);
                return self.alloc(.{ .regex_literal = .{ .pattern = t.text, .flags = t.flags } });
            },
            .lparen => {
                const saved_no_in = self.no_in; // a parenthesized expr is `[+In]`
                self.no_in = false;
                const e = try self.parseExpression();
                self.no_in = saved_no_in;
                try self.expect(.rparen);
                // Record the parenthesization: a parenthesized array/object
                // literal is not a valid destructuring assignment target
                // (`({}) = 1`), even though a parenthesized identifier/member is.
                try self.markParenWrapped(e);
                self.paren_assign_target_name = if (self.check(.assign) and e.* == .identifier) e.identifier else null;
                return e;
            },
            .identifier => {
                if (std.mem.eql(u8, t.text, "true")) return self.alloc(.{ .boolean = true });
                if (std.mem.eql(u8, t.text, "false")) return self.alloc(.{ .boolean = false });
                if (std.mem.eql(u8, t.text, "null")) return self.alloc(.null_lit);
                if (std.mem.eql(u8, t.text, "this")) return self.alloc(.this_expr);
                if (isAlwaysReservedBinding(t.text) or (self.strict and isStrictReservedBinding(t.text))) return self.failWithToken(.unexpected_token, t);
                // `yield`/`await` are reserved words in their contexts, so neither
                // may appear here as an IdentifierReference — `void yield` inside a
                // generator, `void await` inside an async function/module — even
                // though a YieldExpression/AwaitExpression (handled higher up) is
                // fine. (Outside those contexts they are ordinary identifiers.)
                if (self.in_generator and std.mem.eql(u8, t.text, "yield")) return self.failWithToken(.unexpected_token, t);
                if ((self.in_async or self.module) and std.mem.eql(u8, t.text, "await")) return self.failWithToken(.unexpected_token, t);
                self.recordArgumentsUse(t.text);
                return self.alloc(.{ .identifier = t.text });
            },
            else => return self.failWithToken(.unexpected_token, t),
        }
    }
};

/// Validate a regex literal's flags and pattern, returning a parse error for an
/// invalid one. Mirrors the interpreter's eager compile so the result is the
/// same whether the literal is rejected at parse or at evaluation.
fn validateRegexLiteralWithArena(validation_arena: *std.heap.ArenaAllocator, pattern: []const u8, flags: []const u8, diagnostic: *?regex.CompileErrorReason) ParseError!void {
    _ = validation_arena.reset(.retain_capacity);
    defer _ = validation_arena.reset(.retain_capacity);
    _ = try compileRegexLiteralForValidation(validation_arena.allocator(), pattern, flags, diagnostic);
}

fn compileRegexLiteralForValidation(scratch_allocator: std.mem.Allocator, pattern: []const u8, flags: []const u8, diagnostic: *?regex.CompileErrorReason) ParseError!regex.Regex {
    var seen = std.mem.zeroes([128]bool);
    for (flags) |f| {
        if (f >= 128 or std.mem.indexOfScalar(u8, "dgimsuvy", f) == null or seen[f]) return ParseError.UnexpectedToken;
        seen[f] = true;
    }
    if (seen['u'] and seen['v']) return ParseError.UnexpectedToken;
    const cf = regex.common.CompileFlags{
        .case_insensitive = seen['i'],
        .multiline = seen['m'],
        .dot_all = seen['s'],
        .unicode = seen['u'] or seen['v'],
        .unicode_sets = seen['v'],
        .ecmascript = true,
    };
    const normalized = if (cf.unicode)
        regexp_compat.NormalizedPattern.borrowed(pattern)
    else
        try regexp_compat.normalizeAnnexBClassRanges(scratch_allocator, pattern);
    defer normalized.deinit(scratch_allocator);
    return regex.Regex.compileWithFlagsDiagnostic(scratch_allocator, normalized.bytes, cf, diagnostic) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ParseError.UnexpectedToken,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parser source locations map byte offsets to one-based line columns" {
    const src = "alpha\r\nbeta\u{2028}gamma";
    try std.testing.expectEqual(SourceLocation{ .byte_offset = 0, .line = 1, .column = 1 }, sourceLocationAt(src, 0));
    try std.testing.expectEqual(SourceLocation{ .byte_offset = 7, .line = 2, .column = 1 }, sourceLocationAt(src, 7));
    try std.testing.expectEqual(SourceLocation{ .byte_offset = 14, .line = 3, .column = 1 }, sourceLocationAt(src, 14));
    try std.testing.expectEqual(SourceLocation{ .byte_offset = src.len, .line = 3, .column = 6 }, sourceLocationAt(src, src.len + 99));
}

test "parser binding keyword table preserves exact reserved memberships" {
    @setEvalBranchQuota(10_000);
    var always_count: usize = 0;
    var grammar_count: usize = 0;
    var strict_count: usize = 0;
    inline for (binding_keyword_entries, 0..) |entry, index| {
        const key = entry.@"0";
        const expected = entry.@"1";
        try std.testing.expectEqual(expected, bindingKeywordClass(key));
        always_count += @intFromBool(expected.always_reserved);
        grammar_count += @intFromBool(expected.grammar_reserved);
        strict_count += @intFromBool(expected.strict_reserved);
        inline for (binding_keyword_entries, 0..) |other, other_index|
            if (index < other_index)
                try std.testing.expect(!std.mem.eql(u8, key, other.@"0"));
    }
    try std.testing.expectEqual(@as(usize, 36), always_count);
    try std.testing.expectEqual(@as(usize, 36), grammar_count);
    try std.testing.expectEqual(@as(usize, 9), strict_count);

    try std.testing.expectEqual(always_only, bindingKeywordClass("debugger"));
    try std.testing.expectEqual(always_only, bindingKeywordClass("with"));
    try std.testing.expectEqual(grammar_and_strict, bindingKeywordClass("let"));
    try std.testing.expectEqual(grammar_and_strict, bindingKeywordClass("yield"));
    for ([_][]const u8{ "await", "async", "eval", "arguments", "get", "set", "of", "undefined", "parameter4096", "πparameter" }) |ordinary|
        try std.testing.expectEqual(BindingKeywordClass{}, bindingKeywordClass(ordinary));
}

test "parser advances statement locations across every line terminator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "first;\r\n/*x*/ second;\rthird;\xe2\x80\xa8fourth;\xe2\x80\xa9fifth;";
    var parser = try Parser.init(arena.allocator(), source);
    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 5), program.program.len);
    try std.testing.expectEqual(@as(usize, 5), parser.statement_locations.items.len);
    for ([_][]const u8{ "first", "second", "third", "fourth", "fifth" }, parser.statement_locations.items) |name, location| {
        const offset = std.mem.indexOf(u8, source, name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(sourceLocationAt(source, offset), location.location);
    }
    try std.testing.expectEqual(parser.statement_locations.items[4].location, parser.statement_location_cursor);

    var single = try Parser.init(arena.allocator(), "var one = [1, 2, 3];");
    _ = try single.parseProgram();
    try std.testing.expectEqual(SourceLocation{ .byte_offset = 0, .line = 1, .column = 1 }, single.statement_location_cursor);
}

test "parser statement registry excludes expressions and synthetic program roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(),
        \\let value = 1;
        \\if (value) { value = 2; } else value = 3;
        \\while (false) value++;
        \\for (let index = 0; index < 1; index++) { continue; }
        \\try { throw value; } catch (error) { debugger; }
    );
    const program = try parser.parseProgram();
    try std.testing.expect(!canPublishStatementLocation(program));
    for (parser.statement_locations.items) |entry|
        try std.testing.expect(canPublishStatementLocation(entry.node));

    var expression = Node{ .number = 1 };
    try std.testing.expect(!canPublishStatementLocation(&expression));
}

test "parser rejects a non-monotonic statement location entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "first;\nsecond;");
    try std.testing.expectEqual(SourceLocation{ .byte_offset = 7, .line = 2, .column = 1 }, try parser.statementLocationAt(7));
    try std.testing.expectError(ParseError.UnexpectedToken, parser.statementLocationAt(0));
}

test "parser allocates parameter body conflict indexes only for direct lexical declarations" {
    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    var parser: Parser = undefined;
    parser.arena = fixed.allocator();
    parser.secure_hash_state = .{};
    parser.shared_secure_hash_state = null;
    const params = [_]ast.Param{.{ .name = "value" }};

    var empty_body = Node{ .block = &.{} };
    try parser.checkParamBodyConflict(&params, &empty_body);

    var nested_decl = Node{ .var_decl = .{ .kind = .let, .name = "value", .init = null } };
    var nested_items = [_]*Node{&nested_decl};
    var nested_block = Node{ .block = &nested_items };
    var outer_items = [_]*Node{&nested_block};
    var nested_body = Node{ .block = &outer_items };
    try parser.checkParamBodyConflict(&params, &nested_body);

    var direct_items = [_]*Node{&nested_decl};
    var direct_body = Node{ .block = &direct_items };
    try std.testing.expectError(error.OutOfMemory, parser.checkParamBodyConflict(&params, &direct_body));
}

test "parser preserves every direct parameter body conflict shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rejected = [_][]const u8{
        "function ordinary(value) { let value; }",
        "async function asynchronous(value) { const value = 1; }",
        "function* generator(value) { class value {} }",
        "function destructured(value) { let [value] = []; }",
        "function grouped(value) { let other = 0, value = 1; }",
        "(value) => { let value; };",
        "({ method(value) { const value = 1; } });",
    };
    for (rejected) |source| {
        var parser = try Parser.init(arena.allocator(), source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    }

    var nested = try Parser.init(arena.allocator(), "function nested(value) { var value; { let value; } if (true) { const value = 1; } return value; }");
    _ = try nested.parseProgram();
}

test "parser retains binding and parameter conflict diagnostics" {
    const Case = struct {
        source: []const u8,
        reason: DiagnosticReason,
        marker: []const u8,
        message: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "function f(a) { let a; }", .reason = .duplicate_let_binding, .marker = "a", .message = "Cannot declare a let variable twice: 'a'." },
        .{ .source = "function f({a}) { const a = 1; }", .reason = .duplicate_const_binding, .marker = "a", .message = "Cannot declare a const variable twice: 'a'." },
        .{ .source = "function f(a) { const a = 1, b = 2; }", .reason = .duplicate_const_binding, .marker = "a", .message = "Cannot declare a const variable twice: 'a'." },
        .{ .source = "function f(a) { class a {} }", .reason = .duplicate_class_binding, .marker = "a", .message = "Cannot declare a class twice: 'a'." },
        .{ .source = "(a) => { let a; }", .reason = .duplicate_let_binding, .marker = "a", .message = "Cannot declare a let variable twice: 'a'." },
        .{ .source = "try {} catch ([e, e]) {}", .reason = .duplicate_catch_binding, .marker = "e", .message = "Unexpected identifier 'e'. Cannot declare a lexical variable twice: 'e'." },
        .{ .source = "try {} catch (e) { let e; }", .reason = .duplicate_let_binding, .marker = "e", .message = "Cannot declare a let variable twice: 'e'." },
        .{ .source = "try {} catch ({e}) { const {e} = {}; }", .reason = .duplicate_catch_destructuring, .marker = "e", .message = "Unexpected token '}'. Cannot declare a lexical variable twice: 'e'." },
        .{ .source = "try {} catch (e) { const e = 1, x = 2; }", .reason = .duplicate_const_binding, .marker = "e", .message = "Cannot declare a const variable twice: 'e'." },
        .{ .source = "try {} catch (e) { function e() {} }", .reason = .catch_function_shadow, .marker = "e", .message = "Cannot declare a function that shadows a let/const/class/function variable 'e'." },
        .{ .source = "try {} catch (e) { label: function e() {} }", .reason = .catch_function_shadow, .marker = "e", .message = "Cannot declare a function that shadows a let/const/class/function variable 'e'." },
        .{ .source = "try {} catch (e) { class e {} }", .reason = .duplicate_class_binding, .marker = "e", .message = "Cannot declare a class twice: 'e'." },
        .{ .source = "function f(eval) { \"use strict\"; }", .reason = .invalid_strict_parameters, .marker = "eval", .message = "Invalid parameters or function name in strict mode." },
        .{ .source = "function f(interface) { \"use strict\"; }", .reason = .invalid_strict_parameters, .marker = "interface", .message = "Invalid parameters or function name in strict mode." },
        .{ .source = "function f(a, a) { \"use strict\"; }", .reason = .invalid_strict_parameters, .marker = "a", .message = "Invalid parameters or function name in strict mode." },
        .{ .source = "function () {}", .reason = .function_name_required, .marker = "(", .message = "Function statements must have a name." },
        .{ .source = "function if() {}", .reason = .function_keyword_name, .marker = "if", .message = "Cannot use the keyword 'if' as a function name." },
        .{ .source = "function f(a = 1) { \"use strict\"; }", .reason = .strict_directive_non_simple_parameters, .marker = "\"use strict\"", .message = "'use strict' directive not allowed inside a function with a non-simple parameter list." },
        .{ .source = "\"use strict\"; function eval() {}", .reason = .strict_function_name, .marker = "eval", .message = "'eval' is not a valid function name in strict mode." },
        .{ .source = "function arguments() { \"use strict\"; }", .reason = .strict_function_name, .marker = "arguments", .message = "'arguments' is not a valid function name in strict mode." },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), case.source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
        try std.testing.expectEqual(case.reason, parser.last_error_reason.?);
        try std.testing.expectEqual(std.mem.lastIndexOf(u8, case.source, case.marker).?, parser.errorLocation().byte_offset);
        try std.testing.expectEqualStrings(case.message, try parser.diagnosticMessage(arena.allocator(), case.reason));
    }
}

test "parser retains object and destructuring pattern diagnostics" {
    const Case = struct {
        source: []const u8,
        reason: DiagnosticReason,
        marker: []const u8,
        message: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "([a]) = [];", .reason = .invalid_assignment, .marker = "(", .message = "Left side of assignment is not a reference." },
        .{ .source = "[...a,] = [];", .reason = .array_rest_pattern_closing, .marker = ",", .message = "Unexpected token ','. Expected a closing ']' following a rest element destructuring pattern." },
        .{ .source = "[...a, b] = [];", .reason = .array_rest_pattern_closing, .marker = ",", .message = "Unexpected token ','. Expected a closing ']' following a rest element destructuring pattern." },
        .{ .source = "[(a = 1)] = [];", .reason = .invalid_destructuring_assignment, .marker = "[", .message = "Invalid destructuring assignment target." },
        .{ .source = "({...a, b} = {});", .reason = .object_rest_pattern_comma, .marker = ",", .message = "Unexpected token ','. Cannot parse assignment pattern." },
        .{ .source = "({...a,} = {});", .reason = .object_rest_pattern_comma, .marker = ",", .message = "Unexpected token ','. Cannot parse assignment pattern." },
        .{ .source = "({...(a + b)} = {});", .reason = .invalid_destructuring_assignment, .marker = "{", .message = "Invalid destructuring assignment target." },
        .{ .source = "\"use strict\"; ({...eval} = {});", .reason = .strict_modify_eval, .marker = "eval", .message = "Unexpected token '}'. Cannot modify 'eval' in strict mode." },
        .{ .source = "({a: (b = 1)} = {});", .reason = .invalid_destructuring_assignment, .marker = "{", .message = "Invalid destructuring assignment target." },
        .{ .source = "let {...1} = {};", .reason = .expected_binding_element, .marker = "1", .message = "Unexpected number '1'. Expected a binding element." },
        .{ .source = "let {+} = {};", .reason = .expected_property_name, .marker = "+", .message = "Unexpected token '+'. Expected a property name." },
        .{ .source = "let {\"x\"} = {};", .reason = .expected_named_destructuring_colon, .marker = "}", .message = "Unexpected token '}'. Expected a ':' prior to a named destructuring property." },
        .{ .source = "let {break} = {};", .reason = .abbreviated_destructuring_keyword, .marker = "break", .message = "Cannot use abbreviated destructuring syntax for keyword 'break'." },
        .{ .source = "let {...break} = {};", .reason = .lexical_keyword_binding, .marker = "break", .message = "Cannot use the keyword 'break' as a lexical variable name." },
        .{ .source = "\"use strict\"; let {...eval} = {};", .reason = .strict_destructure_binding, .marker = "eval", .message = "Cannot destructure to a variable named 'eval' in strict mode." },
        .{ .source = "({ get #x() {} });", .reason = .private_accessor_outside_class, .marker = "#x", .message = "Cannot declare a private setter or getter outside a class." },
        .{ .source = "({ + });", .reason = .expected_property_name, .marker = "+", .message = "Unexpected token '+'. Expected a property name." },
        .{ .source = "({ *foo });", .reason = .expected_method_parenthesis, .marker = "}", .message = "Unexpected token '}'. Expected a parenthesis for argument list." },
        .{ .source = "({ async foo });", .reason = .expected_method_parenthesis, .marker = "}", .message = "Unexpected token '}'. Expected a parenthesis for argument list." },
        .{ .source = "({ break });", .reason = .shorthand_keyword, .marker = "break", .message = "Cannot use the keyword 'break' as a shorthand property name." },
        .{ .source = "function* g() { return { yield }; }", .reason = .yield_shorthand_generator, .marker = "yield", .message = "Cannot use 'yield' as a shorthand property name in a generator function." },
        .{ .source = "async function f() { return { await }; }", .reason = .await_shorthand_async, .marker = "await", .message = "Cannot use 'await' as a shorthand property name in an async function." },
        .{ .source = "({ \"x\" });", .reason = .expected_identifier_property_name, .marker = "}", .message = "Unexpected token '}'. Expected an identifier as property name." },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), case.source);
        try std.testing.expectError(case.reason.parseError(), parser.parseProgram());
        try std.testing.expectEqual(case.reason, parser.last_error_reason.?);
        try std.testing.expectEqual(std.mem.indexOf(u8, case.source, case.marker).?, parser.errorLocation().byte_offset);
        try std.testing.expectEqualStrings(case.message, try parser.diagnosticMessage(arena.allocator(), case.reason));
    }
}

test "parser retains static and dynamic import diagnostics" {
    const Case = struct {
        source: []const u8,
        module: bool = false,
        reason: DiagnosticReason,
        marker: []const u8,
        message: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "import.1", .reason = .expected_import_call_parenthesis, .marker = ".1", .message = "Unexpected number '.1'. import call expects one or two arguments." },
        .{ .source = "import.meta", .reason = .import_meta_module_only, .marker = "meta", .message = "import.meta is only valid inside modules." },
        .{ .source = "import.\\u006deta", .reason = .import_meta_property, .marker = "\\u006deta", .message = "Unexpected identifier '\\u006deta'. \"import.\" can only be followed with meta." },
        .{ .source = "import.foo('x')", .reason = .import_meta_property, .marker = "foo", .message = "Unexpected identifier 'foo'. \"import.\" can only be followed with meta." },
        .{ .source = "import()", .reason = .unexpected_token, .marker = ")", .message = "Unexpected token ')'" },
        .{ .source = "import(...x)", .reason = .unexpected_token, .marker = "...", .message = "Unexpected token '...'" },
        .{ .source = "import('x', ...y)", .reason = .unexpected_token, .marker = "...", .message = "Unexpected token '...'" },
        .{ .source = "import break from 'm';", .module = true, .reason = .unexpected_token, .marker = "break", .message = "Unexpected keyword 'break'" },
        .{ .source = "import value from name;", .module = true, .reason = .expected_module_specifier, .marker = "name", .message = "Unexpected identifier 'name'. Expected a string literal for module specifier." },
        .{ .source = "import * as break from 'm';", .module = true, .reason = .unexpected_token, .marker = "break", .message = "Unexpected keyword 'break'" },
        .{ .source = "import * as ns from name;", .module = true, .reason = .expected_module_specifier, .marker = "name", .message = "Unexpected identifier 'name'. Expected a string literal for module specifier." },
        .{ .source = "import * as 1 from 'm';", .module = true, .reason = .expected_import_binding, .marker = "1", .message = "Unexpected number '1'. Expected an identifier for import binding." },
        .{ .source = "import { value as } from 'm';", .module = true, .reason = .expected_import_binding, .marker = "}", .message = "Unexpected token '}'. Expected an identifier for import binding." },
        .{ .source = "import { 'value' } from 'm';", .module = true, .reason = .string_import_requires_alias, .marker = "}", .message = "Unexpected token '}'. A string import name requires an 'as' binding." },
        .{ .source = "import { value as break } from 'm';", .module = true, .reason = .unexpected_token, .marker = "break", .message = "Unexpected keyword 'break'" },
        .{ .source = "import source break from 'm';", .module = true, .reason = .unexpected_token, .marker = "break", .message = "Unexpected keyword 'break'" },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), case.source);
        if (case.module)
            try std.testing.expectError(case.reason.parseError(), parser.parseModule())
        else
            try std.testing.expectError(case.reason.parseError(), parser.parseProgram());
        try std.testing.expectEqual(case.reason, parser.last_error_reason.?);
        try std.testing.expectEqual(std.mem.indexOf(u8, case.source, case.marker).?, parser.errorLocation().byte_offset);
        try std.testing.expectEqualStrings(case.message, try parser.diagnosticMessage(arena.allocator(), case.reason));
    }
}

test "parser preserves completion-order locations across module exports and speculative for rewind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\export function outer() {
        \\  for ((function() { debugger; })(); false; ) {}
        \\}
        \\export const later = 1;
    ;
    var parser = try Parser.init(arena.allocator(), source);
    _ = try parser.parseModule();
    try std.testing.expectEqual(@as(usize, 5), parser.statement_locations.items.len);

    var saw_completion_order_descent = false;
    var previous_offset: usize = 0;
    for (parser.statement_locations.items, 0..) |entry, index| {
        try std.testing.expectEqual(sourceLocationAt(source, entry.location.byte_offset), entry.location);
        if (index > 0 and entry.location.byte_offset < previous_offset)
            saw_completion_order_descent = true;
        previous_offset = entry.location.byte_offset;
    }
    try std.testing.expect(saw_completion_order_descent);
    const later_offset = std.mem.indexOf(u8, source, "const later") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(sourceLocationAt(source, later_offset), parser.statement_location_cursor);
}

test "parser derives arguments use in the active ordinary function scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source =
        \\function clean() {
        \\  "arguments eval retrieval";
        \\  var evaluation = 0;
        \\  function inner() { return arguments.length; }
        \\  function innerEval() { return eval("arguments.length"); }
        \\  return object.eval;
        \\}
        \\function arrowOwner() { return () => arguments.length; }
        \\async function asyncUsed() { return arguments.length; }
        \\function* generatorClean() { "arguments eval"; yield 1; }
        \\function defaulted(value = (() => arguments[0])()) { return value; }
        \\function directEval() { return eval("arguments[0]"); }
        \\function indirectEval() { return eval?.("arguments[0]"); }
        \\var methods = {
        \\  clean() { "arguments eval"; return this.eval; },
        \\  used() { return { arguments }; },
        \\  get accessor() { return arguments; },
        \\  async asyncClean() { "arguments eval"; return 1; },
        \\  *generatorUsed() { return arguments; }
        \\};
        \\var expression = function named() { return arguments; };
    ;
    var parser = try Parser.init(arena.allocator(), source);
    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 9), program.program.len);

    const clean = program.program[0].func_decl;
    try std.testing.expect(!clean.uses_arguments);
    try std.testing.expect(!clean.uses_direct_eval);
    try std.testing.expect(std.mem.startsWith(u8, clean.source, "function clean()"));
    try std.testing.expectEqual(@intFromPtr(source.ptr), @intFromPtr(clean.source.ptr));
    try std.testing.expectEqual(@as(usize, 5), clean.body.block.len);
    try std.testing.expect(clean.body.block[2].func_decl.uses_arguments);
    try std.testing.expect(!clean.body.block[3].func_decl.uses_arguments);
    try std.testing.expect(clean.body.block[3].func_decl.uses_direct_eval);

    try std.testing.expect(program.program[1].func_decl.uses_arguments);
    try std.testing.expect(!program.program[1].func_decl.uses_direct_eval);
    try std.testing.expect(program.program[2].func_decl.uses_arguments);
    try std.testing.expect(!program.program[3].func_decl.uses_arguments);
    try std.testing.expect(program.program[4].func_decl.uses_arguments);
    try std.testing.expect(!program.program[5].func_decl.uses_arguments);
    try std.testing.expect(program.program[5].func_decl.uses_direct_eval);
    try std.testing.expect(!program.program[6].func_decl.uses_arguments);
    try std.testing.expect(!program.program[6].func_decl.uses_direct_eval);

    const methods_decl = program.program[7].var_decl.init orelse return error.TestUnexpectedResult;
    if (methods_decl.* != .object_lit or methods_decl.object_lit.len != 5)
        return error.TestUnexpectedResult;
    const expected_method_use = [_]bool{ false, true, true, false, true };
    for (methods_decl.object_lit, expected_method_use) |property, expected| {
        const method = property.value.function;
        try std.testing.expectEqual(expected, method.uses_arguments);
    }

    const expression_decl = program.program[8].var_decl.init orelse return error.TestUnexpectedResult;
    try std.testing.expect(expression_decl.* == .function and expression_decl.function.uses_arguments);
}

test "template function context preserves usage ownership and eval phase" {
    const cases = [_]struct { source: []const u8, arguments: bool = false, parameter_eval: bool = false, body_eval: bool = false }{
        .{ .source = "function f() { return `${arguments[0]}`; }", .arguments = true },
        .{ .source = "function f() { return tag`${arguments[0]}`; }", .arguments = true },
        .{ .source = "function f() { return `${`nested ${arguments[0]}`}`; }", .arguments = true },
        .{ .source = "function f() { return `${(() => arguments[0])()}`; }", .arguments = true },
        .{ .source = "function f() { return `${function inner(){ return arguments[0] + eval('1'); }}`; }" },
        .{ .source = "function f() { return `${eval('1')}`; }", .body_eval = true },
        .{ .source = "function f() { return tag`${eval('1')}`; }", .body_eval = true },
        .{ .source = "function f(a = `${eval('1')}`) { return a; }", .parameter_eval = true },
        .{ .source = "function f(a = tag`${eval('1')}`) { return `${eval('a')}`; }", .parameter_eval = true, .body_eval = true },
        .{ .source = "function f(a = `${(() => eval('1'))()}`) { return a; }", .parameter_eval = true },
        .{ .source = "function f() { return `${eval?.('1')}`; }" },
        .{ .source = "function f() { return `${(0,eval)('1')}`; }" },
    };
    for (cases) |case| for ([_]bool{ false, true }) |module| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), case.source);
        const program = try if (module) parser.parseModule() else parser.parseProgram();
        const function = program.program[0].func_decl;
        try std.testing.expectEqual(case.arguments, function.uses_arguments);
        try std.testing.expectEqual(case.parameter_eval, function.uses_direct_eval_in_parameters);
        try std.testing.expectEqual(case.body_eval, function.uses_direct_eval_in_body);
        try std.testing.expectEqual(case.parameter_eval or case.body_eval, function.uses_direct_eval);
    };
    for ([_][]const u8{ "`${new.target}`", "tag`${new.target}`", "(() => `${new.target}`)()" }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    }
}

test "parser distinguishes parameter-phase direct eval structurally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(),
        \\function bodyOnly(value) { return eval("value"); }
        \\function parameter(value = eval("1")) { return value; }
        \\function both(value = eval("1")) { return eval("value"); }
        \\function arrowParameter(value = (() => eval("2"))()) { return value; }
        \\function indirect(value = eval?.("3")) { return value; }
    );
    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 5), program.program.len);

    const body_only = program.program[0].func_decl;
    try std.testing.expect(body_only.uses_direct_eval);
    try std.testing.expect(!body_only.uses_direct_eval_in_parameters);
    try std.testing.expect(body_only.uses_direct_eval_in_body);

    const parameter_only = program.program[1].func_decl;
    try std.testing.expect(parameter_only.uses_direct_eval);
    try std.testing.expect(parameter_only.uses_direct_eval_in_parameters);
    try std.testing.expect(!parameter_only.uses_direct_eval_in_body);

    const both = program.program[2].func_decl;
    try std.testing.expect(both.uses_direct_eval);
    try std.testing.expect(both.uses_direct_eval_in_parameters);
    try std.testing.expect(both.uses_direct_eval_in_body);

    for (program.program[2..4]) |declaration| {
        const function = declaration.func_decl;
        try std.testing.expect(function.uses_direct_eval);
        try std.testing.expect(function.uses_direct_eval_in_parameters);
    }

    const indirect = program.program[4].func_decl;
    try std.testing.expect(!indirect.uses_direct_eval);
    try std.testing.expect(!indirect.uses_direct_eval_in_parameters);
    try std.testing.expect(!indirect.uses_direct_eval_in_body);
}

test "parser records current token source location for expected-token failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = try Parser.init(arena.allocator(), "let ok = 1;\nlet bad = ;");
    try std.testing.expectError(ParseError.UnexpectedToken, p.parseProgram());
    const loc = p.errorLocation();
    try std.testing.expectEqual(@as(usize, 2), loc.line);
    try std.testing.expectEqual(@as(usize, 11), loc.column);
}

test "parser stream reports lexer failure source location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?SourceLocation = null;
    var parser = try Parser.initWithDiagnostic(arena.allocator(), "let ok = 1;\n'", &diagnostic);
    try std.testing.expectError(lex.LexError.UnterminatedString, parser.parseProgram());
    const loc = parser.errorLocation();
    try std.testing.expectEqual(@as(usize, 2), loc.line);
    try std.testing.expectEqual(@as(usize, 2), loc.column);
}

test "parser retains generic unexpected token diagnostics and locations" {
    const Case = struct {
        source: []const u8,
        err: ParseError,
        reason: DiagnosticReason,
        marker: ?[]const u8,
        message: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "var q = ;", .err = ParseError.UnexpectedToken, .reason = .unexpected_token, .marker = ";", .message = "Unexpected token ';'" },
        .{ .source = "if (true) {", .err = ParseError.ExpectedToken, .reason = .unexpected_end_of_script, .marker = null, .message = "Unexpected end of script" },
        .{ .source = "var a b", .err = ParseError.UnexpectedToken, .reason = .expected_semicolon_after_variable_declaration, .marker = "b", .message = "Unexpected identifier 'b'. Expected ';' after variable declaration." },
        .{ .source = "1 2", .err = ParseError.UnexpectedToken, .reason = .unexpected_token, .marker = "2", .message = "Unexpected number '2'" },
        .{ .source = "'a' 'b'", .err = ParseError.UnexpectedToken, .reason = .unexpected_token, .marker = "'b'", .message = "Unexpected string literal 'b'" },
        .{ .source = "2n 3n", .err = ParseError.UnexpectedToken, .reason = .unexpected_token, .marker = "3n", .message = "Unexpected token '3n'" },
        .{ .source = "if if", .err = ParseError.ExpectedToken, .reason = .expected_if_condition, .marker = "if", .message = "Unexpected keyword 'if'. Expected '(' to start an 'if' condition." },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), case.source);
        try std.testing.expectError(case.err, parser.parseProgram());
        try std.testing.expectEqual(case.reason, parser.last_error_reason.?);
        const expected_offset = if (case.marker) |marker|
            std.mem.lastIndexOf(u8, case.source, marker).?
        else
            case.source.len;
        try std.testing.expectEqual(expected_offset, parser.errorLocation().byte_offset);
        try std.testing.expectEqualStrings(case.message, try parser.diagnosticMessage(arena.allocator(), case.reason));
    }
}

test "parser retains statement placement and control flow diagnostics" {
    const Case = struct {
        source: []const u8,
        reason: DiagnosticReason,
        marker: []const u8,
        message: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "\\u0069f (true) {}", .reason = .escaped_keyword, .marker = "\\u0069f", .message = "Unexpected escaped characters in keyword token: '\\u0069f'" },
        .{ .source = "if (true) let [a] = [];", .reason = .lexical_declaration_single_statement, .marker = "[", .message = "Unexpected token '['. Cannot use lexical declaration in single-statement context." },
        .{ .source = "if (true) const x = 1;", .reason = .unexpected_token, .marker = "const", .message = "Unexpected keyword 'const'" },
        .{ .source = "if (true) class C {}", .reason = .class_declaration_single_statement, .marker = "class", .message = "Unexpected keyword 'class'. 'class' declaration is not directly within a block statement." },
        .{ .source = "\"use strict\"; with ({}) {}", .reason = .strict_with_statement, .marker = "with", .message = "'with' statements are not valid in strict mode." },
        .{ .source = "break;", .reason = .break_outside_loop_or_switch, .marker = "break", .message = "'break' is only valid inside a switch or loop statement." },
        .{ .source = "break missing;", .reason = .undeclared_label, .marker = "missing", .message = "Cannot use the undeclared label 'missing'." },
        .{ .source = "continue;", .reason = .continue_outside_loop, .marker = "continue", .message = "'continue' is only valid inside a loop statement." },
        .{ .source = "continue missing;", .reason = .undeclared_label, .marker = "missing", .message = "Cannot use the undeclared label 'missing'." },
        .{ .source = "outer: { continue outer; }", .reason = .continue_non_loop_label, .marker = "outer;", .message = "Cannot continue to the label 'outer' as it is not targeting a loop." },
        .{ .source = "label: label: ;", .reason = .duplicate_label, .marker = ";", .message = "Unexpected token ';'. Attempted to redeclare the label 'label'." },
        .{ .source = "if (true) function* g() {}", .reason = .generator_function_single_statement, .marker = "*", .message = "Unexpected token '*'. Cannot use generator function declaration in single-statement context." },
        .{ .source = "if (true) async function f() {}", .reason = .async_function_single_statement, .marker = "function", .message = "Unexpected keyword 'function'. Cannot use async function declaration in single-statement context." },
        .{ .source = "\"use strict\"; if (true) function f() {}", .reason = .strict_function_single_statement, .marker = "function", .message = "Function declarations are only allowed inside blocks or switch statements in strict mode." },
        .{ .source = "while (false) function f() {}", .reason = .function_single_statement, .marker = "function", .message = "Unexpected keyword 'function'. Function declarations are only allowed inside block statements or at the top level of a program." },
        .{ .source = "if (true) label: function f() {}", .reason = .function_single_statement, .marker = "function", .message = "Unexpected keyword 'function'. Function declarations are only allowed inside block statements or at the top level of a program." },
        .{ .source = "using resource = {};", .reason = .using_declaration_invalid_context, .marker = "using", .message = "'using' declarations are only valid inside blocks, functions, or modules." },
        .{ .source = "await using resource = {};", .reason = .using_declaration_invalid_context, .marker = "await", .message = "'using' declarations are only valid inside blocks, functions, or modules." },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), case.source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
        try std.testing.expectEqual(case.reason, parser.last_error_reason.?);
        try std.testing.expectEqual(std.mem.indexOf(u8, case.source, case.marker).?, parser.errorLocation().byte_offset);
        try std.testing.expectEqualStrings(case.message, try parser.diagnosticMessage(arena.allocator(), case.reason));
    }

    const valid = [_][]const u8{
        "while (false) { break; }",
        "switch (0) { case 0: break; }",
        "outer: while (false) { continue outer; }",
        "if (true) function f() {}",
        "label: function f() {}",
        "{ using resource = {}; }",
    };
    for (valid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        _ = try parser.parseProgram();
    }
}

test "parser validates wide strict parameter lists without changing duplicate semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var source: std.ArrayListUnmanaged(u8) = .empty;
    try source.appendSlice(a, "function wide(");
    for (0..4096) |index| {
        if (index != 0) try source.append(a, ',');
        try source.appendSlice(a, try std.fmt.allocPrint(a, "parameter{d}", .{index}));
    }
    try source.appendSlice(a, "){\"use strict\";return 7;}");
    var wide = try Parser.initWithScratch(a, std.testing.allocator, source.items);
    _ = try wide.parseProgram();

    var strict_duplicate = try Parser.initWithScratch(a, std.testing.allocator, "function duplicate(first, second, first) { \"use strict\"; }");
    try std.testing.expectError(ParseError.UnexpectedToken, strict_duplicate.parseProgram());

    var sloppy_duplicate = try Parser.initWithScratch(a, std.testing.allocator, "function duplicate(first, second, first) {}");
    _ = try sloppy_duplicate.parseProgram();
}

test "parser reserves strict parameter uniqueness storage once" {
    const params = [_]ast.Param{
        .{ .name = "parameter00" },
        .{ .name = "parameter01" },
        .{ .name = "parameter02" },
        .{ .name = "parameter03" },
        .{ .name = "parameter04" },
        .{ .name = "parameter05" },
        .{ .name = "parameter06" },
        .{ .name = "parameter07" },
        .{ .name = "parameter08" },
        .{ .name = "parameter09" },
        .{ .name = "parameter10" },
        .{ .name = "parameter11" },
        .{ .name = "parameter12" },
        .{ .name = "parameter13" },
        .{ .name = "parameter14" },
        .{ .name = "parameter15" },
    };

    var measured = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var parser: Parser = undefined;
    parser.scratch_allocator = measured.allocator();
    parser.secure_hash_state = .{};
    parser.shared_secure_hash_state = null;
    parser.source = "";
    parser.current_token = &synthetic_eof_token;
    parser.last_error_offset = null;
    parser.last_error_reason = null;
    parser.last_error_token = null;
    try parser.validateStrictParams(&params);
    try std.testing.expectEqual(@as(usize, 1), measured.allocations);
    try std.testing.expectEqual(@as(usize, 1), measured.deallocations);
    try std.testing.expectEqual(measured.allocated_bytes, measured.freed_bytes);

    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    parser.scratch_allocator = fixed.allocator();
    try parser.validateStrictParams(&.{});
    try parser.validateStrictParams(&.{.{ .name = "only" }});

    var allocation_failure = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    parser.scratch_allocator = allocation_failure.allocator();
    try std.testing.expectError(error.OutOfMemory, parser.validateStrictParams(params[0..2]));
    parser.scratch_allocator = std.testing.allocator;
    try parser.validateStrictParams(params[0..2]);

    const invalid = [_][]const ast.Param{
        &.{ .{ .name = "first" }, .{ .name = "first" } },
        &.{ .{ .name = "eval" }, .{ .name = "second" } },
        &.{ .{ .name = "first" }, .{ .name = "arguments" } },
        &.{ .{ .name = "first" }, .{ .name = "implements" } },
    };
    for (invalid) |case| try std.testing.expectError(ParseError.UnexpectedToken, parser.validateStrictParams(case));
}

test "dynamic function validation pins the synthesized function boundary" {
    const valid_source = "(function(a\n) {\nreturn a;\n})";
    var valid_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer valid_arena.deinit();
    var valid = try Parser.initWithScratch(valid_arena.allocator(), std.testing.allocator, valid_source);
    const valid_program = try valid.parseProgram();
    try valid.validateDynamicFunctionProgram(valid_program, valid_source[1 .. valid_source.len - 1]);

    const injected = [_][]const u8{
        "(function(\n) {\n}); globalThis.injected = 1; (function(){\n})",
        "(function(\n) {\n}, function(){ return 'inj'\n})",
        "(function(\n) {\n}, function(){\n})",
        "(function(\n) {\n})(); (function(){\n})",
    };
    for (injected) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        const program = try parser.parseProgram();
        try std.testing.expectError(
            ParseError.UnexpectedToken,
            parser.validateDynamicFunctionProgram(program, source[1 .. source.len - 1]),
        );
    }
}

test "parser source-name indexes share one lazy secure parse-root context" {
    var unavailable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var failed_state: SecureHashState = .{};
    var failed = SecureStringMapUnmanaged(void){ .state = &failed_state };
    defer failed.deinit(unavailable.allocator());
    try std.testing.expectError(error.OutOfMemory, failed.put(unavailable.allocator(), "first", {}));
    try std.testing.expect(failed_state.context == null);
    try std.testing.expectEqual(@as(usize, 0), failed.count());
    try std.testing.expectEqual(@as(usize, 0), failed.index.capacity());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first_shape = try Shape.createRoot(a);
    const second_shape = try Shape.createRoot(a);

    var empty = try Parser.init(a, "1 + 2;");
    empty.useRealmHashKeys(first_shape);
    _ = try empty.parseProgram();
    try std.testing.expect(empty.secure_hash_state.context == null);

    var first = try Parser.init(a, "let first; let second;");
    first.useRealmHashKeys(first_shape);
    _ = try first.parseProgram();
    const first_context = first.secure_hash_state.context orelse return error.TestUnexpectedResult;

    var second = try Parser.init(a, "let first; let second;");
    second.useRealmHashKeys(second_shape);
    _ = try second.parseProgram();
    const second_context = second.secure_hash_state.context orelse return error.TestUnexpectedResult;
    try std.testing.expect(first_context.seed != second_context.seed);

    var nested = try Parser.init(a, "`${function duplicate(first, second, first) { \"use strict\"; }}`");
    nested.useRealmHashKeys(first_shape);
    try std.testing.expectError(ParseError.UnexpectedToken, nested.parseProgram());
    try std.testing.expect(nested.secure_hash_state.context != null);

    var shared_state = SecureHashState{ .context = first_context };
    var wide_index = SecureStringMapUnmanaged(void){ .state = &shared_state };
    defer wide_index.deinit(std.testing.allocator);
    var wide_name: [4096]u8 = @splat('w');
    try wide_index.put(std.testing.allocator, &wide_name, {});
    try std.testing.expect(wide_index.contains(&wide_name));
    try std.testing.expectEqual(@as(usize, 1), wide_index.count());
}

test "parser cover grammar identity indexes are keyed lazy and failure atomic" {
    var empty_state: SecureHashState = .{};
    var empty: SecureIdentityMapUnmanaged(void) = .{};
    defer empty.deinit(std.testing.allocator);
    try std.testing.expect(!empty.contains(&empty_state, 0x101));
    try std.testing.expect(!empty.remove(&empty_state, 0x101));
    try std.testing.expect(empty_state.context == null);

    var unavailable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, empty.put(unavailable.allocator(), &empty_state, 0x101, {}));
    try std.testing.expect(empty_state.context == null);
    try std.testing.expectEqual(@as(usize, 0), empty.count());
    try std.testing.expectEqual(@as(usize, 0), empty.index.capacity());
    try empty.put(std.testing.allocator, &empty_state, 0x101, {});
    try std.testing.expect(empty_state.context != null);
    try std.testing.expect(empty.contains(&empty_state, 0x101));

    const target_mask: u64 = 1023;
    var collision_identities: [32]usize = undefined;
    var collision_count: usize = 0;
    var candidate: usize = 1;
    while (collision_count < collision_identities.len) : (candidate += 1) {
        if ((SecureIdentityHashContext{ .seed = 0 }).hash(candidate) & target_mask != 0) continue;
        collision_identities[collision_count] = candidate;
        collision_count += 1;
    }

    var keyed_state = SecureHashState{ .context = .{ .seed = 0xC0_5645_5247_5241_4D } };
    var keyed: SecureIdentityMapUnmanaged(void) = .{};
    defer keyed.deinit(std.testing.allocator);
    var keyed_buckets: [target_mask + 1]bool = @splat(false);
    var distinct_keyed_buckets: usize = 0;
    for (collision_identities) |identity| {
        try std.testing.expectEqual(@as(u64, 0), (SecureIdentityHashContext{ .seed = 0 }).hash(identity) & target_mask);
        const bucket = (SecureIdentityHashContext{ .seed = keyed_state.context.?.seed }).hash(identity) & target_mask;
        if (!keyed_buckets[bucket]) {
            keyed_buckets[bucket] = true;
            distinct_keyed_buckets += 1;
        }
        try keyed.put(std.testing.allocator, &keyed_state, identity, {});
    }
    try std.testing.expect(distinct_keyed_buckets >= 24);
    try std.testing.expectEqual(collision_identities.len, keyed.count());
    for (collision_identities) |identity| try std.testing.expect(keyed.contains(&keyed_state, identity));
    for (collision_identities[0..16]) |identity| try std.testing.expect(keyed.remove(&keyed_state, identity));
    for (collision_identities[0..16]) |identity| try std.testing.expect(!keyed.contains(&keyed_state, identity));
    for (collision_identities[16..]) |identity| try std.testing.expect(keyed.contains(&keyed_state, identity));
}

test "parser preserves cover grammar facts with keyed node identity" {
    const AllocationProbe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var failure_arena = std.heap.ArenaAllocator.init(allocator);
            defer failure_arena.deinit();
            var parser = try Parser.init(failure_arena.allocator(),
                \\(value);
                \\([...rest,]);
                \\({ value = fallback, __proto__: left, __proto__: right } = source);
            );
            // Allocation replay must not depend on an entropy source or a
            // realm's separately allocated Shape.
            parser.secure_hash_state.context = .{ .seed = 0xC0_5645_5247_4F4F_4D };
            _ = try parser.parseProgram();
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, AllocationProbe.run, .{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root_shape = try Shape.createRoot(allocator);

    var empty = try Parser.init(allocator, "value;");
    empty.useRealmHashKeys(root_shape);
    _ = try empty.parseProgram();
    try std.testing.expect(empty.secure_hash_state.context == null);

    var parenthesized = try Parser.init(allocator, "(value);");
    parenthesized.useRealmHashKeys(root_shape);
    _ = try parenthesized.parseProgram();
    try std.testing.expect(parenthesized.secure_hash_state.context != null);
    try std.testing.expectEqual(@as(usize, 1), parenthesized.paren_wrapped.count());

    var nested = try Parser.init(allocator, "`${(value)}`;");
    nested.useRealmHashKeys(root_shape);
    _ = try nested.parseProgram();
    // The substitution parser owns its identity index but installs the key in
    // the enclosing parse root, just like source-name indexes.
    try std.testing.expect(nested.secure_hash_state.context != null);

    var array_rest = try Parser.init(allocator, "[...rest,] = source;");
    array_rest.useRealmHashKeys(root_shape);
    try std.testing.expectError(ParseError.InvalidAssignmentTarget, array_rest.parseProgram());
    try std.testing.expectEqual(@as(usize, 1), array_rest.rest_comma_arrays.count());

    var refined = try Parser.init(allocator, "({ value = fallback, __proto__: left, __proto__: right } = source);");
    refined.useRealmHashKeys(root_shape);
    _ = try refined.parseProgram();
    try std.testing.expectEqual(@as(usize, 0), refined.pending_cover_inits.count());
    try std.testing.expectEqual(@as(usize, 0), refined.pending_proto_dup.count());

    var cover_literal = try Parser.init(allocator, "({ value = fallback });");
    cover_literal.useRealmHashKeys(root_shape);
    try std.testing.expectError(ParseError.UnexpectedToken, cover_literal.parseProgram());
    try std.testing.expectEqual(@as(usize, 1), cover_literal.pending_cover_inits.count());

    var duplicate_proto = try Parser.init(allocator, "({ __proto__: left, __proto__: right });");
    duplicate_proto.useRealmHashKeys(root_shape);
    try std.testing.expectError(ParseError.UnexpectedToken, duplicate_proto.parseProgram());
    try std.testing.expectEqual(@as(usize, 1), duplicate_proto.pending_proto_dup.count());
}

test "parser builds precedence-correct tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = try Parser.init(arena.allocator(), "1 + 2 * 3");
    const prog = try p.parseProgram();
    try std.testing.expect(prog.* == .program);
    const stmt = prog.program[0];
    try std.testing.expect(stmt.* == .expr_stmt);
    const e = stmt.expr_stmt;
    try std.testing.expect(e.* == .binary);
    try std.testing.expectEqual(ast.BinaryOp.add, e.binary.op);
    // right side must be the multiplication (binds tighter)
    try std.testing.expect(e.binary.right.* == .binary);
    try std.testing.expectEqual(ast.BinaryOp.mul, e.binary.right.binary.op);
}

test "parser handles var decl and if" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var p = try Parser.init(arena.allocator(), "let x = 1; if (x) x = 2; else x = 3;");
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), prog.program.len);
    try std.testing.expect(prog.program[0].* == .var_decl);
    try std.testing.expect(prog.program[1].* == .if_stmt);
}

test "parser requires statement boundary between same-line tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var single = try Parser.init(arena.allocator(), "var str = '''';");
    try std.testing.expectError(ParseError.UnexpectedToken, single.parseProgram());

    var double = try Parser.init(arena.allocator(), "var str = \"\"\"\";");
    try std.testing.expectError(ParseError.UnexpectedToken, double.parseProgram());

    var adjacent_expr = try Parser.init(arena.allocator(), "a b");
    try std.testing.expectError(ParseError.UnexpectedToken, adjacent_expr.parseProgram());
}

test "parser rejects duplicate lexical names in classic for heads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var dup_names = try Parser.init(arena.allocator(), "for (let x, x; ; ) ;");
    try std.testing.expectError(ParseError.UnexpectedToken, dup_names.parseProgram());

    var dup_pattern = try Parser.init(arena.allocator(), "for (const [z, z] = [0, 1]; ; ) ;");
    try std.testing.expectError(ParseError.UnexpectedToken, dup_pattern.parseProgram());

    var valid_pattern = try Parser.init(arena.allocator(), "for (let [z] = [0]; ; ) ;");
    _ = try valid_pattern.parseProgram();
}

test "parser keeps class field initializers out of enclosing await context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var await_ident = try Parser.init(arena.allocator(), "var await = 1; async function f() { return class { x = await; }; }");
    _ = try await_ident.parseProgram();

    var await_expr = try Parser.init(arena.allocator(), "async () => class { x = await 1 };");
    try std.testing.expectError(ParseError.UnexpectedToken, await_expr.parseProgram());
}

test "yield and await regex operands retain postfix member tails" {
    const sources = [_][]const u8{
        "function* g(){ yield /a/.source; }",
        "async function f(){ return await /a/.source; }",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        _ = try parser.parseProgram();
    }
}

test "parser lexical goals distinguish regex literals from division in grammar context" {
    const cases = [_][]const u8{
        "label: {} /\"/.test(\"\\\"\");",
        "switch (0) { case 0: {} /\"/.test(\"\\\"\"); }",
        "var value = class {} / 2;",
        "function* generator(){ yield /\"/.source; }",
        "async function task(){ return await /\"/.source; }",
        "(value = class {} / 2) => value;",
        "(value = /[)]/) => value;",
        "(first = /[)]/, second = class {} / 2) => second;",
        "(first = `${`)`}`, second = class {} / 2) => second;",
        "var arrow = (first = /[)]/, second = class {} / 2) => second;",
        "(class {} / 2);",
        "for (var value = class {} / 2; value; value--) {}",
        "for (var first = /[;]/, value = class {} / 2; value; value--) {}",
    };

    for (cases) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        _ = try parser.parseProgram();
    }
}

test "parser rejects malformed untagged template escapes" {
    const Case = struct {
        source: []const u8,
        reason: DiagnosticReason,
        message: []const u8,
    };
    const invalid = [_]Case{
        .{ .source = "`\\x0`", .reason = .malformed_template_hex_escape, .message = "\\x can only be followed by a hex character sequence" },
        .{ .source = "`\\x0G`", .reason = .malformed_template_hex_escape, .message = "\\x can only be followed by a hex character sequence" },
        .{ .source = "`\\xG`", .reason = .malformed_template_hex_escape, .message = "\\x can only be followed by a hex character sequence" },
        .{ .source = "`\\u0`", .reason = .malformed_template_unicode_escape, .message = "\\u can only be followed by a Unicode character sequence" },
        .{ .source = "`\\u0g`", .reason = .malformed_template_unicode_escape, .message = "\\u can only be followed by a Unicode character sequence" },
        .{ .source = "`\\u00g`", .reason = .malformed_template_unicode_escape, .message = "\\u can only be followed by a Unicode character sequence" },
        .{ .source = "`\\u000g`", .reason = .malformed_template_unicode_escape, .message = "\\u can only be followed by a Unicode character sequence" },
        .{ .source = "`\\u{g`", .reason = .malformed_template_unicode_escape, .message = "\\u can only be followed by a Unicode character sequence" },
        .{ .source = "`\\u{0`", .reason = .malformed_template_unicode_escape, .message = "\\u can only be followed by a Unicode character sequence" },
        .{ .source = "`\\u{10FFFFF}`", .reason = .malformed_template_unicode_escape, .message = "\\u can only be followed by a Unicode character sequence" },
        .{ .source = "`\\u{1F_639}`", .reason = .malformed_template_unicode_escape, .message = "\\u can only be followed by a Unicode character sequence" },
        .{ .source = "`\\u`", .reason = .malformed_template_unicode_escape, .message = "\\u can only be followed by a Unicode character sequence" },
        .{ .source = "`\\00`", .reason = .template_numeric_escape, .message = "The only valid numeric escape in strict mode is '\\0'" },
        .{ .source = "`\\8`", .reason = .template_numeric_escape, .message = "The only valid numeric escape in strict mode is '\\0'" },
        .{ .source = "`\\9`", .reason = .template_numeric_escape, .message = "The only valid numeric escape in strict mode is '\\0'" },
        .{ .source = "`head${1}mid\r\\u0${2}tail`", .reason = .malformed_template_unicode_escape, .message = "\\u can only be followed by a Unicode character sequence" },
        // The invalid tail is normalized before cooking. Its retained source
        // offset must still cross the original two-byte CRLF exactly.
        .{ .source = "`head${1}tail\r\n\\x0`", .reason = .malformed_template_hex_escape, .message = "\\x can only be followed by a hex character sequence" },
    };
    for (invalid) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var p = try Parser.init(arena.allocator(), case.source);
        try std.testing.expectError(ParseError.UnexpectedToken, p.parseProgram());
        try std.testing.expectEqual(case.reason, p.last_error_reason.?);
        try std.testing.expectEqual(std.mem.indexOfScalar(u8, case.source, '\\').?, p.errorLocation().byte_offset);
        try std.testing.expectEqualStrings(case.message, try p.diagnosticMessage(arena.allocator(), case.reason));
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ok = try Parser.init(arena.allocator(), "`\\n${1}\\u{41}`");
    _ = try ok.parseProgram();
}

test "parser borrows plain template quasis and owns decoded storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const plain_source = "`plain template`";
    var plain_parser = try Parser.init(arena.allocator(), plain_source);
    const plain_program = try plain_parser.parseProgram();
    const plain = plain_program.program[0].expr_stmt;
    try std.testing.expect(plain.* == .string);
    try std.testing.expectEqualStrings("plain template", plain.string);
    try std.testing.expectEqual(@intFromPtr(plain_source.ptr + 1), @intFromPtr(plain.string.ptr));

    const tagged_source = "tag`left${value}right`";
    var tagged_parser = try Parser.init(arena.allocator(), tagged_source);
    const tagged_program = try tagged_parser.parseProgram();
    const tagged = tagged_program.program[0].expr_stmt;
    try std.testing.expect(tagged.* == .tagged_template);
    try std.testing.expectEqual(@as(usize, 2), tagged.tagged_template.cooked.len);
    try std.testing.expectEqual(@as(usize, 2), tagged.tagged_template.raw.len);
    try std.testing.expectEqual(@as(usize, 1), tagged.tagged_template.exprs.len);
    const left = tagged.tagged_template.cooked[0] orelse return error.TestUnexpectedResult;
    const right = tagged.tagged_template.cooked[1] orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("left", left);
    try std.testing.expectEqualStrings("right", right);
    try std.testing.expectEqual(@intFromPtr(tagged_source.ptr + 4), @intFromPtr(left.ptr));
    try std.testing.expectEqual(@intFromPtr(tagged.tagged_template.raw[0].ptr), @intFromPtr(left.ptr));
    try std.testing.expectEqual(@intFromPtr(tagged_source.ptr + std.mem.indexOf(u8, tagged_source, "right").?), @intFromPtr(right.ptr));
    try std.testing.expectEqual(@intFromPtr(tagged.tagged_template.raw[1].ptr), @intFromPtr(right.ptr));

    const escaped_source = "tag`raw\\nspan\\u0021tail`";
    var escaped_parser = try Parser.init(arena.allocator(), escaped_source);
    const escaped_program = try escaped_parser.parseProgram();
    const escaped = escaped_program.program[0].expr_stmt.tagged_template;
    const cooked = escaped.cooked[0] orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("raw\nspan!tail", cooked);
    try std.testing.expectEqualStrings("raw\\nspan\\u0021tail", escaped.raw[0]);
    try std.testing.expectEqual(@intFromPtr(escaped_source.ptr + 4), @intFromPtr(escaped.raw[0].ptr));
    try std.testing.expect(@intFromPtr(cooked.ptr) != @intFromPtr(escaped.raw[0].ptr));

    const normalized_source = "tag`left\r\nright`";
    var normalized_parser = try Parser.init(arena.allocator(), normalized_source);
    const normalized_program = try normalized_parser.parseProgram();
    const normalized = normalized_program.program[0].expr_stmt.tagged_template;
    const normalized_cooked = normalized.cooked[0] orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("left\nright", normalized_cooked);
    try std.testing.expectEqualStrings("left\nright", normalized.raw[0]);
    try std.testing.expect(@intFromPtr(normalized_cooked.ptr) != @intFromPtr(normalized_source.ptr + 4));
    try std.testing.expectEqual(@intFromPtr(normalized_cooked.ptr), @intFromPtr(normalized.raw[0].ptr));
}

test "parser normalizes template raw text with exact failure-atomic storage" {
    const plain = "plain source-backed raw text";
    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    const borrowed = try Parser.normalizeTemplateRaw(fixed.allocator(), plain);
    try std.testing.expectEqual(@intFromPtr(plain.ptr), @intFromPtr(borrowed.ptr));

    const raw = "\rleading\r\nmid\rlast\r\n\xe2\x80\xa8\xe2\x80\xa9";
    const expected = "\nleading\nmid\nlast\n\xe2\x80\xa8\xe2\x80\xa9";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var measured = std.testing.FailingAllocator.init(arena.allocator(), .{});
    const normalized = try Parser.normalizeTemplateRaw(measured.allocator(), raw);
    try std.testing.expectEqualStrings(expected, normalized);
    try std.testing.expectEqual(@as(usize, 1), measured.allocations);
    try std.testing.expectEqual(@as(usize, 0), measured.resize_index);
    try std.testing.expectEqual(expected.len, measured.allocated_bytes);

    var failure_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer failure_arena.deinit();
    var allocation_failure = std.testing.FailingAllocator.init(failure_arena.allocator(), .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Parser.normalizeTemplateRaw(allocation_failure.allocator(), raw));
    try std.testing.expectEqualStrings(expected, try Parser.normalizeTemplateRaw(failure_arena.allocator(), raw));
}

test "parser preserves normalized tagged template quasis across substitutions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "tag`\rstart\\\r\n${value}\rmid\xe2\x80\xa8tail\xe2\x80\xa9`");
    const program = try parser.parseProgram();
    const template = program.program[0].expr_stmt.tagged_template;
    try std.testing.expectEqual(@as(usize, 2), template.cooked.len);
    try std.testing.expectEqual(@as(usize, 2), template.raw.len);
    try std.testing.expectEqual(@as(usize, 1), template.exprs.len);
    try std.testing.expectEqualStrings("\nstart", template.cooked[0].?);
    try std.testing.expectEqualStrings("\nstart\\\n", template.raw[0]);
    try std.testing.expectEqualStrings("\nmid\xe2\x80\xa8tail\xe2\x80\xa9", template.cooked[1].?);
    try std.testing.expectEqualStrings("\nmid\xe2\x80\xa8tail\xe2\x80\xa9", template.raw[1]);
}

test "parser cooks template quasis with exact failure-atomic storage" {
    const plain = "plain source-backed quasi";
    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    var borrowing: Parser = undefined;
    borrowing.arena = fixed.allocator();
    const borrowed = (try borrowing.cookTemplateQuasi(plain, false, null)).?;
    try std.testing.expectEqual(@intFromPtr(plain.ptr), @intFromPtr(borrowed.ptr));

    const raw = "raw\\nspan\\u0021\\uD83D\\uDE00\\uD800\\\ntail";
    const expected = "raw\nspan!\xf0\x9f\x98\x80\xed\xa0\x80tail";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var measured = std.testing.FailingAllocator.init(arena.allocator(), .{});
    var cooking: Parser = undefined;
    cooking.arena = measured.allocator();
    const cooked = (try cooking.cookTemplateQuasi(raw, false, null)).?;
    try std.testing.expectEqualStrings(expected, cooked);
    try std.testing.expectEqual(@as(usize, 1), measured.allocations);
    try std.testing.expectEqual(@as(usize, 0), measured.resize_index);
    try std.testing.expectEqual(expected.len, measured.allocated_bytes);

    var invalid_tagged: Parser = undefined;
    invalid_tagged.arena = fixed.allocator();
    try std.testing.expectEqual(@as(?[]const u8, null), try invalid_tagged.cookTemplateQuasi("raw\\u{110000}tail", true, null));
    try std.testing.expectError(ParseError.UnexpectedToken, invalid_tagged.cookTemplateQuasi("raw\\u{110000}tail", false, null));

    var failure_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer failure_arena.deinit();
    var allocation_failure = std.testing.FailingAllocator.init(failure_arena.allocator(), .{ .fail_index = 0 });
    var failing: Parser = undefined;
    failing.arena = allocation_failure.allocator();
    try std.testing.expectError(error.OutOfMemory, failing.cookTemplateQuasi(raw, false, null));
    failing.arena = failure_arena.allocator();
    try std.testing.expectEqualStrings(expected, (try failing.cookTemplateQuasi(raw, false, null)).?);
}

test "parser preserves raw and cooked template quasis across substitutions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "tag`left\\n${value}right\\u0021${other}tail\\uD800`");
    const program = try parser.parseProgram();
    const template = program.program[0].expr_stmt.tagged_template;
    try std.testing.expectEqual(@as(usize, 3), template.cooked.len);
    try std.testing.expectEqual(@as(usize, 3), template.raw.len);
    try std.testing.expectEqual(@as(usize, 2), template.exprs.len);
    try std.testing.expectEqualStrings("left\n", template.cooked[0].?);
    try std.testing.expectEqualStrings("right!", template.cooked[1].?);
    try std.testing.expectEqualStrings("tail\xed\xa0\x80", template.cooked[2].?);
    try std.testing.expectEqualStrings("left\\n", template.raw[0]);
    try std.testing.expectEqualStrings("right\\u0021", template.raw[1]);
    try std.testing.expectEqualStrings("tail\\uD800", template.raw[2]);

    var invalid = try Parser.init(arena.allocator(), "tag`hex\\x0${value}unicode\\u0${other}numeric\\8`");
    const invalid_program = try invalid.parseProgram();
    const invalid_template = invalid_program.program[0].expr_stmt.tagged_template;
    try std.testing.expectEqual(@as(usize, 3), invalid_template.cooked.len);
    try std.testing.expectEqual(@as(?[]const u8, null), invalid_template.cooked[0]);
    try std.testing.expectEqual(@as(?[]const u8, null), invalid_template.cooked[1]);
    try std.testing.expectEqual(@as(?[]const u8, null), invalid_template.cooked[2]);
    try std.testing.expectEqualStrings("hex\\x0", invalid_template.raw[0]);
    try std.testing.expectEqualStrings("unicode\\u0", invalid_template.raw[1]);
    try std.testing.expectEqualStrings("numeric\\8", invalid_template.raw[2]);
}

test "tagged template assembly uses one scratch allocation and untagged templates use none" {
    for ([_][]const u8{"tag`${1}${2}${3}${4}`"}) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scratch = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
        var parser = try Parser.initWithScratch(arena.allocator(), scratch.allocator(), source);
        _ = try parser.parseProgram();
        try std.testing.expectEqual(@as(usize, 1), scratch.allocations);
        try std.testing.expectEqual(scratch.allocated_bytes, scratch.freed_bytes);
    }
    for ([_][]const u8{ "tag`plain`", "`plain`", "`${1}${2}${3}${4}`" }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scratch = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        var parser = try Parser.initWithScratch(arena.allocator(), scratch.allocator(), source);
        _ = try parser.parseProgram();
        try std.testing.expectEqual(@as(usize, 0), scratch.allocations);
    }
}

test "streamed template assembly does not own decoded AST payloads or function source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "tag`a${'\\u0061'}b${\\u0062}c${function f(){return 'c';}}d${tag`n${'\\u0064'}`}e${1+2+3+4+5+6+7+8+9+10}`";
    var scratch = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var parser = try Parser.initWithScratch(arena.allocator(), scratch.allocator(), source);
    const program = try parser.parseProgram();
    try std.testing.expectEqual(scratch.allocated_bytes, scratch.freed_bytes);
    const expressions = program.program[0].expr_stmt.tagged_template.exprs;
    try std.testing.expectEqualStrings("a", expressions[0].string);
    try std.testing.expectEqualStrings("b", expressions[1].identifier);
    try std.testing.expectEqualStrings("function f(){return 'c';}", expressions[2].function.source);
    try std.testing.expectEqualStrings("c", expressions[2].function.body.block[0].return_stmt.?.string);
    try std.testing.expectEqualStrings("d", expressions[3].tagged_template.exprs[0].string);
    try std.testing.expectEqual(ast.BinaryOp.add, expressions[4].binary.op);
}

test "streamed template assembly releases scratch on syntax failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var scratch = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var parser = try Parser.initWithScratch(arena.allocator(), scratch.allocator(), "tag`${1}${({get x(é){}})}`");
    try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    try std.testing.expectEqual(scratch.allocated_bytes, scratch.freed_bytes);
    try std.testing.expectEqualStrings("Unexpected identifier 'é'. getter functions must have no parameters.", try parser.diagnosticMessage(arena.allocator(), parser.last_error_reason.?));
}

test "streamed tagged template growth propagates scratch allocation failures" {
    const Probe = struct {
        fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const backing: *std.mem.Allocator = @ptrCast(@alignCast(raw));
            return backing.rawAlloc(len, alignment, ra);
        }

        fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const backing: *std.mem.Allocator = @ptrCast(@alignCast(raw));
            backing.rawFree(memory, alignment, ra);
        }

        fn run(scratch: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var parser = try Parser.initWithScratch(arena.allocator(), scratch, "tag`${1}${1+2+3+4+5+6+7+8+9+10}${tag`${'\\u0061'}`}`");
            _ = try parser.parseProgram();
        }
    };
    var backing = std.testing.allocator;
    // Part storage grows by remapping, and whether the testing allocator can
    // extend a buffer in place depends on what else is free next to it. A run
    // that grows in place makes one allocation fewer than a run that copies,
    // so the replay saw a different count from one run to the next and failed
    // with NondeterministicMemoryUsage on Linux CI. Refusing in-place growth
    // makes every growth an allocation the replay can fail.
    const non_resizing: std.mem.Allocator = .{ .ptr = &backing, .vtable = &.{
        .alloc = Probe.alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = Probe.free,
    } };
    try std.testing.checkAllAllocationFailures(non_resizing, Probe.run, .{});
}

test "parser fills exact tagged template arrays across nested substitutions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), "tag`a${{ nested: { value: 1 } }}b${`inner${2}`}c${/}/.test('}')}d`");
    const program = try parser.parseProgram();
    const template = program.program[0].expr_stmt.tagged_template;
    try std.testing.expectEqual(@as(usize, 4), template.cooked.len);
    try std.testing.expectEqual(@as(usize, 4), template.raw.len);
    try std.testing.expectEqual(@as(usize, 3), template.exprs.len);
    for (template.cooked, template.raw, [_][]const u8{ "a", "b", "c", "d" }) |cooked, raw, expected| {
        try std.testing.expectEqualStrings(expected, cooked.?);
        try std.testing.expectEqualStrings(expected, raw);
        try std.testing.expectEqual(@intFromPtr(cooked.?.ptr), @intFromPtr(raw.ptr));
    }
}

test "template substitutions use the ordinary expression token stream" {
    const sources = [_][]const u8{
        "var x = `${ typeof /}/ }`; x",
        "var x = `${ (() => { return /}/.source })() }`; x",
        "var x = `${ void /`/ }`; x",
        "var x = `${ [1].map(function(){ return /\"/.source })[0] }`; x",
        "var x = `${ \"source\" in /}/ }`; x",
        "var x = `${ (function(v){ switch (v) { case /}/.source: return 12 } })(\"}\") }`; x",
        "function t(s, v){ return v; } var x = t`${ typeof /}/ }`; x",
        "var s = 'a\"b'; var x = `${s.split(\"\").map(c => { return /\"/.test(c) ? \"&quot;\" : c }).join(\"\")}`; x",
        "var i = 1; var x = `${i++ / 2}`; x",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        _ = try parser.parseProgram();
    }
}

test "parser propagates template decoding allocation failures" {
    var saw_out_of_memory = false;
    var saw_success = false;
    for (0..64) |fail_index| {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = fail_index });
        var arena = std.heap.ArenaAllocator.init(failing.allocator());
        defer arena.deinit();

        var parser = Parser.init(arena.allocator(), "tag`raw\\n${value}span\\u0021tail`") catch |err| {
            if (err != error.OutOfMemory) return err;
            saw_out_of_memory = true;
            continue;
        };
        _ = parser.parseProgram() catch |err| {
            if (err != error.OutOfMemory) return err;
            saw_out_of_memory = true;
            continue;
        };
        saw_success = true;
        break;
    }
    try std.testing.expect(saw_out_of_memory);
    try std.testing.expect(saw_success);
}

test "parser enforces reserved words in identifier positions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var shorthand_true = try Parser.init(arena.allocator(), "({ true });");
    try std.testing.expectError(ParseError.UnexpectedToken, shorthand_true.parseProgram());

    var shorthand_false = try Parser.init(arena.allocator(), "({ false });");
    try std.testing.expectError(ParseError.UnexpectedToken, shorthand_false.parseProgram());

    var shorthand_null = try Parser.init(arena.allocator(), "({ null });");
    try std.testing.expectError(ParseError.UnexpectedToken, shorthand_null.parseProgram());

    var property_name = try Parser.init(arena.allocator(), "({ true: 1, false() {}, get null() { return 1; } });");
    const property_prog = try property_name.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), property_prog.program.len);

    var module_await = try Parser.init(arena.allocator(), "var await;");
    try std.testing.expectError(ParseError.UnexpectedToken, module_await.parseModule());

    var script_await = try Parser.init(arena.allocator(), "var await;");
    const script_prog = try script_await.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), script_prog.program.len);
}

test "parser enforces Unicode identifier properties in bindings and private names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var raw = try Parser.init(arena.allocator(), "var π\u{0301} = 1; π\u{0301}; class C { #℘\u{0301}; read(){ return this.#℘\u{0301}; } }");
    const raw_program = try raw.parseProgram();
    try std.testing.expectEqual(@as(usize, 3), raw_program.program.len);

    var escaped = try Parser.init(arena.allocator(), "var \\u2118\\u0301 = 1; \\u2118\\u0301;");
    const escaped_program = try escaped.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), escaped_program.program.len);

    const invalid = [_][]const u8{
        "var ☃ = 1;",
        "var a☃ = 1;",
        "var \\u2603 = 1;",
        "class C { #☃; }",
        "class C { #a☃; }",
    };
    for (invalid) |source| {
        var parser = try Parser.init(arena.allocator(), source);
        try std.testing.expectError(lex.LexError.UnexpectedCharacter, parser.parseProgram());
    }
}

test "parser accepts ASI line terminators between statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lf = try Parser.init(arena.allocator(), "var a = 1\nvar b = 2");
    const lf_prog = try lf.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), lf_prog.program.len);

    var cr = try Parser.init(arena.allocator(), "var a = 1\rvar b = 2");
    const cr_prog = try cr.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), cr_prog.program.len);

    var ls = try Parser.init(arena.allocator(), "var a = 1\u{2028}var b = 2");
    const ls_prog = try ls.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), ls_prog.program.len);

    var prefix_inc = try Parser.init(arena.allocator(), "var x = 0; var y = 0; x\n++y");
    const prefix_inc_prog = try prefix_inc.parseProgram();
    try std.testing.expectEqual(@as(usize, 4), prefix_inc_prog.program.len);

    var prefix_dec = try Parser.init(arena.allocator(), "var x = 0; var y = 2; x\n--y");
    const prefix_dec_prog = try prefix_dec.parseProgram();
    try std.testing.expectEqual(@as(usize, 4), prefix_dec_prog.program.len);

    var assign_then_inc = try Parser.init(arena.allocator(), "var a=1,b=2,c=3; a=b\n++c");
    const assign_then_inc_prog = try assign_then_inc.parseProgram();
    try std.testing.expectEqual(@as(usize, 3), assign_then_inc_prog.program.len);

    var return_newline = try Parser.init(arena.allocator(), "function f(){ return\n1; }");
    const return_newline_prog = try return_newline.parseProgram();
    const return_body = return_newline_prog.program[0].func_decl.body.block;
    try std.testing.expect(return_body[0].return_stmt == null);
    try std.testing.expect(return_body[1].* == .expr_stmt);

    var break_newline = try Parser.init(arena.allocator(), "label: while (true) { break\nlabel; }");
    const break_newline_prog = try break_newline.parseProgram();
    const break_stmt = break_newline_prog.program[0].labeled_stmt.body.while_stmt.body.block[0];
    try std.testing.expect(break_stmt.break_stmt == null);

    var continue_newline = try Parser.init(arena.allocator(), "label: while (true) { continue\nlabel; }");
    const continue_newline_prog = try continue_newline.parseProgram();
    const continue_stmt = continue_newline_prog.program[0].labeled_stmt.body.while_stmt.body.block[0];
    try std.testing.expect(continue_stmt.continue_stmt == null);

    var throw_newline = try Parser.init(arena.allocator(), "throw\n1;");
    try std.testing.expectError(ParseError.UnexpectedToken, throw_newline.parseProgram());
}

test "parser requires module import export statement boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var named = try Parser.init(arena.allocator(), "export {} null;");
    try std.testing.expectError(ParseError.UnexpectedToken, named.parseModule());

    var named_from = try Parser.init(arena.allocator(), "export {} from './m.js' null;");
    try std.testing.expectError(ParseError.UnexpectedToken, named_from.parseModule());

    var namespace_from = try Parser.init(arena.allocator(), "export * as ns from './m.js' null;");
    try std.testing.expectError(ParseError.UnexpectedToken, namespace_from.parseModule());

    var bare_import = try Parser.init(arena.allocator(), "import './m.js' null;");
    try std.testing.expectError(ParseError.UnexpectedToken, bare_import.parseModule());

    var default_expr = try Parser.init(arena.allocator(), "export default 1 null;");
    try std.testing.expectError(ParseError.UnexpectedToken, default_expr.parseModule());
}

test "parser accepts module import export ASI line terminators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var named = try Parser.init(arena.allocator(), "export {}\nexport {}");
    const named_prog = try named.parseModule();
    try std.testing.expectEqual(@as(usize, 2), named_prog.program.len);

    var bare_import = try Parser.init(arena.allocator(), "import './m.js'\nexport {}");
    const import_prog = try bare_import.parseModule();
    try std.testing.expectEqual(@as(usize, 2), import_prog.program.len);
}

test "parser rejects module duplicate lexical and exported names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var lexical = try Parser.init(arena.allocator(), "let x; const x = 0;");
    try std.testing.expectError(ParseError.UnexpectedToken, lexical.parseModule());

    var var_lex = try Parser.init(arena.allocator(), "var f; function f() {}");
    try std.testing.expectError(ParseError.UnexpectedToken, var_lex.parseModule());

    var default_dup = try Parser.init(arena.allocator(), "var x, y; export default x; export { y as default };");
    try std.testing.expectError(ParseError.UnexpectedToken, default_dup.parseModule());

    var star_dup = try Parser.init(arena.allocator(), "var x; export { x as z }; export * as z from './m.js';");
    try std.testing.expectError(ParseError.UnexpectedToken, star_dup.parseModule());
}

test "parser rejects nested vars over module lexical declarations" {
    const invalid = [_][]const u8{
        "let x; { var x; }",
        "export let x; { var x; }",
        "function f(){} { var f; }",
        "import {x} from 'm'; { var x; }",
        "export default function f(){} { var f; }",
    };
    for (invalid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        errdefer std.debug.print("module lexical/var conflict: {s}\n", .{source});
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseModule());
    }

    const valid = [_][]const u8{
        "let x; function f(){ var x; }",
        "export let x; export function f(){ var x; }",
        "import {x} from 'm'; const f = function(){ var x; };",
    };
    for (valid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        _ = try parser.parseModule();
    }
}

test "parser rejects unresolved local exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var missing = try Parser.init(arena.allocator(), "export { unresolvable };");
    try std.testing.expectError(ParseError.UnexpectedToken, missing.parseModule());

    var global = try Parser.init(arena.allocator(), "export { Number };");
    try std.testing.expectError(ParseError.UnexpectedToken, global.parseModule());

    var declared_later = try Parser.init(arena.allocator(), "export { value as renamed }; const value = 1;");
    const prog = try declared_later.parseModule();
    try std.testing.expectEqual(@as(usize, 2), prog.program.len);
}

test "parser rejects forbidden strict import bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var args = try Parser.init(arena.allocator(), "import { x as arguments } from './m.js';");
    try std.testing.expectError(ParseError.UnexpectedToken, args.parseModule());

    var eval_name = try Parser.init(arena.allocator(), "import eval from './m.js';");
    try std.testing.expectError(ParseError.UnexpectedToken, eval_name.parseModule());
}

test "parser validates static import attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var attrs = try Parser.init(arena.allocator(),
        \\import x from './a.js' with {};
        \\import './b.js'
        \\  with { type: "json", "test262": "", };
        \\export * from './c.js' with { if: "" };
    );
    const prog = try attrs.parseModule();
    try std.testing.expectEqual(@as(usize, 3), prog.program.len);

    var dup_import = try Parser.init(arena.allocator(), "import './m.js' with { type: 'json', 'typ\\u0065': '' };");
    try std.testing.expectError(ParseError.UnexpectedToken, dup_import.parseModule());

    var dup_export = try Parser.init(arena.allocator(), "export * from './m.js' with { type: 'json', 'type': '' };");
    try std.testing.expectError(ParseError.UnexpectedToken, dup_export.parseModule());

    var non_string = try Parser.init(arena.allocator(), "import './m.js' with { type: 1 };");
    try std.testing.expectError(ParseError.UnexpectedToken, non_string.parseModule());
}

test "parser accepts source-phase import bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source_import = try Parser.init(arena.allocator(), "import source mod from '<module source>';");
    const source_prog = try source_import.parseModule();
    try std.testing.expectEqualStrings("source", source_prog.program[0].import_decl.entries[0].imported);
    try std.testing.expectEqualStrings("mod", source_prog.program[0].import_decl.entries[0].local);

    var source_named_source = try Parser.init(arena.allocator(), "import source source from '<module source>';");
    const named_source_prog = try source_named_source.parseModule();
    try std.testing.expectEqualStrings("source", named_source_prog.program[0].import_decl.entries[0].local);

    var source_named_from = try Parser.init(arena.allocator(), "import source from from '<module source>';");
    const named_from_prog = try source_named_from.parseModule();
    try std.testing.expectEqualStrings("from", named_from_prog.program[0].import_decl.entries[0].local);

    var default_source = try Parser.init(arena.allocator(), "import source from './m.js';");
    const default_prog = try default_source.parseModule();
    try std.testing.expectEqualStrings("default", default_prog.program[0].import_decl.entries[0].imported);
    try std.testing.expectEqualStrings("source", default_prog.program[0].import_decl.entries[0].local);

    var default_from = try Parser.init(arena.allocator(), "import from from './m.js';");
    const default_from_prog = try default_from.parseModule();
    try std.testing.expectEqualStrings("default", default_from_prog.program[0].import_decl.entries[0].imported);
    try std.testing.expectEqualStrings("from", default_from_prog.program[0].import_decl.entries[0].local);
}

test "parser validates module label early errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var undef_continue = try Parser.init(arena.allocator(), "while (false) { continue undef; }");
    try std.testing.expectError(ParseError.UnexpectedToken, undef_continue.parseModule());

    var duplicate = try Parser.init(arena.allocator(), "label: { label: 0; }");
    try std.testing.expectError(ParseError.UnexpectedToken, duplicate.parseModule());

    var labeled_loop = try Parser.init(arena.allocator(), "label: while (false) { continue label; }");
    const labeled_prog = try labeled_loop.parseModule();
    try std.testing.expectEqual(@as(usize, 1), labeled_prog.program.len);

    var labeled_block_continue = try Parser.init(arena.allocator(), "label: { while (false) { continue label; } }");
    try std.testing.expectError(ParseError.UnexpectedToken, labeled_block_continue.parseModule());
}

test "parser module super queries include exports and preserve own bindings" {
    const invalid = [_][]const u8{
        "super.x;",
        "super();",
        "export default super.x;",
        "export const x = super.x;",
        "export class C extends super.Object {}",
        "const f = () => super.x;",
        "export default () => super.x;",
        "export const {x = super.x} = {};",
    };
    const valid = [_][]const u8{
        "export default class C extends Object { constructor() { super(); } }",
        "export const o = {m() { return super.x; }};",
        "const f = () => class {m() { return super.x; }};",
        "export function f() { return new.target; }",
        "export default function () { return {m() { return super.x; }}; }",
        "export class C extends Object { field = super.x; static { super.name; } }",
    };
    for (invalid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        errdefer std.debug.print("invalid module super: {s}\n", .{source});
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseModule());
    }
    for (valid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        errdefer std.debug.print("valid module super: {s}\n", .{source});
        _ = try parser.parseModule();
    }
}

test "parser query coverage includes labels logical assignments and with" {
    const invalid = [_][]const u8{
        "class C { m() { label: this.#missing; } }",
        "class C { m() { label: { this.#missing; } } }",
        "class C { m() { let x; x ||= this.#missing; } }",
        "class C { m() { let x; x &&= this.#missing; } }",
        "class C { m() { let x; x ??= this.#missing; } }",
        "class C { m() { this.#missing ||= 1; } }",
        "class C { m() { this.#missing &&= 1; } }",
        "class C { m() { this.#missing ??= 1; } }",
        "with ({}) { super.x; }",
        "with ({}) { super(); }",
        "with (super.x) {}",
        "function f() { with ({}) { super.x; } }",
    };
    const valid = [_][]const u8{
        "class C { #x; m() { label: this.#x; } }",
        "class C { #x; m() { this.#x ||= 1; this.#x &&= 2; this.#x ??= 3; } }",
        "class C { #x; m() { let a; a ??= () => this.#x; } }",
        "class C { m() { label: { class D { #x; m() { return this.#x; } } } } }",
    };
    for ([_]bool{ false, true }) |module| {
        for (invalid) |source| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
            const parsed = if (module) parser.parseModule() else parser.parseProgram();
            if (parsed) |program| {
                try std.testing.expectError(ParseError.UnexpectedToken, parser.scanEvalContext(program.program, true, true));
            } else |err| try std.testing.expectEqual(ParseError.UnexpectedToken, err);
        }
        for (valid) |source| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
            const program = if (module) try parser.parseModule() else try parser.parseProgram();
            try parser.scanEvalContext(program.program, true, true);
        }
    }
    // With is permitted only in sloppy code. A method supplies super to its
    // contained arrow even while the arrow resolves ordinary names via with.
    for ([_][]const u8{
        "function f() { with ({x: 1}) { x; } }",
        "({ m() { with ({}) { return () => super.x; } } });",
        "with ({}) { const C = class extends Object { constructor() { super(); } }; }",
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        const program = try parser.parseProgram();
        try parser.scanEvalContext(program.program, true, true);
    }
}

test "parser class queries visit heritage and keys with independent body boundaries" {
    const invalid = [_][]const u8{
        "class C extends super() {}",
        "class C extends super.Object {}",
        "class C { [super()]() {} }",
        "class C { [super.key]() {} }",
        "function f() { return class extends super.Object {}; }",
        "class C extends Object { m() { return class extends super() {}; } }",
        "async function f(x = class extends (await Object) {}) {}",
        "async function f(x = class { [await 0]() {} }) {}",
        "function* f(x = class extends (yield Object) {}) {}",
        "function* f(x = class { [yield 0]() {} }) {}",
        "class C { x = class extends arguments.X {}; }",
        "class C { x = class { [arguments]() {} }; }",
        "class C { static { const D = class { [arguments]() {} }; } }",
        "class C { static { const D = class { static { const f = () => arguments; } }; } }",
    };
    const valid = [_][]const u8{
        "class C extends Object { constructor() { const D = class extends (super(), Object) {}; } }",
        "({ m() { return class { [super.key]() {} }; } });",
        "async function f() { return class extends (await Object) {}; }",
        "function* f() { return class { [yield 0]() {} }; }",
        "function f() { return class extends Object { constructor() { super(); } }; }",
        "class C { static { const D = class extends Object { constructor() { super(); } }; } }",
        "function f() { return class { x = super.value; }; }",
        "function f() { return class { static { super.name; } }; }",
        "class C { static { const D = class extends Object { constructor() { super(); } x = super.value; static { super.name; } }; } }",
        "async function f(x = class { field = async () => await 1; static { const g = async () => await 1; } }) {}",
        "function* f(x = class { *m() { yield 1; } }) {}",
        "function f() { return class { [arguments[0]]() { return arguments[0]; } }; }",
    };
    const Check = struct {
        fn run(allocator: std.mem.Allocator, source: []const u8, module: bool) ParseError!void {
            var parser = try Parser.initWithScratch(allocator, std.testing.allocator, source);
            const program = if (module) try parser.parseModule() else try parser.parseProgram();
            // Context's Script/Module validation additionally enforces the
            // global lexical super boundary after the shared parse.
            try parser.scanEvalContext(program.program, true, true);
        }
    };
    for ([_]bool{ false, true }) |module| {
        for (invalid) |source| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            errdefer std.debug.print("invalid class query: {s}\n", .{source});
            try std.testing.expectError(ParseError.UnexpectedToken, Check.run(arena.allocator(), source, module));
        }
        for (valid) |source| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            errdefer std.debug.print("valid class query: {s}\n", .{source});
            try Check.run(arena.allocator(), source, module);
        }
    }
}

test "parser arrow boundaries keep lexical and suspension queries independent" {
    const invalid = [_][]const u8{
        "class C { static { const f = () => arguments; } }",
        "class C { static { const f = async () => arguments; } }",
        "class C { static { const f = () => () => arguments; } }",
        "class C { static { const f = () => { let [x = arguments] = []; }; } }",
        "class C { static { const f = () => ({[arguments]: 1}); } }",
        "class C { static { const f = () => { try {} catch ([x = arguments]) {} }; } }",
        "class C { static { const f = (x = arguments) => x; } }",
        "class C { static { const f = async (x = () => arguments) => x; } }",
        "class C extends Object { static { const f = () => super(); } }",
        "class C extends Object { static { const f = async () => super(); } }",
        "class C extends Object { static { const f = () => () => super(); } }",
        "class C extends Object { static { const f = async (x = () => super()) => x; } }",
        "class C extends Object { m() { return async (x = () => super()) => x; } }",
        "function f() { return async (x = () => super.name) => x; }",
        "class C { static { const f = async () => await 1; if (false) { for await (const x of []) {} } } }",
        "class C { static { const f = async () => await 1; if (false) { await using x = null; } } }",
        "async function f(x = super(await 1)) {}",
        "function* f(x = super(yield 1)) {}",
        "class C extends Object { constructor(f = async (x = super(await 1)) => x) {} }",
        "function* f() { const g = async (x = yield 1) => x; }",
    };
    const valid = [_][]const u8{
        "class C { static { const f = function () { return arguments; }; } }",
        "class C { static { const f = function () { return () => arguments; }; } }",
        "class C { static { const f = async () => await 1; } }",
        "class C { static { const f = () => async () => await 1; } }",
        "class C { static { const f = async () => { for await (const x of []) {} }; } }",
        "class C { static { const f = async () => { await using x = null; }; } }",
        "class C extends Object { static { const f = () => super.name; } }",
        "class C extends Object { constructor() { const f = () => super(); f(); } }",
        "class C extends Object { constructor(f = async (x = () => super()) => x) {} }",
        "class C extends Object { constructor(f = async (x = () => super.name) => x) {} }",
        "class C extends Object { constructor(f = async (x = super()) => x) {} }",
        "class C extends Object { constructor() { return (async (x = () => () => super()) => x); } }",
        "class C extends Object { async m(x = () => super.name) {} }",
        "class C extends Object { *m(x = () => super.name) {} }",
        "class C { field = async () => await 1; }",
        "async function f(x = async () => await 1) {}",
        "function* f(x = function* () { yield 1; }) {}",
        "class C { static { const f = () => ({arguments: 1}); } }",
    };
    for ([_]bool{ false, true }) |module| {
        for (invalid) |source| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
            errdefer std.debug.print("invalid arrow boundary: {s}\n", .{source});
            try std.testing.expectError(ParseError.UnexpectedToken, if (module) parser.parseModule() else parser.parseProgram());
        }
        for (valid) |source| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
            errdefer std.debug.print("valid arrow boundary: {s}\n", .{source});
            _ = if (module) try parser.parseModule() else try parser.parseProgram();
        }
    }
}

test "parser arrows open fresh label and yield contexts and validate strict parameters" {
    const invalid = [_][]const u8{
        "outer: { (() => { break outer; })(); }",
        "outer: for (;;) { (() => { continue outer; })(); }",
        "outer: { async () => { break outer; }; }",
        "function* g(){ () => { yield 1; }; }",
        "(eval) => { 'use strict'; }",
        "eval => { 'use strict'; }",
        "async (arguments) => { 'use strict'; }",
        "(yield) => { 'use strict'; }",
        "(interface) => { 'use strict'; }",
        "(let) => { 'use strict'; }",
        "static => { 'use strict'; }",
    };
    const valid = [_][]const u8{
        "outer: for (;;) { (() => { outer: for (;;) break outer; })(); break outer; }",
        "function* g(){ () => { var yield; }; }",
        "function* g(){ () => { yield.x; }; }",
        "function* g(){ () => { yield = 1; }; }",
        "function* g(){ var f = () => { return yield; }; }",
    };
    for (invalid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        errdefer std.debug.print("invalid arrow context: {s}\n", .{source});
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    }
    for (valid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        errdefer std.debug.print("valid arrow context: {s}\n", .{source});
        _ = try parser.parseProgram();
    }
}

test "parser restores outer label storage after fresh control-flow boundaries" {
    const sources = [_][]const u8{
        "outer: for (;;) { function f(){ inner: { break inner; } } break outer; }",
        "outer: for (;;) { (() => { inner: { break inner; } }); break outer; }",
        "outer: for (;;) { class C { static { inner: { break inner; } } } break outer; }",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        errdefer std.debug.print("label restoration: {s}\n", .{source});
        _ = try parser.parseProgram();
    }
}

test "parser early errors traverse pattern expressions without crossing function boundaries" {
    const invalid = [_][]const u8{
        "class C { static { if (false) { let [x = await 0] = []; } } }",
        "class C { static { if (false) { let {x = await 0} = {}; } } }",
        "class C { static { if (false) { let {[await 0]: x} = {}; } } }",
        "class C { static { for (let [x = await 0] of []) {} } }",
        "class C { static { for (let {[await 0]: x} in {}) {} } }",
        "class C { static { try {} catch ([x = await 0]) {} } }",
        "class C { static { if (false) { let [...[x = await 0]] = []; } } }",
        "class C { static { if (false) { let {x: [y = await 0]} = {}; } } }",
        "class C { static { if (false) { let x; [x = await 0] = []; } } }",
        "class C { x = () => { let [x = arguments] = []; }; }",
        "class C { x = () => { let {[arguments]: x} = {}; }; }",
        "class C { x = () => { try {} catch ([x = arguments]) {} }; }",
        "class C { x = ([x = arguments]) => x; }",
        "class C { x = () => { for (let [x = arguments] of []) {} }; }",
        "class C { x = () => { let x; [x = arguments] = []; }; }",
        "async function f([x = await 0]) {}",
        "async function f({[await 0]: x}) {}",
        "async function f(...[x = await 0]) {}",
        "function* f([x = yield 0]) {}",
        "function* f({[yield 0]: x}) {}",
        "async function* f([x = await 0]) {}",
        "async function* f([x = yield 0]) {}",
        "const f = async ([x = await 0]) => x;",
        "async function f() { ([x = await 0]) => x; }",
        "function* f() { ([x = yield 0]) => x; }",
        "class C { async m([x = await 0]) {} }",
        "({ *m({[yield 0]: x}) {} });",
        "class C extends Object { m() { let [x = super()] = []; } }",
        "class C extends Object { m([x = super()]) {} }",
        "({ m([x = super()]) {} });",
        "function f([x = super.x]) {}",
        "function f() { try {} catch ({[super.x]: x}) {} }",
        "class C { x = () => `x${(() => { let [x = arguments] = []; })()}`; }",
        "class C { static { if (false) { let [x = (a ||= await 0)] = []; } } }",
        "function* f([x = (a &&= yield 0)]) {}",
        "class C { x = () => { let [x = (a ??= arguments)] = []; }; }",
        "class C extends Object { m([x = (a ||= super())]) {} }",
        "class C { static { if (false) { let [x = import(await 0)] = []; } } }",
        "function* f([x = import(yield 0)]) {}",
        "class C { x = () => { let [x = import(arguments)] = []; }; }",
        "class C extends Object { m([x = import(super())]) {} }",
        "async function f([x = import('x', {with: {type: await 0}})]) {}",
        "class C { static { if (false) { for await (const x of []) {} } } }",
        "class C { static { if (false) { await using x = null; } } }",
        "class C { static { if (false) { for (await using x of []) {} } } }",
    };
    for (invalid) |source| for ([_]bool{ false, true }) |module| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        errdefer std.debug.print("pattern early error: {s}\n", .{source});
        try std.testing.expectError(ParseError.UnexpectedToken, if (module) parser.parseModule() else parser.parseProgram());
    };
    const valid = [_][]const u8{
        "class C { static { async function f() { let [x = await 0] = []; } } }",
        "class C { x = function () { let [x = arguments] = []; }; }",
        "class C { x = function ([x = arguments]) {}; }",
        "class C { x = () => { function f() { try {} catch ([x = arguments]) {} } }; }",
        "class C { static { let [x = 1] = []; let {y = 2} = {}; } }",
        "class C extends Object { constructor([x = super()] = []) {} }",
        "class C extends Object { m([x = super.value]) {} }",
        "({ m([x = super.value]) {} });",
        "async function f([x = async () => await 0]) {}",
        "function* f([x = function* () { yield 0; }]) {}",
        "class C { x = () => { let {arguments: x} = {}; }; }",
        "class C { x = () => { let [x = 'arguments'] = []; }; }",
        "class C { static { let [...[x = 1]] = []; } }",
        "function f([x = (a ||= 1)]) {}",
        "async function f([x = import(async () => await 0)]) {}",
        "class C { x = function () { let [x = import(arguments)] = []; }; }",
        "class C { static { async function f() { for await (const x of []) {} } } }",
        "class C { static { async function f() { await using x = null; } } }",
        "class C { static { const f = async () => { for await (const x of []) {} }; } }",
        "class C { static { const o = { await: 1 }; o.await; } }",
    };
    for (valid) |source| for ([_]bool{ false, true }) |module| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        errdefer std.debug.print("valid pattern boundary: {s}\n", .{source});
        _ = if (module) try parser.parseModule() else try parser.parseProgram();
    };
}

test "parser private deletion rejects optional references and retains diagnostics" {
    const invalid = [_]struct { source: []const u8, name: []const u8 }{
        .{ .source = "class C { #x; m(o) { delete o.#x; } }", .name = "#x" },
        .{ .source = "class C { #x; m(o) { delete ((o.#x)); } }", .name = "#x" },
        .{ .source = "class C { #x; m(o) { delete o?.#x; } }", .name = "#x" },
        .{ .source = "class C { #x; m(o) { delete ((o?.#x)); } }", .name = "#x" },
        .{ .source = "class C { #x; m(o) { delete o?.child.#x; } }", .name = "#x" },
        .{ .source = "class C { #x; m(o) { delete o?.['child'].#x; } }", .name = "#x" },
        .{ .source = "class C { #x; m(o) { delete o?.().#x; } }", .name = "#x" },
        .{ .source = "class C { static #x; static { delete this?.#x; } }", .name = "#x" },
        .{ .source = "class C { #x; m() { delete null?.#x; } }", .name = "#x" },
        .{ .source = "class C { #x; m(o) { return `x${delete o?.#x}`; } }", .name = "#x" },
        .{ .source = "class C { #x; m(o) { return `x\r\n${tag`y\r\n${delete o?.#x}`}`; } }", .name = "#x" },
        .{ .source = "class C { #é; m(o) { delete o?.#é; } }", .name = "#é" },
        .{ .source = "class C { #x; m(o) { delete o?.#\\u0078; } }", .name = "#x" },
    };
    for (invalid) |case| for ([_]bool{ false, true }) |module| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, case.source);
        errdefer std.debug.print("private deletion source: {s}\n", .{case.source});
        try std.testing.expectError(ParseError.UnexpectedToken, if (module) parser.parseModule() else parser.parseProgram());
        try std.testing.expectEqual(DiagnosticReason.private_field_delete, parser.last_error_reason.?);
        try std.testing.expectEqualStrings(case.name, parser.last_error_token.?.text);
        const expected = try std.fmt.allocPrint(arena.allocator(), "Cannot delete private field {s}.", .{case.name});
        try std.testing.expectEqualStrings(expected, try parser.diagnosticMessage(arena.allocator(), parser.last_error_reason.?));
        try std.testing.expectEqualDeep(sourceLocationAt(case.source, std.mem.indexOf(u8, case.source, "delete").?), parser.errorLocation());
    };
    const valid = [_][]const u8{
        "class C { #x() {} m(o) { delete o?.#x(); } }",
        "class C { #x() {} m(o) { delete o.#x?.(); } }",
        "class C { #x; m(o) { delete o?.#x.public; } }",
        "class C { #x; m(o) { delete o?.#x['public']; } }",
        "class C { #x; m(o) { delete (0, o?.#x); } }",
        "class C { #x; m(o) { delete o?.[o.#x]; } }",
        "class C { m(o) { delete o?.['#x']; } }",
        "class C { m(o) { delete o?.public; } }",
    };
    for (valid) |source| for ([_]bool{ false, true }) |module| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        _ = if (module) try parser.parseModule() else try parser.parseProgram();
    };
}

test "parser rejects top-level new target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var top_level = try Parser.init(arena.allocator(), "new.target;");
    try std.testing.expectError(ParseError.UnexpectedToken, top_level.parseModule());

    var script_top_level = try Parser.init(arena.allocator(), "new.target;");
    try std.testing.expectError(ParseError.UnexpectedToken, script_top_level.parseProgram());

    var nested = try Parser.init(arena.allocator(), "function f() { new.target; }");
    const prog = try nested.parseModule();
    try std.testing.expectEqual(@as(usize, 1), prog.program.len);

    var nested_arrow = try Parser.init(arena.allocator(), "function f() { return () => new.target; }");
    const arrow_prog = try nested_arrow.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), arrow_prog.program.len);

    var default_param = try Parser.init(arena.allocator(), "function f(x = new.target) { return x; }");
    const default_prog = try default_param.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), default_prog.program.len);

    var top_level_arrow = try Parser.init(arena.allocator(), "() => new.target;");
    try std.testing.expectError(ParseError.UnexpectedToken, top_level_arrow.parseProgram());

    var static_block = try Parser.init(arena.allocator(), "class C { static { new.target; } }");
    const static_prog = try static_block.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), static_prog.program.len);
}

test "new target invalid identifier diagnostics preserve spelling and source position" {
    const cases = [_]struct { source: []const u8, spelling: []const u8 }{
        .{ .source = "new.other;", .spelling = "other" },
        .{ .source = "new.\\u0074arget;", .spelling = "\\u0074arget" },
        .{ .source = "function f() { new.t\\u0061rget; }", .spelling = "t\\u0061rget" },
        .{ .source = "new.é;", .spelling = "é" },
        .{ .source = "tag`x\r\n${new.\\u0074arget}`", .spelling = "\\u0074arget" },
        .{ .source = "`x\r\n${tag`y\r\n${new.other}`}`", .spelling = "other" },
    };
    for (cases) |case| for ([_]bool{ false, true }) |module| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, case.source);
        try std.testing.expectError(ParseError.UnexpectedToken, if (module) parser.parseModule() else parser.parseProgram());
        try std.testing.expectEqual(DiagnosticReason.new_target_invalid_identifier, parser.last_error_reason.?);
        try std.testing.expectEqualStrings(case.spelling, parser.last_error_token.?.text);
        const expected = try std.fmt.allocPrint(arena.allocator(), "Unexpected identifier '{s}'. \"new.\" can only be followed with target.", .{case.spelling});
        try std.testing.expectEqualStrings(expected, try parser.diagnosticMessage(arena.allocator(), parser.last_error_reason.?));
        const offset = std.mem.indexOf(u8, case.source, "new.").? + "new.".len;
        try std.testing.expectEqualDeep(sourceLocationAt(case.source, offset), parser.errorLocation());
    };
}

test "new target diagnostics retain the rejection context and original source position" {
    const invalid = [_][]const u8{
        "new.target;",
        "\r\n  new.target;",
        "() => new.target;",
        "(x = new.target) => x;",
        "`x${new.target}`",
        "tag`x\r\n${new.target}`",
        "`x\r\n${tag`y\r\n${new.target}`}`",
        "function f() {} new.target;",
        "class C { static {} } new.target;",
    };
    for (invalid) |source| for ([_]bool{ false, true }) |module| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        try std.testing.expectError(ParseError.UnexpectedToken, if (module) parser.parseModule() else parser.parseProgram());
        const reason: DiagnosticReason = if (std.mem.eql(u8, source, "() => new.target;")) .new_target_in_global_arrow else .new_target_outside_function;
        try std.testing.expectEqual(reason, parser.last_error_reason.?);
        try std.testing.expectEqualDeep(sourceLocationAt(source, std.mem.indexOf(u8, source, "new.target").?), parser.errorLocation());
    };
    // The contextual identifier check precedes the permission check: a typo or
    // escaped spelling is not the valid NewTarget grammar in an invalid scope.
    for ([_][]const u8{ "new.other;", "new.\\u0074arget;", "function f() { new.\\u0074arget; }" }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
        try std.testing.expect(parser.last_error_reason != .new_target_outside_function);
    }
    for ([_][]const u8{
        "function f() { return new.target; }",
        "function f(x = new.target) { return () => new.target; }",
        "({ m() { return tag`x${new.target}`; } });",
        "class C { m() { return `x${new.target}`; } static { `x${new.target}`; } }",
        "function f() { return `x${tag`y\r\n${new.target}`}`; }",
    }) |source| for ([_]bool{ false, true }) |module| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        _ = if (module) try parser.parseModule() else try parser.parseProgram();
    };
}

test "parser validates module string export names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var local_string = try Parser.init(arena.allocator(), "export { \"foo\" as \"bar\" }; function foo() {}");
    try std.testing.expectError(ParseError.UnexpectedToken, local_string.parseModule());

    var bad_export = try Parser.init(arena.allocator(), "export { Foo as \"\\uD83D\" }; function Foo() {}");
    try std.testing.expectError(ParseError.UnexpectedToken, bad_export.parseModule());

    var bad_import = try Parser.init(arena.allocator(), "import { \"\\uD83D\" as foo } from './m.js';");
    try std.testing.expectError(ParseError.UnexpectedToken, bad_import.parseModule());

    var good_reexport = try Parser.init(arena.allocator(), "export { \"foo\" as \"bar\" } from './m.js';");
    const prog = try good_reexport.parseModule();
    try std.testing.expectEqual(@as(usize, 1), prog.program.len);
}

test "parser rejects parenthesized destructuring pattern targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var top_arr = try Parser.init(arena.allocator(), "var a, b; ([a, b]) = [1, 2];");
    try std.testing.expectError(ParseError.InvalidAssignmentTarget, top_arr.parseProgram());

    var top_obj = try Parser.init(arena.allocator(), "var a, b; ({a, b}) = { a: 1, b: 2 };");
    try std.testing.expectError(ParseError.InvalidAssignmentTarget, top_obj.parseProgram());

    var nested_arr = try Parser.init(arena.allocator(), "var a, b; ({ a: ([b]) } = { a: [42] });");
    try std.testing.expectError(ParseError.InvalidAssignmentTarget, nested_arr.parseProgram());

    var nested_default = try Parser.init(arena.allocator(), "var a, b; [(a = 5)] = [1];");
    try std.testing.expectError(ParseError.InvalidAssignmentTarget, nested_default.parseProgram());

    var valid = try Parser.init(arena.allocator(), "var a, b; [(a), b] = [1, 2]; ({ a: (a) = 5, b} = { a: 1, b: 2 });");
    const prog = try valid.parseProgram();
    try std.testing.expectEqual(@as(usize, 3), prog.program.len);
}

test "parser retains malformed for-in of and await head diagnostics" {
    const Case = struct {
        source: []const u8,
        reason: DiagnosticReason,
        marker: []const u8,
        message: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "for (async of []) {}", .reason = .unexpected_token, .marker = "of", .message = "Unexpected identifier 'of'" },
        .{ .source = "async function f() { for await (x in y) {} }", .reason = .for_await_in, .marker = "in y", .message = "Unexpected keyword 'in'. Expected 'of' in for-await syntax." },
        .{ .source = "for (using x in y) {}", .reason = .using_for_in, .marker = "x in", .message = "Unexpected identifier 'x'. Expected either 'in' or 'of' in enumeration syntax." },
        .{ .source = "async function f() { for (await using x in y) {} }", .reason = .using_for_in, .marker = "x in", .message = "Unexpected identifier 'x'. Expected either 'in' or 'of' in enumeration syntax." },
        .{ .source = "async function f() { for await (await using x in y) {} }", .reason = .using_for_in, .marker = "x in", .message = "Unexpected identifier 'x'. Expected either 'in' or 'of' in enumeration syntax." },
        .{ .source = "for (var x = 0 of y) {}", .reason = .for_of_initializer, .marker = "=", .message = "Cannot assign to the loop variable inside a for-of loop header." },
        .{ .source = "async function f() { for await (;;) {} }", .reason = .for_await_semicolon, .marker = ";", .message = "Unexpected token ';'. Unexpected a ';' in for-await-of header." },
        .{ .source = "async function f() { for await (let x;;) {} }", .reason = .for_await_semicolon, .marker = ";", .message = "Unexpected token ';'. Unexpected a ';' in for-await-of header." },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), case.source);
        try std.testing.expectError(case.reason.parseError(), parser.parseProgram());
        try std.testing.expectEqual(case.reason, parser.last_error_reason.?);
        try std.testing.expectEqual(std.mem.indexOf(u8, case.source, case.marker).?, parser.errorLocation().byte_offset);
        try std.testing.expectEqualStrings(case.message, try parser.diagnosticMessage(arena.allocator(), case.reason));
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var valid = try Parser.init(arena.allocator(), "async function* f() { for await (a of b) ; }");
    const prog = try valid.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), prog.program.len);
}

test "parser validates class private name uses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var method_use = try Parser.init(arena.allocator(), "class C { f() { this.#x; } }");
    try std.testing.expectError(ParseError.UnexpectedToken, method_use.parseModule());

    var field_use = try Parser.init(arena.allocator(), "class C { y = this.#x; }");
    try std.testing.expectError(ParseError.UnexpectedToken, field_use.parseModule());

    var declared = try Parser.init(arena.allocator(), "class C { #x; f() { this.#x; } }");
    const prog = try declared.parseModule();
    try std.testing.expectEqual(@as(usize, 1), prog.program.len);

    var nested = try Parser.init(arena.allocator(),
        \\class Outer {
        \\  #x;
        \\  f() { return class Inner { g() { return this.#x; } } }
        \\}
    );
    const nested_prog = try nested.parseModule();
    try std.testing.expectEqual(@as(usize, 1), nested_prog.program.len);
}

test "parser lexical and var early errors span nested block scopes" {
    // #928 baseline, recorded before any change to the subtree var scan in
    // `checkLexicalDupes`. Every case was confirmed against another engine
    // first, so this pins observed behaviour rather than a reading of the
    // spec. A `var` conflicts with the LexicallyDeclaredNames of every block
    // enclosing it up to the nearest function boundary -- which is exactly the
    // set a single scoped map with rollback would hold at that point.
    const invalid = [_][]const u8{
        "{ var x; let x; }",
        // `var` hoists out of nested blocks, so it reaches the outer `let`.
        "{ let x; { var x; } }",
        "{ let x; { { var x; } } }",
        "function f() { let x; { var x; } }",
        // The whole switch is one lexical scope spanning every case.
        "switch (0) { case 1: let x; break; case 2: var x; }",
        "{ let x; try { var x; } catch (e) {} }",
        "{ let x; try {} catch (e) { var x; } }",
        "{ let x; for (var x of []) ; }",
        "{ const x = 1; { var x; } }",
        // A label is not a scope boundary for this early error.
        "{ let x; lbl: { var x; } }",
    };
    for (invalid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    }

    const valid = [_][]const u8{
        // Sibling scopes never see each other's names.
        "{ let x; } { var x; }",
        "{ { var x; } { let x; } }",
        // A function or arrow body stops `var` from hoisting further out.
        "{ let x; function f() { var x; } }",
        "{ let x; (() => { var x; }); }",
        // Shadowing, and a `var` that is declared OUTSIDE the block holding
        // the lexical name -- the asymmetry a naive scan gets wrong.
        "{ let x; { let x; } }",
        "{ var x; { let x; } }",
        "{ let a; { let b; { var v; } } }",
    };
    for (valid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        _ = try parser.parseProgram();
    }
}

test "parser checks duplicate block functions with their owning strictness" {
    // #930 family 4. These bodies have already restored the enclosing parser
    // mode when the lexical walk runs, so the FunctionNode's recorded mode is
    // the authority for the Annex B.3.3 duplicate-function allowance.
    const invalid = [_][]const u8{
        "function g(){ 'use strict'; { function f(){} function f(){} } }",
        "function g(){ 'use strict'; switch (0) { case 0: function f(){} case 1: function f(){} } }",
        "class C { m(){ { function f(){} function f(){} } } }",
        "class C { m(){ switch (0) { case 0: function f(){} case 1: function f(){} } } }",
        // Strictness is inherited by a nested declaration even without its own
        // directive prologue.
        "function outer(){ 'use strict'; function inner(){ { function f(){} function f(){} } } }",
    };
    for (invalid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    }

    const valid = [_][]const u8{
        "function g(){ { function f(){} function f(){} } }",
        "function g(){ switch (0) { case 0: function f(){} case 1: function f(){} } }",
        // Checking a strict sibling must restore sloppy mode for the next body.
        "function strict(){ 'use strict'; { function f(){} } } function sloppy(){ { function f(){} function f(){} } }",
    };
    for (valid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        _ = try parser.parseProgram();
    }
}

test "parser includes labelled functions in their statement-list declarations" {
    // #930 family 3. Annex B.3.2 permits a sloppy LabelledItem ending in a
    // FunctionDeclaration. Its name is var-scoped in a Script/FunctionBody and
    // lexical in a Block/CaseBlock, just like an unlabelled declaration in that
    // statement list. Peeling labels must not make the declaration invisible.
    const invalid = [_][]const u8{
        "let g; lbl: function g(){}",
        "function g(){ let f; lbl: function f(){} }",
        "{ let f; lbl: function f(){} }",
        "{ var f; lbl: function f(){} }",
        "{ class f{} lbl: function f(){} }",
        "{ let f; outer: inner: function f(){} }",
        "switch (0) { case 0: let f; case 1: lbl: function f(){} }",
        "try {} catch ([f]) { lbl: function f(){} }",
    };
    for (invalid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    }

    const valid = [_][]const u8{
        "var g; lbl: function g(){}",
        "function g(){ var f; lbl: function f(){} }",
        "{ function f(){} lbl: function f(){} }",
        "{ outer: inner: function f(){} function f(){} }",
        "switch (0) { case 0: function f(){} case 1: lbl: function f(){} }",
    };
    for (valid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        _ = try parser.parseProgram();
    }
}

test "parser lexical and var early errors traverse with statement bodies" {
    // #930 family 2. A with environment changes runtime name resolution but is
    // not a declaration boundary, so its body contributes the same lexical and
    // var names as any other statement body.
    const invalid = [_][]const u8{
        "{ let x; with ({}) { var x; } }",
        "with ({}) { let y; var y; }",
        "try {} catch ([e]) { with ({}) { var e; } }",
        "{ let x; with ({}) if (1) var x; }",
        // Exercises collectVarNames, used by the lexical for-head check before
        // the shared post-parse scope walk runs.
        "for (let x;;) { with ({}) { var x; } break; }",
    };
    for (invalid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    }

    const valid = [_][]const u8{
        "{ let x; with ({}) { function f(){ var x; } } }",
        "with ({}) { let y; } var y;",
        "try {} catch ([e]) { with ({}) { function f(){ var e; } } }",
    };
    for (valid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        _ = try parser.parseProgram();
    }
}

fn parseForNestingTest(allocator: std.mem.Allocator, source: []const u8) ParseError!void {
    var parser = try Parser.init(allocator, source);
    _ = try parser.parseProgram();
}

fn nestedSource(allocator: std.mem.Allocator, shape: NestingShape, depth: usize) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(allocator, shape.prefix);
    for (0..depth) |level| {
        // Labels must differ at every level: a nested duplicate is itself an
        // early error, which would hide what this test measures.
        if (shape.numbered_label) {
            try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "l{d}: ", .{level}));
        } else try out.appendSlice(allocator, shape.open);
    }
    try out.appendSlice(allocator, shape.core);
    for (0..depth) |_| try out.appendSlice(allocator, shape.close);
    try out.appendSlice(allocator, shape.suffix);
    return out.items;
}

const NestingShape = struct {
    prefix: []const u8 = "",
    open: []const u8 = "",
    core: []const u8,
    close: []const u8 = "",
    suffix: []const u8 = "",
    numbered_label: bool = false,
};

test "parser refuses source nested deeper than the stack allows" {
    // #936: each shape below followed a recursion that segfaulted the process
    // once nested deeply enough. The guard probes the real stack pointer, so a
    // depth far past any stack is refused as `error.StackExhausted`, while the
    // same shape at an ordinary depth still parses: the limit is the stack,
    // not a fixed nesting count.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shapes = [_]NestingShape{
        .{ .open = "(", .core = "1", .close = ")" }, // expressions via parseAssignment
        .{ .open = "[", .core = "1", .close = "]" }, // array literals
        .{ .open = "({a:", .core = "1", .close = "})" }, // object literals
        .{ .open = "!", .core = "1" }, // parseUnaryOperand
        .{ .open = "delete ", .core = "x" }, // parseUnaryOperand through `delete`
        .{ .prefix = "async function f() { ", .open = "await ", .core = "1", .suffix = " }" }, // and through `await`
        .{ .open = "2**", .core = "2" }, // parseBinaryOperand's right-associative loop
        .{ .open = "new ", .core = "X" }, // parseNew
        .{ .open = "x=>", .core = "1" }, // arrow bodies
        .{ .prefix = "x = ", .open = "class extends ", .core = "Object", .close = "{}" }, // class heritage
        .{ .open = "{", .core = "", .close = "}" }, // parseStatement through blocks
        .{ .open = "if (1) ", .core = ";" }, // statements without blocks
        .{ .core = ";", .numbered_label = true }, // labelled statements
        .{ .prefix = "var ", .open = "[", .core = "x", .close = "]", .suffix = " = [];" }, // binding patterns
        .{ .open = "[", .core = "x", .close = "]", .suffix = " = [];" }, // assignment patterns via litToPattern
        .{ .open = "`${", .core = "1", .close = "}`" }, // streamed template expressions
        // A for-in/of head that fails as a target is retried as a classic head;
        // exhaustion inside it must propagate, not trigger the retry.
        .{ .prefix = "async function f() { for await (a[", .open = "(", .core = "1", .close = ")", .suffix = "] of []); }" },
        .{ .open = "for (a[function () { ", .core = "0;", .close = " }()] of []);" },
    };
    for (shapes) |shape| {
        const shallow = try nestedSource(a, shape, 64);
        parseForNestingTest(a, shallow) catch |err| {
            std.debug.print("64-deep shape `{s}{s}` should parse, got {s}\n", .{ shape.prefix, shape.open, @errorName(err) });
            return err;
        };
        const deep = try nestedSource(a, shape, 200_000);
        try std.testing.expectError(error.StackExhausted, parseForNestingTest(a, deep));
    }
}

test "parser destructuring catch parameters reject a same-named var" {
    // #931. A CatchParameter's BoundNames must not occur in its Block's
    // VarDeclaredNames; Annex B.3.4 lifts that only for a plain
    // BindingIdentifier. Every case was confirmed against another engine first.
    const invalid = [_][]const u8{
        "try {} catch ([e]) { var e; }",
        "try {} catch ({e}) { var e; }",
        "try {} catch ({a: e}) { var e; }",
        "try {} catch ([e = 1]) { var e; }",
        "try {} catch ([...e]) { var e; }",
        "try {} catch ([e, f]) { var f; }",
        // The var still counts from a nested block, a statement position or a loop head.
        "try {} catch ([e]) { { var e; } }",
        "try {} catch ([e]) { if (1) var e; }",
        "try {} catch ([e]) { lbl: var e; }",
        "try {} catch ([e]) { switch (0) { case 0: var e; } }",
        "try {} catch ([e]) { for (var e;;) break; }",
        "try {} catch ([e]) { for (var e in {}); }",
        "try {} catch ([e]) { for (var e of []); }",
        // An inner plain catch allows its own `var e`, but that var still hoists
        // into the outer destructuring parameter's block.
        "try {} catch ([e]) { try {} catch (e) { var e; } }",
        "try {} catch ([e]) { try {} catch ([x]) { var e; } }",
        "class C { static { try {} catch ([e]) { var e; } } }",
    };
    for (invalid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    }

    const valid = [_][]const u8{
        // The Annex B relaxation for a plain identifier, in every var form.
        "try {} catch (e) { var e; }",
        "try {} catch (e) { for (var e;;) break; }",
        "try {} catch (e) { for (var e in {}); }",
        "try {} catch (e) { for (var e of []); }",
        // A var inside a nested function does not hoist into the catch block.
        "try {} catch ([e]) { function f(){ var e; } }",
        "try {} catch ([e]) { (function(){ var e; }); }",
        // The parameter is scoped to the catch block alone.
        "try {} catch ([e]) {} var e;",
        "try {} catch ([e]) {} finally { var e; }",
        "try {} catch ([e]) { var x; }",
    };
    for (valid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        _ = try parser.parseProgram();
    }
    // Deliberately absent: `(function(){ try {} catch ([e]) { var e; } })();`
    // is also a SyntaxError, but this check runs in the lexical walk, which does
    // not yet reach function bodies nested in expressions. That reach gap is
    // shared by every lexical/var early error and is tracked as #930.
}

test "parser class static blocks scope top-level functions as var declarations" {
    // #929. A ClassStaticBlockStatementList takes its names from
    // TopLevelLexicallyDeclaredNames / TopLevelVarDeclaredNames, exactly as a
    // FunctionBody does, so its top-level function declarations are VAR-scoped.
    // The parser used to check it as an ordinary block, where those functions
    // are lexical and -- under the block's forced strictness -- rigid, and
    // rejected valid code. test262 only asserts the error direction for static
    // blocks, so this test is the only gate on the valid direction. Every case
    // was confirmed against another engine before being written down.
    const valid = [_][]const u8{
        "class C { static { var f; function f(){} } }",
        "class C { static { function f(){} function f(){} } }",
        // All hoistable declaration kinds are var-scoped here, not just plain functions.
        "class C { static { async function f(){} async function f(){} } }",
        "class C { static { function* f(){} async function* f(){} } }",
        // A var hoisting out of a nested block, or bound by a pattern.
        "class C { static { function f(){} { var f; } } }",
        "class C { static { var {f} = {}; function f(){} } }",
        // Each static block, including one in a nested class, is its own var scope.
        "class C { static { function f(){} } static { var f; function f(){} } }",
        "class C { static { let f; class D { static { var f; function f(){} } } } }",
    };
    for (valid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        _ = try parser.parseProgram();
    }

    const invalid = [_][]const u8{
        // A lexical declaration still collides with any var-scoped name.
        "class C { static { let f; var f; } }",
        "class C { static { let f; function f(){} } }",
        "class C { static { function f(){} let f; } }",
        "class C { static { const f = 0; async function f(){} } }",
        "class C { static { function f(){} class f {} } }",
        "class C { static { let f; if (1) { var f; } else {} } }",
        // Only the static block's TOP LEVEL changed: a function in a block nested
        // inside it is still lexical, and still rigid under strict mode.
        "class C { static { { function f(){} function f(){} } } }",
        "class C { static { { async function f(){} function f(){} } } }",
        "class C { static { { function f(){} var f; } } }",
    };
    for (invalid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    }
}

test "parser private name scoping isolates siblings and descendants" {
    // #926 baseline, recorded before any change to the inherited-name copy in
    // `checkPrivateNameUses`. Every case here was first confirmed against
    // JavaScriptCore, so a scoped fix that keeps them passing keeps the
    // observable semantics: a nested class sees its ancestors' names, shadows
    // them by redeclaring, and never sees a sibling's or a descendant's.
    const valid = [_][]const u8{
        "class Outer { #x; a = class { m() { return this.#x; } }; }",
        // Redeclaring shadows rather than collides, and the sibling that does
        // not redeclare still binds the outer name -- the two inner classes
        // must not end up sharing one mutable set.
        "class Outer { #x; a = class { #x; m() { return this.#x; } }; b = class { m() { return this.#x; } }; }",
        // Every level of a chain sees all of its ancestors, by use and by brand.
        "class A { #a; m() { return class B { #b; n() { return class C { p(o) { return this.#a + this.#b + (#a in o); } }; } }; } }",
        "class Outer { #x; a = class { m(o) { return #x in o; } }; }",
        // An inner class's heritage is checked in the enclosing environment,
        // which already holds the outer names.
        "class Outer { #x; m() { return class extends (this.#x) {}; } }",
        // The shadowed outer name must still resolve in a LATER member, after
        // the shadowing class has closed. An undo log that removed the name
        // unconditionally rather than only when it inserted would break here.
        "class A { #x; m() { class B { #x; } } n() { return this.#x; } }",
        // A legal accessor pair declares one name across two members, so an
        // undo log must record it once, not twice.
        "class C { get #x() { return 1; } set #x(v) {} m() { return this.#x; } }",
        "class Outer { #x; m() { class I { get #x() {} set #x(v) {} } } n() { return this.#x; } }",
        // Reached through static blocks, a template substitution and a default
        // parameter value -- separate traversal arms into a nested class.
        "class Outer { #x; static { const a = class { m() { return this.#x; } }; } static { const b = class { m() { return this.#x; } }; } }",
        "class Outer { #x; a = class { m() { return `${this.#x}`; } }; }",
        "class Outer { #x; m(f = class { g() { return this.#x; } }) { return f; } }",
    };
    for (valid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        const program = try parser.parseProgram();
        try std.testing.expectEqual(@as(usize, 1), program.program.len);
    }

    const invalid = [_][]const u8{
        // A name declared in an earlier sibling is out of scope in a later one.
        "class Outer { a = class { #y; }; b = class { m() { return this.#y; } }; }",
        "class Outer { a = class { #y; }; b = class { m(o) { return #y in o; } }; }",
        // A nested class's own names do not leak back out to the enclosing one.
        "class Outer { a = class { #y; }; m() { return this.#y; } }",
        // A class's own names are not in scope for its own heritage clause:
        // the extends expression is checked before they are added.
        "class C extends class { x = this.#foo; } { #foo; }",
        "class A { m() { return class B { #b; }; } n(o) { return #b in o; } }",
        // The same reach-in arms as the valid block above, but with nothing
        // declaring the name -- each must still be rejected.
        "class Outer { m() { class I { get #x() {} set #x(v) {} } } n() { return this.#x; } }",
        "class Outer { static { const a = class { #y; }; } static { const b = class { m() { return this.#y; } }; } }",
        "class Outer { a = class { #y; }; b = class { m() { return `${this.#y}`; } }; }",
        "class Outer { m(f = class { #y; }) { return this.#y; } }",
    };
    for (invalid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    }
}

test "parser private constructor members preserve lexical name validation" {
    const valid = [_][]const u8{
        "class C { #Ctor; make() { return new this.#Ctor(); } }",
        "class C { #Ctor; make() { return new this.#Ctor; } }",
        "class C { #holder; make() { return new this.#holder.Ctor(7).value; } }",
        "class C { get #Ctor() {} make(value = new this.#Ctor()) {} }",
        "class C { #Ctor; make(value = new (this.#Ctor)()) {} }",
        "class C { #Ctor; make() { return class D { run(c) { return new c.#Ctor(); } }; } }",
    };
    const Probe = struct {
        fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const backing: *std.mem.Allocator = @ptrCast(@alignCast(raw));
            return backing.rawAlloc(len, alignment, ra);
        }

        fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const backing: *std.mem.Allocator = @ptrCast(@alignCast(raw));
            backing.rawFree(memory, alignment, ra);
        }

        fn run(allocator: std.mem.Allocator, source: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            var parser = try Parser.init(arena.allocator(), source);
            // Freeze the keyed parse input for deterministic allocation replay.
            parser.secure_hash_state.context = .{ .seed = 0x807_7061_7273_65 };
            const program = try parser.parseProgram();
            try std.testing.expectEqual(@as(usize, 1), program.program.len);
        }
    };
    var backing = std.testing.allocator;
    // Arena growth must allocate during replay: whether the host can resize a
    // particular mapping in place is address-dependent, not parser behavior.
    const non_resizing: std.mem.Allocator = .{ .ptr = &backing, .vtable = &.{
        .alloc = Probe.alloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = Probe.free,
    } };
    for (valid) |source| try std.testing.checkAllAllocationFailures(non_resizing, Probe.run, .{source});
    const invalid = [_][]const u8{
        "new value.#Ctor()",
        "class C { make() { return new this.#Ctor(); } }",
        "class C { #Ctor; make() { return new this?.#Ctor(); } }",
        "class C { #Ctor; make() { return new this.#Ctor?.(); } }",
        "class C extends Base { #Ctor; make() { return new super.#Ctor(); } }",
    };
    for (invalid) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    }
}

test "private eval contexts validate exact enclosing names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var names = PrivateNameMap.init(0x5052_4956_4154_4501);
    try names.put(allocator, "#outer", .{ .storage_key = "#outer\x001", .kind = .field });
    const cases = [_]struct { source: []const u8, valid: bool }{
        .{ .source = "this.#outer", .valid = true },
        .{ .source = "() => this.#outer", .valid = true },
        .{ .source = "class C { #inner; read(obj) { return obj.#outer + this.#inner; } }", .valid = true },
        .{ .source = "`value: ${this.#outer}`", .valid = true },
        .{ .source = "this.#missing", .valid = false },
        .{ .source = "() => this.#missing", .valid = false },
        .{ .source = "class C { #inner; read(obj) { return obj.#missing; } }", .valid = false },
        .{ .source = "`value: ${this.#missing}`", .valid = false },
    };
    for (cases) |case| {
        var parser = try Parser.init(allocator, case.source);
        parser.in_class = true;
        parser.eval_private_names = &names;
        if (case.valid)
            _ = try parser.parseProgram()
        else
            try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    }
}

test "undeclared private diagnostics retain decoded names and exact offsets" {
    const Case = struct { source: []const u8, name: []const u8, marker: []const u8 };
    const cases = [_]Case{
        .{ .source = "class C { m(){ return this.#missing; } }", .name = "#missing", .marker = "#missing" },
        .{ .source = "class C { m(o){ return #missing in o; } }", .name = "#missing", .marker = "#missing" },
        .{ .source = "({}).#missing", .name = "#missing", .marker = "#missing" },
        .{ .source = "class C { m(){ return this.#\\u0078; } }", .name = "#x", .marker = "#\\u0078" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), case.source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
        try std.testing.expectEqual(DiagnosticReason.undeclared_private_name, parser.last_error_reason.?);
        try std.testing.expectEqualStrings(case.name, parser.last_error_token.?.text);
        try std.testing.expectEqual(std.mem.indexOf(u8, case.source, case.marker).?, parser.errorLocation().byte_offset);
        const expected = try std.fmt.allocPrint(arena.allocator(), "Cannot reference undeclared private names: \"{s}\"", .{case.name});
        try std.testing.expectEqualStrings(expected, try parser.diagnosticMessage(arena.allocator(), parser.last_error_reason.?));
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bare = try Parser.init(arena.allocator(), "#missing;");
    try std.testing.expectError(ParseError.UnexpectedToken, bare.parseProgram());
    try std.testing.expectEqual(DiagnosticReason.unexpected_token, bare.last_error_reason.?);
    try std.testing.expectEqualStrings("#missing", bare.last_error_token.?.text);
    try std.testing.expectEqualStrings("Unexpected token '#missing'", try bare.diagnosticMessage(arena.allocator(), bare.last_error_reason.?));
}

test "invalid super diagnostics retain context and exact token offsets" {
    const Case = struct {
        source: []const u8,
        reason: DiagnosticReason,
        marker: []const u8,
        global_scan: bool = false,
    };
    const cases = [_]Case{
        .{ .source = "super()", .reason = .invalid_super, .marker = "super", .global_scan = true },
        .{ .source = "super.x", .reason = .invalid_super, .marker = "super", .global_scan = true },
        .{ .source = "class C { m(){ super(); } }", .reason = .invalid_super, .marker = "super" },
        .{ .source = "class C { static { super(); } }", .reason = .invalid_super, .marker = "super" },
        .{ .source = "class C { x = super(); }", .reason = .super_call_field_initializer, .marker = "super(" },
        .{ .source = "class C { static x = (() => super())(); }", .reason = .super_call_field_initializer, .marker = "super(" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), case.source);
        if (case.global_scan) {
            const program = try parser.parseProgram();
            try std.testing.expectError(ParseError.UnexpectedToken, parser.scanEvalContext(program.program, true, true));
        } else {
            try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
        }
        try std.testing.expectEqual(case.reason, parser.last_error_reason.?);
        const marker_offset = std.mem.indexOf(u8, case.source, case.marker).?;
        const expected_offset = marker_offset + if (case.reason == .super_call_field_initializer) "super".len else 0;
        try std.testing.expectEqual(expected_offset, parser.errorLocation().byte_offset);
        try std.testing.expectEqualStrings(case.reason.message(), try parser.diagnosticMessage(arena.allocator(), case.reason));
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var valid = try Parser.init(arena.allocator(), "class B {} class C extends B { constructor(){ super(); } m(){ return super.x; } }");
    _ = try valid.parseProgram();
}

test "static block await diagnostics preserve syntactic position" {
    const Case = struct { source: []const u8, reason: DiagnosticReason };
    const cases = [_]Case{
        .{ .source = "class C { static { await 1; } }", .reason = .static_block_await_statement },
        .{ .source = "class C { static { { await 1; } } }", .reason = .static_block_await_statement },
        .{ .source = "class C { static { (await 1); } }", .reason = .static_block_await_reference },
        .{ .source = "class C { static { let x = await 1; } }", .reason = .static_block_await_reference },
        .{ .source = "class C { static { if (true) await 1; } }", .reason = .static_block_await_reference },
        .{ .source = "class C { static { for await (const x of []) {} } }", .reason = .static_block_for_await },
        .{ .source = "class C { static { await using x = null; } }", .reason = .static_block_await_statement },
        .{ .source = "class C { static { for (await using x of []) {} } }", .reason = .static_block_await_reference },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.init(arena.allocator(), case.source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
        try std.testing.expectEqual(case.reason, parser.last_error_reason.?);
        try std.testing.expectEqual(std.mem.indexOf(u8, case.source, "await").?, parser.errorLocation().byte_offset);
        try std.testing.expectEqualStrings(case.reason.message(), try parser.diagnosticMessage(arena.allocator(), case.reason));
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var valid = try Parser.init(arena.allocator(), "class C { static { const f = async () => await 1; } }");
    _ = try valid.parseProgram();
}

test "parser enforces private name declaration collisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const accepted = [_][]const u8{
        "class C { get #x() { return 1; } set #x(value) {} }",
        "class C { static set #x(value) {} static get #x() { return 1; } }",
        "class C { #field; #method() {} get #value() {} set #value(value) {} }",
    };
    for (accepted) |source| {
        var parser = try Parser.init(arena.allocator(), source);
        _ = try parser.parseProgram();
    }

    const rejected = [_][]const u8{
        "class C { #x; #x; }",
        "class C { #x; #x() {} }",
        "class C { get #x() {} get #x() {} }",
        "class C { set #x(value) {} set #x(value) {} }",
        "class C { get #x() {} set #x(value) {} get #x() {} }",
        "class C { static get #x() {} set #x(value) {} }",
        "class C { #constructor; }",
    };
    for (rejected) |source| {
        var parser = try Parser.init(arena.allocator(), source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
    }
}

test "class diagnostic reasons retain declaration offsets and template provenance" {
    const Case = struct { source: []const u8, reason: DiagnosticReason, declaration: []const u8 };
    const cases = [_]Case{
        .{ .source = "class C { constructor; }", .reason = .constructor_field, .declaration = "constructor" },
        .{ .source = "class C { static 'constructor'; }", .reason = .constructor_field, .declaration = "static" },
        .{ .source = "class C { #constructor; }", .reason = .private_constructor_field, .declaration = "#constructor" },
        .{ .source = "class C { #constructor() {} }", .reason = .private_constructor_method, .declaration = "#constructor" },
        .{ .source = "class C { get #constructor() {} }", .reason = .private_constructor_accessor, .declaration = "get #constructor" },
        .{ .source = "class C { constructor() {}\n  constructor() {} }", .reason = .duplicate_constructor, .declaration = "constructor" },
        .{ .source = "class C { static prototype; }", .reason = .static_prototype_field, .declaration = "static" },
        .{ .source = "class C { static prototype() {} }", .reason = .static_prototype_method, .declaration = "static" },
        .{ .source = "class C { get constructor() {} }", .reason = .constructor_accessor, .declaration = "get constructor" },
        .{ .source = "class C { async constructor() {} }", .reason = .constructor_async, .declaration = "async constructor" },
        .{ .source = "class C { *constructor() {} }", .reason = .constructor_generator, .declaration = "*constructor" },
        .{ .source = "class C { #x() {} #x; }", .reason = .duplicate_private_field, .declaration = "#x" },
        .{ .source = "class C { #x; #x() {} }", .reason = .duplicate_private_method, .declaration = "#x" },
        .{ .source = "class C { get #x() {} get #x() {} }", .reason = .duplicate_private_accessor, .declaration = "get #x" },
        .{ .source = "class C { set #x(v) {} static get #x() {} }", .reason = .static_getter_instance_setter, .declaration = "static" },
        .{ .source = "class C { get #x() {} static set #x(v) {} }", .reason = .static_setter_instance_getter, .declaration = "static" },
        .{ .source = "class C { static set #x(v) {} get #x() {} }", .reason = .instance_getter_static_setter, .declaration = "get #x" },
        .{ .source = "class C { static get #x() {} set #x(v) {} }", .reason = .instance_setter_static_getter, .declaration = "set #x" },
        .{ .source = "class C { get #x() {} set #x(v) {} #x; }", .reason = .duplicate_private_field, .declaration = "#x" },
        .{ .source = "`a\r\n${class C { constructor; }}`", .reason = .constructor_field, .declaration = "constructor" },
        .{ .source = "tag`a\r\n${class C { #constructor; }}`", .reason = .private_constructor_field, .declaration = "#constructor" },
        .{ .source = "`a${tag`b\r\n${class C { constructor; }}`}`", .reason = .constructor_field, .declaration = "constructor" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, case.source);
        try std.testing.expectError(ParseError.UnexpectedToken, parser.parseProgram());
        try std.testing.expectEqual(case.reason, parser.last_error_reason.?);
        const offset = std.mem.lastIndexOf(u8, case.source, case.declaration).?;
        try std.testing.expectEqualDeep(sourceLocationAt(case.source, offset), parser.errorLocation());
    }
}

test "assignment diagnostic reasons preserve error tags and operator offsets" {
    const Case = struct { source: []const u8, reason: DiagnosticReason, marker: []const u8, err: ParseError = ParseError.InvalidAssignmentTarget };
    const cases = [_]Case{
        .{ .source = "1 = 2", .reason = .invalid_assignment, .marker = "=" },
        .{ .source = "1 **= 2", .reason = .invalid_assignment, .marker = "**=" },
        .{ .source = "1 ??= 2", .reason = .invalid_assignment, .marker = "??=" },
        .{ .source = "[1] = []", .reason = .invalid_destructuring_assignment, .marker = "[1]" },
        .{ .source = "({a: 1} = {})", .reason = .invalid_destructuring_assignment, .marker = "{a" },
        .{ .source = "++1", .reason = .invalid_prefix_increment, .marker = "++" },
        .{ .source = "--1", .reason = .invalid_prefix_decrement, .marker = "--" },
        .{ .source = "(1)++", .reason = .invalid_postfix_increment, .marker = "++" },
        .{ .source = "(1)--", .reason = .invalid_postfix_decrement, .marker = "--" },
        .{ .source = "`a\r\n${++1}`", .reason = .invalid_prefix_increment, .marker = "++" },
        .{ .source = "if (true) { return; }", .reason = .return_outside_function, .marker = "return", .err = ParseError.UnexpectedToken },
        .{ .source = "'use strict'; eval = 1", .reason = .strict_modify_eval, .marker = "eval", .err = ParseError.UnexpectedToken },
        .{ .source = "'use strict'; ++arguments", .reason = .strict_modify_arguments, .marker = "arguments", .err = ParseError.UnexpectedToken },
        .{ .source = "'use strict'; eval++", .reason = .strict_postfix_eval, .marker = "eval", .err = ParseError.UnexpectedToken },
        .{ .source = "'use strict'; arguments--", .reason = .strict_postfix_arguments, .marker = "arguments", .err = ParseError.UnexpectedToken },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, case.source);
        try std.testing.expectError(case.err, parser.parseProgram());
        try std.testing.expectEqual(case.reason, parser.last_error_reason.?);
        try std.testing.expectEqual(std.mem.indexOf(u8, case.source, case.marker).?, parser.errorLocation().byte_offset);
    }
}

test "accessor parameter grammar retains the actual offending token" {
    const Case = struct { source: []const u8, reason: DiagnosticReason, marker: []const u8 };
    const cases = [_]Case{
        .{ .source = "({get x(a) { return ++1; }})", .reason = .getter_parameters, .marker = "a)" },
        .{ .source = "({get x({a}) {}})", .reason = .getter_parameters, .marker = "{a}" },
        .{ .source = "({get x(\\u0061) {}})", .reason = .getter_parameters, .marker = "\\u0061" },
        .{ .source = "({set x() {}})", .reason = .setter_parameters, .marker = ")" },
        .{ .source = "({set x(a,) {}})", .reason = .setter_parameters, .marker = "," },
        .{ .source = "({set x({a},) {}})", .reason = .setter_parameters, .marker = "," },
        .{ .source = "class C { static set x(a,b) {} }", .reason = .setter_parameters, .marker = "," },
        .{ .source = "class C { set #x(...a) {} }", .reason = .setter_parameter_pattern, .marker = "..." },
        .{ .source = "`a\r\n${({get x(é) {}})}`", .reason = .getter_parameters, .marker = "é" },
    };
    for (cases) |case| for ([_]bool{ false, true }) |module| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, case.source);
        try std.testing.expectError(ParseError.UnexpectedToken, if (module) parser.parseModule() else parser.parseProgram());
        try std.testing.expectEqual(case.reason, parser.last_error_reason.?);
        try std.testing.expectEqual(std.mem.indexOf(u8, case.source, case.marker).?, parser.errorLocation().byte_offset);
        try std.testing.expect(parser.last_error_token != null);
    };
    for ([_][]const u8{
        "({get x() {}, set x(a) {}})",
        "({set x({a,b} = {}) {}})",
        "({set x([a,...b]) {}})",
        "class C { static set #x({a} = {}) {} }",
        "function f(a,) {} ({m(a,) {}}); class C { m(a,) {} }",
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        _ = try parser.parseProgram();
    }
}

test "template substitution finalization rejects pending cover errors and trailing tokens" {
    const Case = struct { source: []const u8, reason: ?DiagnosticReason, marker: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .source = "`x${({__proto__: null, '__proto__': {}})}`", .reason = .duplicate_proto, .marker = "'__proto__'" },
        .{ .source = "String.raw`x${({__proto__: null, '__proto__': {}})}`", .reason = .duplicate_proto, .marker = "'__proto__'" },
        .{ .source = "`x\r\n${`y${({__proto__: null, '__proto__': {}})}`}`", .reason = .duplicate_proto, .marker = "'__proto__'" },
        .{ .source = "`x${({a = 1})}`", .reason = null },
        .{ .source = "String.raw`x${({a = 1})}`", .reason = null },
        .{ .source = "`x${1 2}`", .reason = .template_expression_tail, .marker = "2" },
        .{ .source = "String.raw`x${1; 2}`", .reason = .template_expression_tail, .marker = ";" },
    };
    for (cases) |case| for ([_]bool{ false, true }) |module| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, case.source);
        try std.testing.expectError(ParseError.UnexpectedToken, if (module) parser.parseModule() else parser.parseProgram());
        try std.testing.expectEqual(case.reason, parser.last_error_reason);
        if (case.marker) |marker| try std.testing.expectEqual(std.mem.indexOf(u8, case.source, marker).?, parser.errorLocation().byte_offset);
    };
    for ([_][]const u8{
        "var a,b; `x${({__proto__: a, __proto__: b} = {})}`",
        "var a; `x${({a = 1} = {})}`",
        "var a; String.raw`x${({a = 1} = {})}`",
        "`x${({['__proto__']: 1, ['__proto__']: 2})}`",
        "`x${1,2}`",
        "String.raw`x${`y${(1,2)}`}`",
    }) |source| for ([_]bool{ false, true }) |module| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, source);
        _ = try if (module) parser.parseModule() else parser.parseProgram();
    };
}

test "parser reports private name validation scratch exhaustion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var no_memory: [0]u8 = .{};
    var scratch = std.heap.FixedBufferAllocator.init(&no_memory);
    var parser = try Parser.initWithScratch(arena.allocator(), scratch.allocator(), "class C { #first; #second; }");
    try std.testing.expectError(error.OutOfMemory, parser.parseProgram());
}

test "parser rejects new await only when await is active" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var module_new_await = try Parser.init(arena.allocator(), "new await;");
    try std.testing.expectError(ParseError.UnexpectedToken, module_new_await.parseModule());

    var script_new_await = try Parser.init(arena.allocator(), "function await() {} new await;");
    const prog = try script_new_await.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), prog.program.len);
}

test "parser does not propagate module await into function parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var decl_param = try Parser.init(arena.allocator(), "function fn(x = await 1) {}");
    try std.testing.expectError(ParseError.UnexpectedToken, decl_param.parseModule());

    var expr_param = try Parser.init(arena.allocator(), "0, function (x = await 1) {};");
    try std.testing.expectError(ParseError.UnexpectedToken, expr_param.parseModule());
}

test "module parsing extends one goal-bounded token stream and rejects Script HTML comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var module = try Parser.init(arena.allocator(), "import { value } from './dependency.js'; export { value };");
    const initial_token_count = module.tokens.items.len;
    try std.testing.expect(initial_token_count > 0);
    const program = try module.parseModule();
    try std.testing.expectEqual(@as(usize, 2), program.program.len);
    try std.testing.expect(module.tokens.items.len >= initial_token_count);
    try std.testing.expectEqual(TokenKind.eof, module.tokens.items[module.tokens.items.len - 1].kind);

    const source = "var before = 1;\n  --> hidden\nvar after = 2;";
    var script = try Parser.init(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 2), (try script.parseProgram()).program.len);

    var rejected = try Parser.init(arena.allocator(), source);
    try std.testing.expectError(ParseError.UnexpectedToken, rejected.parseModule());
    try std.testing.expectEqual(std.mem.indexOf(u8, source, "-->").?, rejected.errorLocation().byte_offset);
}

fn exerciseRegexValidationScratch(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "var patterns = [/(?<word>[a-z]+)(?=\\d)/gi, /[\\d-a]+/, /unicode-[a-z]+/u];";
    var parser = try Parser.initWithScratch(arena.allocator(), allocator, source);
    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), program.program.len);
    const initializer = program.program[0].var_decl.init.?;
    try std.testing.expectEqual(@as(usize, 3), initializer.array_lit.len);
    try std.testing.expectEqualStrings("(?<word>[a-z]+)(?=\\d)", initializer.array_lit[0].regex_literal.pattern);
    try std.testing.expectEqualStrings("gi", initializer.array_lit[0].regex_literal.flags);
    try std.testing.expectEqualStrings("[\\d-a]+", initializer.array_lit[1].regex_literal.pattern);
    try std.testing.expectEqualStrings("u", initializer.array_lit[2].regex_literal.flags);
}

fn exerciseRegexCompilerAllocationFailures(allocator: std.mem.Allocator) !void {
    for ([_]struct { pattern: []const u8, flags: []const u8 }{
        .{ .pattern = "(?<word>[a-z]+)(?=\\d)", .flags = "gi" },
        .{ .pattern = "[\\d-a]+", .flags = "" },
        .{ .pattern = "unicode-[a-z]+", .flags = "u" },
    }) |spec| {
        var diagnostic: ?regex.CompileErrorReason = null;
        var compiled = try compileRegexLiteralForValidation(allocator, spec.pattern, spec.flags, &diagnostic);
        defer compiled.deinit();
    }
}

test "parser RegExp validation releases every scratch allocation and preserves AST source" {
    try exerciseRegexValidationScratch(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRegexCompilerAllocationFailures,
        .{},
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var invalid = try Parser.initWithScratch(arena.allocator(), std.testing.allocator, "var invalid = /(/;");
    try std.testing.expectError(ParseError.UnexpectedToken, invalid.parseProgram());

    var no_memory: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&no_memory);
    var exhausted = try Parser.initWithScratch(arena.allocator(), fixed.allocator(), "var pattern = /a+/;");
    try std.testing.expectError(error.OutOfMemory, exhausted.parseProgram());
}

test "regex literal validation preserves exact compile diagnostics" {
    const Case = struct {
        source: []const u8,
        reason: DiagnosticReason,
        message: []const u8,
    };
    const cases = [_]Case{
        .{ .source = "/(/;", .reason = .regexp_missing_closing_parenthesis, .message = "Invalid regular expression: missing )" },
        .{ .source = "/a{2,1}/;", .reason = .regexp_quantifier_numbers_out_of_order, .message = "Invalid regular expression: numbers out of order in {} quantifier" },
        .{ .source = "/a**/;", .reason = .regexp_nothing_to_repeat, .message = "Invalid regular expression: nothing to repeat" },
        .{ .source = "/(?<1>a)/;", .reason = .regexp_invalid_group_specifier_name, .message = "Invalid regular expression: invalid group specifier name" },
        .{ .source = "/[z-a]/;", .reason = .regexp_range_out_of_order_in_character_class, .message = "Invalid regular expression: range out of order in character class" },
        .{ .source = "/\\q/u;", .reason = .regexp_invalid_escaped_character_for_unicode_pattern, .message = "Invalid regular expression: invalid escaped character for Unicode pattern" },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (cases) |case| {
        var parser = try Parser.init(arena.allocator(), case.source);
        try std.testing.expectError(case.reason.parseError(), parser.parseProgram());
        try std.testing.expectEqual(case.reason, parser.last_error_reason.?);
        try std.testing.expectEqualStrings(case.message, try parser.diagnosticMessage(arena.allocator(), case.reason));
    }
}
