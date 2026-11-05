# toml-zig

TOML 1.0.0 parser and writer for Zig 0.17, with no dependencies. See `ai/SPEC.md` for requirements and known deviations (notably: comments are not preserved when writing).

```zig
// build.zig.zon: .toml = .{ .path = "../toml-zig" }
// build.zig:     exe.root_module.addImport("toml", b.dependency("toml", .{}).module("toml"));
var diag: toml.Diagnostic = .{};
var doc = try toml.Document.parse(gpa, text, .{}, &diag);
defer doc.deinit();
```

`zig build test` runs the tests.
