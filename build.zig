const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("zds", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
        .optimize = optimize,
    });



    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.

    // Benchmark step
    const bench_exe = b.addExecutable(.{
        .name = "swissmap_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/swissmap_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_exe.root_module.addImport("zds", mod);

    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| {
        run_bench.addArgs(args);
    }

    const bench_step = b.step("swissmap_bench", "Run swissmap benchmarks");
    bench_step.dependOn(&run_bench.step);

    // Examples
    const example_step = b.step("examples", "Run examples");

    const basic_example = b.addExecutable(.{
        .name = "basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/swissmap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    basic_example.root_module.addImport("zds", mod);

    const run_basic = b.addRunArtifact(basic_example);
    example_step.dependOn(&run_basic.step);

    const rbtree_example = b.addExecutable(.{
        .name = "rbtree_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/rbtree.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    rbtree_example.root_module.addImport("zds", mod);

    const run_rbtree = b.addRunArtifact(rbtree_example);
    example_step.dependOn(&run_rbtree.step);

    // RBTree Benchmark
    const rbtree_bench = b.addExecutable(.{
        .name = "rbtree_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/rbtree_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    rbtree_bench.root_module.addImport("zds", mod);

    const run_rbtree_bench = b.addRunArtifact(rbtree_bench);
    if (b.args) |args| {
        run_rbtree_bench.addArgs(args);
    }

    const rbtree_bench_step = b.step("rbtree_bench", "Run RBTree benchmarks");
    rbtree_bench_step.dependOn(&run_rbtree_bench.step);

    // Radix Tree Example
    const radix_example = b.addExecutable(.{
        .name = "radix_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/radix.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    radix_example.root_module.addImport("zds", mod);

    const run_radix = b.addRunArtifact(radix_example);
    example_step.dependOn(&run_radix.step);

    // LRU Example
    const lru_example = b.addExecutable(.{
        .name = "lru_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/lru.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lru_example.root_module.addImport("zds", mod);

    const run_lru = b.addRunArtifact(lru_example);
    example_step.dependOn(&run_lru.step);

    // LRU Benchmark
    const lru_bench = b.addExecutable(.{
        .name = "lru_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/lru_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    lru_bench.root_module.addImport("zds", mod);

    const run_lru_bench = b.addRunArtifact(lru_bench);
    if (b.args) |args| {
        run_lru_bench.addArgs(args);
    }

    const lru_bench_step = b.step("lru_bench", "Run LRU benchmarks");
    lru_bench_step.dependOn(&run_lru_bench.step);


    // Radix Tree Benchmark
    const radix_bench = b.addExecutable(.{
        .name = "radix_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/radix_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    radix_bench.root_module.addImport("zds", mod);

    const run_radix_bench = b.addRunArtifact(radix_bench);
    if (b.args) |args| {
        run_radix_bench.addArgs(args);
    }

    const radix_bench_step = b.step("radix_bench", "Run RadixTree benchmarks");
    radix_bench_step.dependOn(&run_radix_bench.step);

    // BTree Example
    const btree_example = b.addExecutable(.{
        .name = "btree_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/btree.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    btree_example.root_module.addImport("zds", mod);

    const run_btree = b.addRunArtifact(btree_example);
    example_step.dependOn(&run_btree.step);

    // BTree Benchmark
    const btree_bench = b.addExecutable(.{
        .name = "btree_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/btree_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    btree_bench.root_module.addImport("zds", mod);

    const run_btree_bench = b.addRunArtifact(btree_bench);
    if (b.args) |args| {
        run_btree_bench.addArgs(args);
    }

    const btree_bench_step = b.step("btree_bench", "Run BTree benchmarks");
    btree_bench_step.dependOn(&run_btree_bench.step);
}
