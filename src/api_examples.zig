//! The code shown in docs/api.md, compiled and run by `zig build test` so the
//! documentation cannot drift from the library. Keep the two in step.

const std = @import("std");
const toml = @import("root.zig");
const testing = std.testing;
const gpa = testing.allocator;

const config =
    \\# DKDE panel
    \\title = "DKDE"
    \\
    \\[panel]
    \\position = "bottom"   # top|bottom
    \\height = 32
    \\opacity = 0.9
    \\visible = true
    \\
    \\[[panel.widget]]
    \\name = "clock"
    \\
    \\[[panel.widget]]
    \\name = "tray"
    \\
;

test "read: typed getters and dotted lookup" {
    var diag: toml.Diagnostic = .{};
    var doc = try toml.Document.parse(gpa, config, .{}, &diag);
    defer doc.deinit();

    const title = doc.root.getString("title") orelse "untitled";
    try testing.expectEqualStrings("DKDE", title);

    const panel = doc.root.getTable("panel") orelse return error.MissingPanel;
    const height = panel.getInt("height") orelse 24;
    const opacity = panel.getFloat("opacity") orelse 1.0;
    const visible = panel.getBool("visible") orelse true;
    try testing.expectEqual(@as(i64, 32), height);
    try testing.expectEqual(@as(f64, 0.9), opacity);
    try testing.expect(visible);

    if (doc.root.lookup("panel.position")) |v| {
        switch (v) {
            .string => |s| try testing.expectEqualStrings("bottom", s),
            else => return error.WrongType,
        }
    } else return error.Missing;
}

test "read: arrays and arrays of tables" {
    var doc = try toml.Document.parse(gpa, config, .{}, null);
    defer doc.deinit();

    const panel = doc.root.getTable("panel").?;
    const widgets = panel.getArray("widget") orelse return error.Missing;
    try testing.expect(widgets.is_table_array);
    var names: [2][]const u8 = undefined;
    for (widgets.items.items, 0..) |item, i| {
        names[i] = item.table.getString("name").?;
    }
    try testing.expectEqualStrings("clock", names[0]);
    try testing.expectEqualStrings("tray", names[1]);
}

test "read: iterate a table in file order" {
    var doc = try toml.Document.parse(gpa, config, .{}, null);
    defer doc.deinit();

    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    var it = doc.root.getTable("panel").?.entries.iterator();
    while (it.next()) |e| try keys.append(gpa, e.key_ptr.*);
    try testing.expectEqual(@as(usize, 5), keys.items.len);
    try testing.expectEqualStrings("position", keys.items[0]);
    try testing.expectEqualStrings("widget", keys.items[4]);
}

test "read: datetimes" {
    var doc = try toml.Document.parse(gpa, "when = 1979-05-27T07:32:00-07:00\n", .{}, null);
    defer doc.deinit();
    const dt = doc.root.get("when").?.datetime;
    try testing.expectEqual(@as(u16, 1979), dt.date.?.year);
    try testing.expectEqual(@as(u8, 7), dt.time.?.hour);
    try testing.expectEqual(@as(i16, -420), dt.offset_minutes.?);
    var buf: [40]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{dt});
    try testing.expectEqualStrings("1979-05-27T07:32:00-07:00", s);
}

test "errors: diagnostic carries line, column and message" {
    var diag: toml.Diagnostic = .{};
    try testing.expectError(error.Syntax, toml.Document.parse(gpa, "a = 1\na = 2\n", .{}, &diag));
    try testing.expectEqual(@as(usize, 2), diag.line);
    var buf: [128]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{diag});
    try testing.expect(std.mem.startsWith(u8, s, "2:"));
}

test "options: strict 1.0 and limits" {
    const src = "t = { a = 1,\n b = 2 }\n";
    var doc = try toml.Document.parse(gpa, src, .{}, null);
    doc.deinit();
    try testing.expectError(error.Syntax, toml.Document.parse(gpa, src, .{ .version = .v1_0 }, null));
    try testing.expectError(error.LimitExceeded, toml.Document.parse(gpa, src, .{ .max_bytes = 4 }, null));
}

test "edit: set values, dupe strings, remove keys" {
    var doc = try toml.Document.parse(gpa, config, .{}, null);
    defer doc.deinit();

    try doc.set(&.{ "panel", "position" }, .{ .string = try doc.dupe("top") });
    try doc.set(&.{ "panel", "height" }, .{ .integer = 40 });
    try doc.set(&.{ "net", "retries" }, .{ .integer = 3 }); // creates [net]
    try testing.expectError(error.NotATable, doc.set(&.{ "title", "x" }, .{ .integer = 1 }));

    try testing.expect(doc.root.getTable("panel").?.remove("opacity"));
    try testing.expectEqualStrings("top", doc.root.lookup("panel.position").?.string);
}

test "edit: build a document from nothing, including an array" {
    var doc = try toml.Document.init(gpa);
    defer doc.deinit();

    const a = doc.allocator();
    const ports = try a.create(toml.Array);
    ports.* = .{};
    try ports.items.append(a, .{ .integer = 80 });
    try ports.items.append(a, .{ .integer = 443 });

    try doc.set(&.{ "server", "host" }, .{ .string = try doc.dupe("localhost") });
    try doc.set(&.{ "server", "ports" }, .{ .array = ports });

    const out = try doc.toOwnedString(gpa);
    defer gpa.free(out);
    try testing.expectEqualStrings(
        \\[server]
        \\host = "localhost"
        \\ports = [80, 443]
        \\
    , out);
}

test "comments: survive an edit; setComments adds new ones" {
    var doc = try toml.Document.parse(gpa, config, .{}, null);
    defer doc.deinit();

    try doc.set(&.{ "panel", "height" }, .{ .integer = 40 });
    try doc.setComments(&.{ "panel", "height" }, .{
        .before = &.{"# pixels"},
        .after = "# was 32",
    });
    const c = doc.root.getTable("panel").?.commentsOf("height").?;
    try testing.expectEqualStrings("# was 32", c.after.?);

    const out = try doc.toOwnedString(gpa);
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "# DKDE panel\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "# pixels\nheight = 40 # was 32\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "position = \"bottom\" # top|bottom") != null);
    try testing.expectError(error.InvalidComment, doc.setComments(&.{"title"}, .{ .after = "no hash" }));
}

test "write: to any std.Io.Writer" {
    var doc = try toml.Document.parse(gpa, config, .{}, null);
    defer doc.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try doc.write(gpa, &aw.writer);
    try testing.expect(aw.written().len > 0);
}
