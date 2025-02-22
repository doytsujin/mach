const std = @import("std");
const Builder = std.build.Builder;

const ft_root = thisDir() ++ "/upstream/freetype";
const ft_include_path = ft_root ++ "/include";
const hb_root = thisDir() ++ "/upstream/harfbuzz";
const hb_include_path = hb_root ++ "/src";
const brotli_root = thisDir() ++ "/upstream/brotli";

const c_pkg = std.build.Pkg{
    .name = "c",
    .source = .{ .path = thisDir() ++ "/src/c.zig" },
};

const utils_pkg = std.build.Pkg{
    .name = "utils",
    .source = .{ .path = thisDir() ++ "/src/utils.zig" },
};

pub const pkg = std.build.Pkg{
    .name = "freetype",
    .source = .{ .path = thisDir() ++ "/src/freetype/main.zig" },
    .dependencies = &.{ c_pkg, utils_pkg },
};

pub const harfbuzz_pkg = std.build.Pkg{
    .name = "harfbuzz",
    .source = .{ .path = thisDir() ++ "/src/harfbuzz/main.zig" },
    .dependencies = &.{ c_pkg, utils_pkg, pkg },
};

pub const Options = struct {
    freetype: FreetypeOptions = .{},
    harfbuzz: ?HarfbuzzOptions = null,
};

pub const FreetypeOptions = struct {
    /// the path you specify freetype options
    /// via `ftoptions.h` and `ftmodule.h`
    /// e.g `test/ft/`
    ft_config_path: ?[]const u8 = null,
    brotli: bool = false,
};

pub const HarfbuzzOptions = struct {};

pub fn build(b: *std.build.Builder) !void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const freetype_tests = b.addTestSource(pkg.source);
    freetype_tests.setBuildMode(mode);
    freetype_tests.setTarget(target);
    freetype_tests.addPackage(c_pkg);
    freetype_tests.addPackage(utils_pkg);
    link(b, freetype_tests, .{});

    const harfbuzz_tests = b.addTestSource(harfbuzz_pkg.source);
    harfbuzz_tests.setBuildMode(mode);
    harfbuzz_tests.setTarget(target);
    harfbuzz_tests.addPackage(c_pkg);
    harfbuzz_tests.addPackage(utils_pkg);
    harfbuzz_tests.addPackage(pkg);
    link(b, harfbuzz_tests, .{ .harfbuzz = .{} });

    const main_tests = b.addTest("test/main.zig");
    main_tests.setBuildMode(mode);
    main_tests.setTarget(target);
    main_tests.addPackage(c_pkg);
    main_tests.addPackage(pkg);
    link(b, main_tests, .{ .freetype = .{
        .ft_config_path = "./test/ft",
        .brotli = true,
    } });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&freetype_tests.step);
    test_step.dependOn(&harfbuzz_tests.step);
    test_step.dependOn(&main_tests.step);

    inline for ([_][]const u8{
        "single-glyph",
        "glyph-to-svg",
    }) |example| {
        const example_exe = b.addExecutable("example-" ++ example, "examples/" ++ example ++ ".zig");
        example_exe.setBuildMode(mode);
        example_exe.setTarget(target);
        example_exe.addPackage(pkg);
        link(b, example_exe, .{});
        example_exe.install();

        const example_compile_step = b.step("example-" ++ example, "Compile '" ++ example ++ "' example");
        example_compile_step.dependOn(b.getInstallStep());

        const example_run_cmd = example_exe.run();
        example_run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            example_run_cmd.addArgs(args);
        }

        const example_run_step = b.step("run-example-" ++ example, "Run '" ++ example ++ "' example");
        example_run_step.dependOn(&example_run_cmd.step);
    }
}

pub fn link(b: *Builder, step: *std.build.LibExeObjStep, options: Options) void {
    const ft_lib = buildFreetype(b, step, options.freetype);
    step.linkLibrary(ft_lib);
    step.addIncludePath(ft_include_path);
    step.addIncludePath(hb_include_path);

    if (options.harfbuzz) |hb_options| {
        const hb_lib = buildHarfbuzz(b, step, hb_options);
        step.linkLibrary(hb_lib);
    }
}

