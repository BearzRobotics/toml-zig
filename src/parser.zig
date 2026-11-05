//! TOML 1.0.0 parser. Reference: https://toml.io/en/v1.0.0 (ABNF in the
//! toml-lang/toml repository, toml.abnf at tag v1.0.0).
//!
//! The parser works on a UTF-8 byte slice and allocates everything from the
//! arena it is given. On any error it stops at the first problem and, if a
//! `Diagnostic` was supplied, records a 1-based line/column and a message.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("value.zig");
const Value = value.Value;
const Table = value.Table;
const Array = value.Array;
const Datetime = value.Datetime;

pub const Error = error{
    /// Malformed TOML, or a valid-looking construct TOML forbids (duplicate key, ...).
    Syntax,
    /// The input is not valid UTF-8.
    InvalidUtf8,
    /// Nesting or input size exceeded `Options` limits.
    LimitExceeded,
    OutOfMemory,
};

pub const Options = struct {
    /// Maximum nesting of arrays plus inline tables. Bounds recursion depth.
    max_depth: u32 = 64,
    /// Maximum input size in bytes.
    max_bytes: usize = 16 * 1024 * 1024,
};

pub const Diagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    /// Static string; valid for the program's lifetime.
    message: []const u8 = "",

    pub fn format(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}: {s}", .{ self.line, self.column, self.message });
    }
};

pub fn parse(arena: Allocator, root: *Table, src: []const u8, options: Options, diag: ?*Diagnostic) Error!void {
    if (src.len > options.max_bytes) return fail0(diag, "input too large", error.LimitExceeded);
    if (!std.unicode.utf8ValidateSlice(src)) {
        // Locate the line for the message; cheap, and only on the error path.
        return failAt(diag, src, firstInvalidUtf8(src), "invalid UTF-8", error.InvalidUtf8);
    }
    var p: Parser = .{ .src = src, .pos = 0, .arena = arena, .root = root, .current = root, .options = options, .diag = diag };
    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) p.pos = 3;
    root.kind = .explicit;
    try p.document();
}

fn fail0(diag: ?*Diagnostic, msg: []const u8, err: Error) Error {
    if (diag) |d| d.* = .{ .line = 1, .column = 1, .message = msg };
    return err;
}

fn failAt(diag: ?*Diagnostic, src: []const u8, pos: usize, msg: []const u8, err: Error) Error {
    if (diag) |d| {
        var line: usize = 1;
        var col: usize = 1;
        for (src[0..@min(pos, src.len)]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else if (c & 0xC0 != 0x80) col += 1; // count code points, not bytes
        }
        d.* = .{ .line = line, .column = col, .message = msg };
    }
    return err;
}

fn firstInvalidUtf8(src: []const u8) usize {
    var i: usize = 0;
    while (i < src.len) {
        const n = std.unicode.utf8ByteSequenceLength(src[i]) catch return i;
        if (i + n > src.len or !std.unicode.utf8ValidateSlice(src[i .. i + n])) return i;
        i += n;
    }
    return src.len;
}

