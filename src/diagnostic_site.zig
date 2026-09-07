//! Source spans retained solely for JavaScriptCore-compatible runtime errors.
//!
//! This neutral module is shared by bytecode and native artifacts. Keeping the
//! data here avoids making the architecture-level JIT depend on bytecode (which
//! already depends on the JIT) while preserving one exact span representation.

/// Exact source retained for a syntax-owned `[[Call]]`. A CallExpression keeps
/// the byte length of its callee prefix; a tagged template keeps the whole
/// expression for JavaScriptCore's `(near '...source...')` diagnostic.
pub const CallSiteSpan = struct {
    pub const Kind = enum { call, tagged_template };

    text: []const u8 = "",
    callee_len: u32 = 0,
    kind: Kind = .call,
};

/// Exact source of a member evaluation or construction used only when that
/// operation throws, for JavaScriptCore's `(evaluating '...')` suffix.
pub const EvaluationSiteSpan = struct { text: []const u8 = "" };
