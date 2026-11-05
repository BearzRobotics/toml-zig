//! toml-zig: a TOML 1.0.0 parser and writer.
//!
//! ```zig
//! var diag: toml.Diagnostic = .{};
//! var doc = toml.Document.parse(gpa, source, .{}, &diag) catch |e| {
//!     std.log.err("config: {f}: {s}", .{ diag, @errorName(e) });
//!     return e;
//! };
//! defer doc.deinit();
//! const pos = doc.root.lookup("panel.position");
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = @import("value.zig").Value;
pub const Table = @import("value.zig").Table;
pub const TableKind = @import("value.zig").TableKind;
pub const Array = @import("value.zig").Array;
pub const Datetime = @import("value.zig").Datetime;
pub const Date = @import("value.zig").Date;
pub const Time = @import("value.zig").Time;
pub const ParseError = @import("parser.zig").Error;
pub const Options = @import("parser.zig").Options;
pub const Diagnostic = @import("parser.zig").Diagnostic;
pub const WriteError = @import("writer.zig").Error;

/// A parsed document. Owns an arena holding every string, table and array
/// reachable from `root`; `deinit` frees all of it at once.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Table,

    /// An empty document, for building one with the setters.
    pub fn init(gpa: Allocator) Allocator.Error!Document {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const root = try arena.allocator().create(Table);
        root.* = .{};
        return .{ .arena = arena, .root = root };
    }

    /// Parses `source` (UTF-8). `source` is not retained. On failure the
    /// optional `diag` receives a 1-based line and column.
    pub fn parse(gpa: Allocator, source: []const u8, options: Options, diag: ?*Diagnostic) ParseError!Document {
        var doc = try init(gpa);
        errdefer doc.deinit();
        try @import("parser.zig").parse(doc.arena.allocator(), doc.root, source, options, diag);
        return doc;
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The allocator that owns this document's contents; use it for any value
    /// passed to `Table.put`.
    pub fn allocator(self: *Document) Allocator {
        return self.arena.allocator();
    }

    /// Duplicates `s` into the document so it can be stored as a value or key.
    pub fn dupe(self: *Document, s: []const u8) Allocator.Error![]const u8 {
        return self.allocator().dupe(u8, s);
    }

    /// Sets `a.b.c = value`, creating intermediate tables. Fails with
    /// `error.NotATable` if a path segment already holds a non-table value.
    /// `value` must already be arena-owned (use `dupe` for strings).
    pub fn set(self: *Document, path: []const []const u8, v: Value) (Allocator.Error || error{NotATable})!void {
        std.debug.assert(path.len > 0);
        const a = self.allocator();
        var cur = self.root;
        for (path[0 .. path.len - 1]) |seg| {
            if (cur.getPtr(seg)) |existing| {
                switch (existing.*) {
                    .table => |t| cur = t,
                    else => return error.NotATable,
                }
            } else {
                const t = try a.create(Table);
                t.* = .{ .kind = .explicit };
                try cur.put(a, try self.dupe(seg), .{ .table = t });
                cur = t;
            }
        }
        try cur.put(a, try self.dupe(path[path.len - 1]), v);
    }

    /// Writes the document as TOML. See `writer.zig` for what is preserved.
    pub fn write(self: *const Document, gpa: Allocator, w: *std.Io.Writer) WriteError!void {
        try @import("writer.zig").writeTable(gpa, w, self.root);
    }

    /// Returns the TOML text; caller frees with `gpa`.
    pub fn toOwnedString(self: *const Document, gpa: Allocator) WriteError![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        try self.write(gpa, &aw.writer);
        return aw.toOwnedSlice();
    }
};

test {
    _ = @import("tests.zig");
}