pub fn buildFreetype(b: *Builder, step: *std.build.LibExeObjStep, options: FreetypeOptions) *std.build.LibExeObjStep {
    // TODO(build-system): https://github.com/hexops/mach/issues/229#issuecomment-1100958939
    ensureDependencySubmodule(b.allocator, "upstream") catch unreachable;

    const main_abs = ft_root ++ "/src/base/ftbase.c";
    const lib = b.addStaticLibrary("freetype", main_abs);
    lib.defineCMacro("FT2_BUILD_LIBRARY", "1");
    lib.setBuildMode(step.build_mode);
    lib.setTarget(step.target);
    lib.linkLibC();
    lib.addIncludePath(ft_include_path);

    if (options.ft_config_path) |path|
        lib.addIncludePath(path);

    if (options.brotli) {
        const brotli_lib = buildBrotli(b, step);
        step.linkLibrary(brotli_lib);
        lib.defineCMacro("FT_REQUIRE_BROTLI", "1");
    }

    const target = (std.zig.system.NativeTargetInfo.detect(b.allocator, step.target) catch unreachable).target;

    if (target.os.tag == .windows) {
        lib.addCSourceFile(ft_root ++ "/builds/windows/ftsystem.c", &.{});
        lib.addCSourceFile(ft_root ++ "/builds/windows/ftdebug.c", &.{});
    } else {
        lib.addCSourceFile(ft_root ++ "/src/base/ftsystem.c", &.{});
        lib.addCSourceFile(ft_root ++ "/src/base/ftdebug.c", &.{});
    }
    if (target.os.tag.isBSD() or target.os.tag == .linux) {
        lib.defineCMacro("HAVE_UNISTD_H", "1");
        lib.defineCMacro("HAVE_FCNTL_H", "1");
        lib.addCSourceFile(ft_root ++ "/builds/unix/ftsystem.c", &.{});
        if (target.os.tag == .macos) {
            lib.addCSourceFile(ft_root ++ "/src/base/ftmac.c", &.{});
        }
    }

    lib.addCSourceFiles(freetype_base_sources, &.{});
    lib.install();
    return lib;
}

pub fn buildHarfbuzz(b: *Builder, step: *std.build.LibExeObjStep, options: HarfbuzzOptions) *std.build.LibExeObjStep {
    _ = options;
    const main_abs = hb_root ++ "/src/harfbuzz.cc";
    const lib = b.addStaticLibrary("harfbuzz", main_abs);
    lib.setBuildMode(step.build_mode);
    lib.setTarget(step.target);
    lib.linkLibCpp();
    lib.addIncludePath(hb_include_path);
    lib.addIncludePath(ft_include_path);
    lib.defineCMacro("HAVE_FREETYPE", "1");
    lib.install();
    return lib;
}

pub fn buildBrotli(b: *Builder, step: *std.build.LibExeObjStep) *std.build.LibExeObjStep {
    const main_abs = brotli_root ++ "/common/constants.c";
    const lib = b.addStaticLibrary("brotli", main_abs);
    lib.setBuildMode(step.build_mode);
    lib.setTarget(step.target);
    lib.linkLibC();
    lib.addIncludePath(brotli_root ++ "/include");
    lib.addCSourceFiles(brotli_base_sources, &.{});
    lib.install();
    return lib;
}

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

fn ensureDependencySubmodule(allocator: std.mem.Allocator, path: []const u8) !void {
    if (std.process.getEnvVarOwned(allocator, "NO_ENSURE_SUBMODULES")) |no_ensure_submodules| {
        if (std.mem.eql(u8, no_ensure_submodules, "true")) return;
    } else |_| {}
    var child = std.ChildProcess.init(&.{ "git", "submodule", "update", "--init", path }, allocator);
    child.cwd = thisDir();
    child.stderr = std.io.getStdErr();
    child.stdout = std.io.getStdOut();

    _ = try child.spawnAndWait();
}

