const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard command-line configuration query
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Expose the source-based Zig Module for native Zig interpreters
    const gc_module = b.addModule("collectors", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 2. Build the freestanding binary archive archive for the C-FFI boundary
    const lib_artifact = b.addLibrary(.{
        .name = "collectors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib_artifact);

    // 3. Set up the Unit Testing Engine
    const unit_tests = b.addTest(.{
        .root_module = gc_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // =========================================================================
    // LAUNCH OUR SHAREABLE PIPELINE INSIDE OUR OWN BUILD
    // =========================================================================
    // Instead of duplicating code, your own build script just calls our
    // public helper function right here! We pass "serve-docs" as our local name.
    addServeDocsStep(b, "serve-docs", target, optimize);
}

/// Serve documentation build and provided by the library.
pub fn addServeDocsStep(
    b: *std.Build,
    step_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    // Physically generate the documentation from the source code module graph
    const obj_docs = b.addObject(.{
        .name = "docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const docs_dir = obj_docs.getEmittedDocs();

    // Install the website HTML files directly into 'zig-out/docs/'
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_dir,
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    // Create the user-facing command step hook using our parameter string
    const serve_step = b.step(step_name, "Host collectors Documentation");

    // Set up and compile our native tools/serve.zig server file
    const serve_tool_exe = b.addExecutable(.{
        .name = "doc_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/serve.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Wire up our karlseguin/http.zig dependency module
    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    serve_tool_exe.root_module.addImport("httpz", httpz_dep.module("httpz"));

    const run_server_cmd = b.addRunArtifact(serve_tool_exe);

    // Force the server executor step to wait until the fresh HTML generation is installed completely
    run_server_cmd.step.dependOn(&install_docs.step);
    serve_step.dependOn(&run_server_cmd.step);
}