const Parser = struct {
    src: []const u8,
    pos: usize,
    arena: Allocator,
    root: *Table,
    current: *Table,
    options: Options,
    diag: ?*Diagnostic,
    depth: u32 = 0,

    fn err(self: *Parser, msg: []const u8) Error {
        return failAt(self.diag, self.src, self.pos, msg, error.Syntax);
    }

    fn errAt(self: *Parser, pos: usize, msg: []const u8) Error {
        return failAt(self.diag, self.src, pos, msg, error.Syntax);
    }

    fn peek(self: *const Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn startsWith(self: *const Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, self.src[self.pos..], s);
    }

    // ---- lexical helpers -------------------------------------------------

    fn skipWs(self: *Parser) void {
        while (self.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            self.pos += 1;
        }
    }

    /// Consumes a newline (LF or CRLF) if present.
    fn eatNewline(self: *Parser) bool {
        if (self.peek() == '\n') {
            self.pos += 1;
            return true;
        }
        if (self.startsWith("\r\n")) {
            self.pos += 2;
            return true;
        }
        return false;
    }

    /// Comment body: any char except control characters other than tab (ABNF `non-eol`).
    fn skipComment(self: *Parser) Error!void {
        if (self.peek() != '#') return;
        while (self.peek()) |c| {
            if (c == '\n') break;
            if (c == '\r') {
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\n') break;
                return self.err("bare carriage return in comment");
            }
            if (isForbiddenControl(c)) return self.err("control character in comment");
            self.pos += 1;
        }
    }

    /// Whitespace, comments and newlines, as between top-level expressions.
    fn skipBlank(self: *Parser) Error!void {
        while (true) {
            self.skipWs();
            try self.skipComment();
            if (!self.eatNewline()) break;
        }
    }

    fn expectEndOfLine(self: *Parser) Error!void {
        self.skipWs();
        try self.skipComment();
        if (self.pos >= self.src.len) return;
        if (!self.eatNewline()) return self.err("expected end of line");
    }

    // ---- document structure ---------------------------------------------

    fn document(self: *Parser) Error!void {
        while (true) {
            try self.skipBlank();
            const c = self.peek() orelse return;
            if (c == '[') {
                if (self.startsWith("[[")) try self.arrayTableHeader() else try self.tableHeader();
            } else {
                try self.keyValue(self.current);
            }
            try self.expectEndOfLine();
        }
    }

    fn tableHeader(self: *Parser) Error!void {
        const start = self.pos;
        self.pos += 1; // '['
        self.skipWs();
        const keys = try self.key();
        self.skipWs();
        if (self.peek() != ']') return self.err("expected ']'");
        self.pos += 1;

        const parent = try self.walk(self.root, keys[0 .. keys.len - 1], start);
        const last = keys[keys.len - 1];
        if (parent.getPtr(last)) |existing| {
            switch (existing.*) {
                .table => |t| {
                    if (t.kind != .implicit) return self.errAt(start, "table defined more than once");
                    t.kind = .explicit;
                    self.current = t;
                },
                else => return self.errAt(start, "key already defined as a non-table value"),
            }
        } else {
            const t = try self.newTable(.explicit);
            try parent.put(self.arena, last, .{ .table = t });
            self.current = t;
        }
    }

    fn arrayTableHeader(self: *Parser) Error!void {
        const start = self.pos;
        self.pos += 2; // '[['
        self.skipWs();
        const keys = try self.key();
        self.skipWs();
        if (!self.startsWith("]]")) return self.err("expected ']]'");
        self.pos += 2;

        const parent = try self.walk(self.root, keys[0 .. keys.len - 1], start);
        const last = keys[keys.len - 1];
        const elem = try self.newTable(.explicit);
        if (parent.getPtr(last)) |existing| {
            switch (existing.*) {
                .array => |a| {
                    if (!a.is_table_array) return self.errAt(start, "cannot extend a static array with [[...]]");
                    try a.items.append(self.arena, .{ .table = elem });
                },
                else => return self.errAt(start, "key already defined as a non-array value"),
            }
        } else {
            const a = try self.arena.create(Array);
            a.* = .{ .is_table_array = true };
            try a.items.append(self.arena, .{ .table = elem });
            try parent.put(self.arena, last, .{ .array = a });
        }
        self.current = elem;
    }

    /// Follows header path segments, creating implicit tables. Through an array
    /// of tables it descends into the most recently added element.
    fn walk(self: *Parser, from: *Table, segs: []const []const u8, pos: usize) Error!*Table {
        var cur = from;
        for (segs) |seg| {
            if (cur.getPtr(seg)) |existing| {
                switch (existing.*) {
                    .table => |t| {
                        if (t.kind == .inline_table) return self.errAt(pos, "cannot extend an inline table");
                        cur = t;
                    },
                    .array => |a| {
                        if (!a.is_table_array or a.items.items.len == 0)
                            return self.errAt(pos, "cannot extend a static array");
                        cur = a.items.items[a.items.items.len - 1].table;
                    },
                    else => return self.errAt(pos, "key already defined as a non-table value"),
                }
            } else {
                const t = try self.newTable(.implicit);
                try cur.put(self.arena, seg, .{ .table = t });
                cur = t;
            }
        }
        return cur;
    }

    fn newTable(self: *Parser, kind: value.TableKind) Error!*Table {
        const t = try self.arena.create(Table);
        t.* = .{ .kind = kind };
        return t;
    }

    // ---- keys and values -------------------------------------------------

    /// key = value, where key may be dotted. Inserts into `table`.
    fn keyValue(self: *Parser, table: *Table) Error!void {
        const start = self.pos;
        const keys = try self.key();
        self.skipWs();
        if (self.peek() != '=') return self.err("expected '=' after key");
        self.pos += 1;
        self.skipWs();

        // Dotted keys create tables that only dotted keys may extend.
        var cur = table;
        for (keys[0 .. keys.len - 1]) |seg| {
            if (cur.getPtr(seg)) |existing| {
                switch (existing.*) {
                    .table => |t| {
                        if (t.kind != .dotted) return self.errAt(start, "key already defined as a table");
                        cur = t;
                    },
                    else => return self.errAt(start, "key already defined as a non-table value"),
                }
            } else {
                const t = try self.newTable(.dotted);
                try cur.put(self.arena, seg, .{ .table = t });
                cur = t;
            }
        }
        const last = keys[keys.len - 1];
        if (cur.get(last) != null) return self.errAt(start, "duplicate key");
        const v = try self.val();
        try cur.put(self.arena, last, v);
    }

    /// Parses `simple-key *( dot-sep simple-key )`.
    fn key(self: *Parser) Error![]const []const u8 {
        var segs: std.ArrayList([]const u8) = .empty;
        while (true) {
            self.skipWs();
            try segs.append(self.arena, try self.simpleKey());
            self.skipWs();
            if (self.peek() == '.') {
                self.pos += 1;
            } else break;
        }
        return segs.items;
    }

    fn simpleKey(self: *Parser) Error![]const u8 {
        const c = self.peek() orelse return self.err("expected key");
        if (c == '"') return self.basicString();
        if (c == '\'') return self.literalString();
        const start = self.pos;
        while (self.peek()) |b| {
            if (!isBareKeyChar(b)) break;
            self.pos += 1;
        }
        if (self.pos == start) return self.err("expected key");
        return try self.arena.dupe(u8, self.src[start..self.pos]);
    }

    fn val(self: *Parser) Error!Value {
        const c = self.peek() orelse return self.err("expected value");
        switch (c) {
            '"' => {
                if (self.startsWith("\"\"\"")) return .{ .string = try self.multilineBasic() };
                return .{ .string = try self.basicString() };
            },
            '\'' => {
                if (self.startsWith("'''")) return .{ .string = try self.multilineLiteral() };
                return .{ .string = try self.literalString() };
            },
            '[' => return self.arrayValue(),
            '{' => return self.inlineTable(),
            else => return self.scalar(),
        }
    }

    fn enter(self: *Parser) Error!void {
        if (self.depth >= self.options.max_depth) {
            return failAt(self.diag, self.src, self.pos, "nesting too deep", error.LimitExceeded);
        }
        self.depth += 1;
    }

    fn arrayValue(self: *Parser) Error!Value {
        try self.enter();
        defer self.depth -= 1;
        self.pos += 1; // '['
        const a = try self.arena.create(Array);
        a.* = .{};
        while (true) {
            try self.skipBlank();
            if (self.peek() == ']') {
                self.pos += 1;
                break;
            }
            try a.items.append(self.arena, try self.val());
            try self.skipBlank();
            switch (self.peek() orelse return self.err("unterminated array")) {
                ',' => self.pos += 1,
                ']' => {},
                else => return self.err("expected ',' or ']' in array"),
            }
        }
        return .{ .array = a };
    }

    fn inlineTable(self: *Parser) Error!Value {
        try self.enter();
        defer self.depth -= 1;
        self.pos += 1; // '{'
        const t = try self.newTable(.inline_table);
        self.skipWs();
        if (self.peek() == '}') {
            self.pos += 1;
            return .{ .table = t };
        }
        while (true) {
            self.skipWs();
            try self.keyValue(t);
            self.skipWs();
            switch (self.peek() orelse return self.err("unterminated inline table")) {
                ',' => {
                    self.pos += 1;
                    self.skipWs();
                    if (self.peek() == '}') return self.err("trailing comma in inline table");
                },
                '}' => {
                    self.pos += 1;
                    break;
                },
                else => return self.err("expected ',' or '}' in inline table"),
            }
        }
        return .{ .table = t };
    }

    // ---- strings ---------------------------------------------------------

    fn basicString(self: *Parser) Error![]const u8 {
        self.pos += 1; // opening quote
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = self.peek() orelse return self.err("unterminated string");
            switch (c) {
                '"' => {
                    self.pos += 1;
                    return out.items;
                },
                '\\' => try self.escape(&out),
                '\n', '\r' => return self.err("newline in single-line string"),
                else => {
                    if (isForbiddenControl(c)) return self.err("control character in string");
                    try out.append(self.arena, c);
                    self.pos += 1;
                },
            }
        }
    }

    fn literalString(self: *Parser) Error![]const u8 {
        self.pos += 1;
        const start = self.pos;
        while (true) {
            const c = self.peek() orelse return self.err("unterminated string");
            if (c == '\'') break;
            if (c == '\n' or c == '\r') return self.err("newline in single-line string");
            if (isForbiddenControl(c)) return self.err("control character in string");
            self.pos += 1;
        }
        const s = try self.arena.dupe(u8, self.src[start..self.pos]);
        self.pos += 1;
        return s;
    }

    fn multilineBasic(self: *Parser) Error![]const u8 {
        self.pos += 3;
        _ = self.eatNewline(); // a newline right after the opening delimiter is trimmed
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = self.peek() orelse return self.err("unterminated multi-line string");
            switch (c) {
                '"' => {
                    const run = self.quoteRun('"');
                    if (run >= 3) {
                        if (run > 5) return self.err("too many quotes in multi-line string");
                        try out.appendNTimes(self.arena, '"', run - 3);
                        self.pos += run;
                        return out.items;
                    }
                    try out.appendNTimes(self.arena, '"', run);
                    self.pos += run;
                },
                '\\' => {
                    // A backslash before optional whitespace and a newline removes
                    // the newline and all following whitespace.
                    var q = self.pos + 1;
                    while (q < self.src.len and (self.src[q] == ' ' or self.src[q] == '\t')) q += 1;
                    if (q < self.src.len and (self.src[q] == '\n' or (self.src[q] == '\r' and q + 1 < self.src.len and self.src[q + 1] == '\n'))) {
                        self.pos = q;
                        while (self.peek()) |w| {
                            if (w == ' ' or w == '\t' or w == '\n') {
                                self.pos += 1;
                            } else if (self.startsWith("\r\n")) {
                                self.pos += 2;
                            } else break;
                        }
                    } else try self.escape(&out);
                },
                '\n' => {
                    try out.append(self.arena, c);
                    self.pos += 1;
                },
                '\r' => {
                    if (!self.startsWith("\r\n")) return self.err("bare carriage return in string");
                    try out.appendSlice(self.arena, "\r\n");
                    self.pos += 2;
                },
                else => {
                    if (isForbiddenControl(c)) return self.err("control character in string");
                    try out.append(self.arena, c);
                    self.pos += 1;
                },
            }
        }
    }

    fn multilineLiteral(self: *Parser) Error![]const u8 {
        self.pos += 3;
        _ = self.eatNewline();
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = self.peek() orelse return self.err("unterminated multi-line string");
            switch (c) {
                '\'' => {
                    const run = self.quoteRun('\'');
                    if (run >= 3) {
                        if (run > 5) return self.err("too many quotes in multi-line string");
                        try out.appendNTimes(self.arena, '\'', run - 3);
                        self.pos += run;
                        return out.items;
                    }
                    try out.appendNTimes(self.arena, '\'', run);
                    self.pos += run;
                },
                '\r' => {
                    if (!self.startsWith("\r\n")) return self.err("bare carriage return in string");
                    try out.appendSlice(self.arena, "\r\n");
                    self.pos += 2;
                },
                else => {
                    if (c != '\n' and isForbiddenControl(c)) return self.err("control character in string");
                    try out.append(self.arena, c);
                    self.pos += 1;
                },
            }
        }
    }

    fn quoteRun(self: *const Parser, q: u8) usize {
        var n: usize = 0;
        while (self.pos + n < self.src.len and self.src[self.pos + n] == q) n += 1;
        return n;
    }

    /// At a backslash inside a basic string.
    fn escape(self: *Parser, out: *std.ArrayList(u8)) Error!void {
        const esc_pos = self.pos;
        self.pos += 1;
        const c = self.peek() orelse return self.err("unterminated escape");
        self.pos += 1;
        switch (c) {
            'b' => try out.append(self.arena, 0x08),
            't' => try out.append(self.arena, '\t'),
            'n' => try out.append(self.arena, '\n'),
            'f' => try out.append(self.arena, 0x0C),
            'r' => try out.append(self.arena, '\r'),
            '"' => try out.append(self.arena, '"'),
            '\\' => try out.append(self.arena, '\\'),
            'u', 'U' => {
                const ndig: usize = if (c == 'u') 4 else 8;
                if (self.pos + ndig > self.src.len) return self.errAt(esc_pos, "truncated unicode escape");
                const cp32 = std.fmt.parseInt(u32, self.src[self.pos .. self.pos + ndig], 16) catch
                    return self.errAt(esc_pos, "invalid unicode escape");
                // parseInt accepts a leading sign; TOML does not.
                for (self.src[self.pos .. self.pos + ndig]) |h| {
                    if (!std.ascii.isHex(h)) return self.errAt(esc_pos, "invalid unicode escape");
                }
                if (cp32 > 0x10FFFF or (cp32 >= 0xD800 and cp32 <= 0xDFFF))
                    return self.errAt(esc_pos, "unicode escape is not a scalar value");
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cp32), &buf) catch unreachable;
                try out.appendSlice(self.arena, buf[0..n]);
                self.pos += ndig;
            },
            else => return self.errAt(esc_pos, "invalid escape sequence"),
        }
    }

    // ---- numbers, booleans, datetimes -----------------------------------

    fn scalar(self: *Parser) Error!Value {
        const start = self.pos;
        // A space-separated datetime ("1979-05-27 07:32:00") is one token.
        var end = start;
        while (end < self.src.len and !isTokenEnd(self.src[end])) end += 1;
        if (looksLikeDate(self.src[start..end]) and end + 1 < self.src.len and self.src[end] == ' ' and
            end + 3 < self.src.len and std.ascii.isDigit(self.src[end + 1]) and std.ascii.isDigit(self.src[end + 2]) and self.src[end + 3] == ':')
        {
            end += 1;
            while (end < self.src.len and !isTokenEnd(self.src[end])) end += 1;
        }
        const tok = self.src[start..end];
        if (tok.len == 0) return self.err("expected value");
        self.pos = end;

        if (std.mem.eql(u8, tok, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, tok, "false")) return .{ .boolean = false };
        if (looksLikeDate(tok) or (tok.len >= 3 and tok[2] == ':')) {
            return .{ .datetime = parseDatetime(tok) orelse return self.errAt(start, "invalid date or time") };
        }
        return self.number(tok, start);
    }

    fn number(self: *Parser, tok: []const u8, start: usize) Error!Value {
        var s = tok;
        var neg = false;
        var signed = false;
        if (s.len > 0 and (s[0] == '+' or s[0] == '-')) {
            neg = s[0] == '-';
            signed = true;
            s = s[1..];
        }
        if (std.mem.eql(u8, s, "inf")) return .{ .float = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
        if (std.mem.eql(u8, s, "nan")) return .{ .float = std.math.nan(f64) };

        if (s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'o' or s[1] == 'b')) {
            if (signed) return self.errAt(start, "sign not allowed on prefixed integer");
            const base: u8 = switch (s[1]) {
                'x' => 16,
                'o' => 8,
                else => 2,
            };
            const body = self.stripUnderscores(s[2..], base, start) orelse return self.errAt(start, "invalid integer");
            const u = std.fmt.parseInt(u63, body, base) catch return self.errAt(start, "integer out of range");
            return .{ .integer = u };
        }

        var is_float = false;
        for (s) |c| {
            if (c == '.' or c == 'e' or c == 'E') is_float = true;
        }
        if (!is_float) {
            if (s.len == 0) return self.errAt(start, "invalid number");
            if (s.len > 1 and s[0] == '0') return self.errAt(start, "leading zeros are not allowed");
            const body = self.stripUnderscores(s, 10, start) orelse return self.errAt(start, "invalid integer");
            const buf = try self.arena.alloc(u8, body.len + 1);
            buf[0] = if (neg) '-' else '+';
            @memcpy(buf[1..], body);
            const i = std.fmt.parseInt(i64, buf, 10) catch return self.errAt(start, "integer out of range");
            return .{ .integer = i };
        }

        // Float: int-part [frac] [exp], validated before conversion because
        // std.fmt.parseFloat accepts forms TOML rejects ("1.", ".5", "0x1p3").
        var i: usize = 0;
        const int_end = scanDigits(s, 0, 10) orelse return self.errAt(start, "invalid float");
        if (int_end == 0) return self.errAt(start, "invalid float");
        if (int_end > 1 and s[0] == '0') return self.errAt(start, "leading zeros are not allowed");
        i = int_end;
        if (i < s.len and s[i] == '.') {
            const frac_end = scanDigits(s, i + 1, 10) orelse return self.errAt(start, "invalid float");
            if (frac_end == i + 1) return self.errAt(start, "digits required after decimal point");
            i = frac_end;
        }
        if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
            i += 1;
            if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
            const exp_end = scanDigits(s, i, 10) orelse return self.errAt(start, "invalid float");
            if (exp_end == i) return self.errAt(start, "digits required in exponent");
            i = exp_end;
        }
        if (i != s.len) return self.errAt(start, "invalid float");
        const clean = self.stripUnderscores(s, 0, start) orelse return self.errAt(start, "invalid float");
        const f = std.fmt.parseFloat(f64, clean) catch return self.errAt(start, "invalid float");
        return .{ .float = if (neg) -f else f };
    }

    /// Validates underscore placement (only between digits) and returns the
    /// digits without them. `base == 0` means "a float body": '.', 'e', 'E',
    /// '+' and '-' count as non-digit separators that underscores may not touch.
    fn stripUnderscores(self: *Parser, s: []const u8, base: u8, start: usize) ?[]const u8 {
        _ = start;
        if (s.len == 0) return null;
        const out = self.arena.alloc(u8, s.len) catch return null;
        var n: usize = 0;
        for (s, 0..) |c, idx| {
            if (c == '_') {
                if (idx == 0 or idx + 1 == s.len) return null;
                if (!isDigitOf(s[idx - 1], base) or !isDigitOf(s[idx + 1], base)) return null;
                continue;
            }
            if (base != 0 and !isDigitOf(c, base)) return null;
            out[n] = c;
            n += 1;
        }
        return out[0..n];
    }
};

