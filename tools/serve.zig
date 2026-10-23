const std = @import("std");
const httpz = @import("httpz");

/// A custom context structure passed down to every request handler
const Context = struct {
    io: std.Io,
};

pub fn main(init: std.process.Init) !void {
    // 1. Initialize the modern 0.17.0 SafeAllocator
    var safe_alloc = std.heap.SafeAllocator.init(
        init.gpa,
        std.heap.SafeAllocator.Options{},
    );
    const allocator = safe_alloc.allocator();
    defer _ = safe_alloc.deinit();

    // 2. Initialize our custom application context holding the event loop handle
    var ctx = Context{ .io = init.io };

    // 3. Initialize httpz passing the context pointer
    var server = try httpz.Server(*Context).init(init.io, allocator, .{
        .address = .localhost(8080),
    }, &ctx);
    defer {
        server.stop();
        server.deinit();
    }

    // 4. Register a wildcard route mapping to capture all web assets
    var router = try server.router(.{});
    router.get("/*", serveDocumentationFiles, .{});

    std.debug.print("Native Zig Documentation Server running at http://localhost:8080/\n", .{});

    // 5. Boot the event loop engine natively
    try server.listen();
}

/// The transactional route handler executed whenever Firefox requests a file asset.
fn serveDocumentationFiles(ctx: *Context, req: *httpz.Request, res: *httpz.Response) !void {
    const target_path = req.url.path; //

    // Route root hits to index.html, otherwise format the string to look inside zig-out/docs
    const relative_path = if (std.mem.eql(u8, target_path, "/"))
        "zig-out/docs/index.html"
    else
        try std.fmt.allocPrint(res.arena, "zig-out/docs{s}", .{target_path});

    // VERIFIED 0.17.0 API: Open the file asynchronously from the current working directory
    const file = std.Io.Dir.cwd().openFile(ctx.io, relative_path, .{ .mode = .read_only }) catch {
        res.status = 404;
        res.body = "404 Not Found";
        return;
    };
    defer file.close(ctx.io); //

    // Read the file metadata size and content using the contextual loop handle
    const file_size = (try file.stat(ctx.io)).size;
    const file_content = try res.arena.alloc(u8, file_size);
    _ = try file.readPositionalAll(ctx.io, file_content, 0); //

    // Populate the response fields fields cleanly
    res.status = 200;
    res.header("content-type", mimeType(relative_path));
    res.body = file_content;
}

/// Helper function to supply clean browser multi-media type configurations
fn mimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    return "text/plain";
}
