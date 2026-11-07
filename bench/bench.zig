//! Parse/write baseline. Run with `zig build bench` (ReleaseFast).
//!
//! Generates a deterministic TOML document of roughly the requested size and
//! reports best-of-N wall time for each operation. Meant for comparing one
//! parser design against another on the same machine, not for absolute claims.

const std = @import("std");
const toml = @import("toml");

const runs = 20;

/// One `[section.N]` table of mixed value kinds, ~330 bytes.
fn appendSection(w: *std.Io.Writer, n: usize) !void {
    try w.print(
        \\[section.s{d}]
        \\name = "item number {d}"
        \\path = 'C:\Users\item{d}'
        \\enabled = true
        \\count = {d}
        \\ratio = {d}.5e-2
        \\hex = 0xdead_beef
        \\created = 2026-11-06T12:34:56Z
        \\tags = ["alpha", "beta", "gamma", "d{d}"]
        \\sizes = [1, 2, 3, 4, 5, 6, 7, 8]
        \\inline = {{ x = {d}, y = "why", z = [true, false] }}
        \\note = """
        \\multi line
        \\text for {d}"""
        \\# a comment line
        \\"quoted key" = "caf\u00e9 \t tab"
        \\a.b.c = {d}
        \\
        \\
    , .{ n, n, n, n, n, n, n, n, n });
}

fn generate(gpa: std.mem.Allocator, target_bytes: usize) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var n: usize = 0;
    while (aw.writer.end < target_bytes) : (n += 1) try appendSection(&aw.writer, n);
    return aw.toOwnedSlice();
}

fn report(io: std.Io, label: []const u8, bytes: usize, best_ns: i96) void {
    _ = io;
    const ns: f64 = @floatFromInt(best_ns);
    const mb_s = @as(f64, @floatFromInt(bytes)) / 1e6 / (ns / 1e9);
    std.debug.print("  {s:<22} {d:>10.3} ms  {d:>8.1} MB/s\n", .{ label, ns / 1e6, mb_s });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    for ([_]usize{ 4 * 1024, 256 * 1024, 8 * 1024 * 1024 }) |size| {
        const text = try generate(gpa, size);
        defer gpa.free(text);
        std.debug.print("\ninput {d} bytes\n", .{text.len});

        // parse from a slice
        var best: i96 = std.math.maxInt(i96);
        for (0..runs) |_| {
            const t0 = std.Io.Clock.awake.now(io);
            var doc = try toml.Document.parse(gpa, text, .{}, null);
            const t1 = std.Io.Clock.awake.now(io);
            std.mem.doNotOptimizeAway(doc.root);
            doc.deinit();
            best = @min(best, t0.durationTo(t1).nanoseconds);
        }
        report(io, "parse (slice)", text.len, best);

        // parse through a Reader
        best = std.math.maxInt(i96);
        for (0..runs) |_| {
            var r: std.Io.Reader = .fixed(text);
            const t0 = std.Io.Clock.awake.now(io);
            var doc = try toml.Document.parseReader(gpa, &r, .{ .max_bytes = 1 << 30 }, null);
            const t1 = std.Io.Clock.awake.now(io);
            std.mem.doNotOptimizeAway(doc.root);
            doc.deinit();
            best = @min(best, t0.durationTo(t1).nanoseconds);
        }
        report(io, "parseReader (fixed)", text.len, best);

        // write
        var doc = try toml.Document.parse(gpa, text, .{}, null);
        defer doc.deinit();
        best = std.math.maxInt(i96);
        var out_len: usize = 0;
        for (0..runs) |_| {
            const t0 = std.Io.Clock.awake.now(io);
            const s = try doc.toOwnedString(gpa);
            const t1 = std.Io.Clock.awake.now(io);
            out_len = s.len;
            gpa.free(s);
            best = @min(best, t0.durationTo(t1).nanoseconds);
        }
        report(io, "write (toOwnedString)", out_len, best);
    }
}