/// Index just past the run of digits/underscores starting at `from`, or null
/// if an underscore is not between two digits.
fn scanDigits(s: []const u8, from: usize, base: u8) ?usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '_') {
            if (i == from or i + 1 >= s.len or !isDigitOf(s[i - 1], base) or !isDigitOf(s[i + 1], base)) return null;
        } else if (!isDigitOf(c, base)) break;
    }
    return i;
}

fn isDigitOf(c: u8, base: u8) bool {
    return switch (base) {
        0, 10 => std.ascii.isDigit(c),
        16 => std.ascii.isHex(c),
        8 => c >= '0' and c <= '7',
        2 => c == '0' or c == '1',
        else => false,
    };
}

fn isBareKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// Characters that end a bare value token.
fn isTokenEnd(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', ',', ']', '}', '#' => true,
        else => false,
    };
}

/// Control characters TOML forbids in strings and comments: U+0000..U+0008,
/// U+000A..U+001F and U+007F. (Tab is allowed; callers handle LF/CR.)
fn isForbiddenControl(c: u8) bool {
    return (c < 0x20 and c != '\t') or c == 0x7F;
}

fn looksLikeDate(tok: []const u8) bool {
    return tok.len >= 10 and tok[4] == '-' and tok[7] == '-' and std.ascii.isDigit(tok[0]);
}