const freetype_base_sources = &[_][]const u8{
    ft_root ++ "/src/autofit/autofit.c",
    ft_root ++ "/src/base/ftbbox.c",
    ft_root ++ "/src/base/ftbdf.c",
    ft_root ++ "/src/base/ftbitmap.c",
    ft_root ++ "/src/base/ftcid.c",
    ft_root ++ "/src/base/ftfstype.c",
    ft_root ++ "/src/base/ftgasp.c",
    ft_root ++ "/src/base/ftglyph.c",
    ft_root ++ "/src/base/ftgxval.c",
    ft_root ++ "/src/base/ftinit.c",
    ft_root ++ "/src/base/ftmm.c",
    ft_root ++ "/src/base/ftotval.c",
    ft_root ++ "/src/base/ftpatent.c",
    ft_root ++ "/src/base/ftpfr.c",
    ft_root ++ "/src/base/ftstroke.c",
    ft_root ++ "/src/base/ftsynth.c",
    ft_root ++ "/src/base/fttype1.c",
    ft_root ++ "/src/base/ftwinfnt.c",
    ft_root ++ "/src/bdf/bdf.c",
    ft_root ++ "/src/bzip2/ftbzip2.c",
    ft_root ++ "/src/cache/ftcache.c",
    ft_root ++ "/src/cff/cff.c",
    ft_root ++ "/src/cid/type1cid.c",
    ft_root ++ "/src/gzip/ftgzip.c",
    ft_root ++ "/src/lzw/ftlzw.c",
    ft_root ++ "/src/pcf/pcf.c",
    ft_root ++ "/src/pfr/pfr.c",
    ft_root ++ "/src/psaux/psaux.c",
    ft_root ++ "/src/pshinter/pshinter.c",
    ft_root ++ "/src/psnames/psnames.c",
    ft_root ++ "/src/raster/raster.c",
    ft_root ++ "/src/sdf/sdf.c",
    ft_root ++ "/src/sfnt/sfnt.c",
    ft_root ++ "/src/smooth/smooth.c",
    ft_root ++ "/src/svg/svg.c",
    ft_root ++ "/src/truetype/truetype.c",
    ft_root ++ "/src/type1/type1.c",
    ft_root ++ "/src/type42/type42.c",
    ft_root ++ "/src/winfonts/winfnt.c",
};

const brotli_base_sources = &[_][]const u8{
    brotli_root ++ "/enc/backward_references.c",
    brotli_root ++ "/enc/fast_log.c",
    brotli_root ++ "/enc/histogram.c",
    brotli_root ++ "/enc/cluster.c",
    brotli_root ++ "/enc/command.c",
    brotli_root ++ "/enc/compress_fragment_two_pass.c",
    brotli_root ++ "/enc/entropy_encode.c",
    brotli_root ++ "/enc/bit_cost.c",
    brotli_root ++ "/enc/memory.c",
    brotli_root ++ "/enc/backward_references_hq.c",
    brotli_root ++ "/enc/dictionary_hash.c",
    brotli_root ++ "/enc/encoder_dict.c",
    brotli_root ++ "/enc/block_splitter.c",
    brotli_root ++ "/enc/compress_fragment.c",
    brotli_root ++ "/enc/literal_cost.c",
    brotli_root ++ "/enc/brotli_bit_stream.c",
    brotli_root ++ "/enc/encode.c",
    brotli_root ++ "/enc/static_dict.c",
    brotli_root ++ "/enc/utf8_util.c",
    brotli_root ++ "/enc/metablock.c",
    brotli_root ++ "/dec/decode.c",
    brotli_root ++ "/dec/bit_reader.c",
    brotli_root ++ "/dec/huffman.c",
    brotli_root ++ "/dec/state.c",
    brotli_root ++ "/common/context.c",
    brotli_root ++ "/common/dictionary.c",
    brotli_root ++ "/common/transform.c",
    brotli_root ++ "/common/platform.c",
};