// ---- datetime parsing ----------------------------------------------------

fn digits(s: []const u8, comptime n: usize) ?u32 {
    if (s.len < n) return null;
    var v: u32 = 0;
    for (s[0..n]) |c| {
        if (!std.ascii.isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 29 else 28,
    };
}

fn parseTime(s: []const u8, out_len: *usize) ?value.Time {
    const h = digits(s, 2) orelse return null;
    if (s.len < 8 or s[2] != ':' or s[5] != ':') return null;
    const m = digits(s[3..], 2) orelse return null;
    const sec = digits(s[6..], 2) orelse return null;
    if (h > 23 or m > 59 or sec > 60) return null; // 60: leap second
    var ns: u32 = 0;
    var i: usize = 8;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        var scale: u32 = 100_000_000;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            ns += (s[i] - '0') * scale; // digits past nanoseconds are truncated
            scale /= 10;
        }
        if (i == frac_start) return null;
    }
    out_len.* = i;
    return .{ .hour = @intCast(h), .minute = @intCast(m), .second = @intCast(sec), .nanosecond = ns };
}

fn parseDatetime(tok: []const u8) ?Datetime {
    var dt: Datetime = .{};
    var rest = tok;
    if (looksLikeDate(tok)) {
        const y = digits(tok, 4) orelse return null;
        const mo = digits(tok[5..], 2) orelse return null;
        const d = digits(tok[8..], 2) orelse return null;
        if (mo < 1 or mo > 12 or d < 1 or d > daysInMonth(y, mo)) return null;
        dt.date = .{ .year = @intCast(y), .month = @intCast(mo), .day = @intCast(d) };
        rest = tok[10..];
        if (rest.len == 0) return dt;
        if (rest[0] != 'T' and rest[0] != 't' and rest[0] != ' ') return null;
        rest = rest[1..];
    }
    var tlen: usize = 0;
    dt.time = parseTime(rest, &tlen) orelse return null;
    rest = rest[tlen..];
    if (rest.len == 0) return dt;
    if (dt.date == null) return null; // a bare time has no offset
    if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z')) {
        dt.offset_minutes = 0;
        return dt;
    }
    if (rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':') {
        const oh = digits(rest[1..], 2) orelse return null;
        const om = digits(rest[4..], 2) orelse return null;
        if (oh > 23 or om > 59) return null;
        const mins: i16 = @intCast(oh * 60 + om);
        dt.offset_minutes = if (rest[0] == '-') -mins else mins;
        return dt;
    }
    return null;
}
