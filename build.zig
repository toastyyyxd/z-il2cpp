const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("z_il2cpp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const shared_step = b.step("shared", "Build mapped shared-library artifacts");

    const manifest_tool = b.addExecutable(.{
        .name = "gen-manifest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_manifest.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const gen_manifest = b.addRunArtifact(manifest_tool);
    const manifest_out = gen_manifest.addOutputFileArg("manifest.json");

    const strip_tool = b.addExecutable(.{
        .name = "strip-pe-tls",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/strip_pe_tls.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const shared_targets = [_]SharedTarget{
        .{
            .artifact_name = "z-il2cpp-windows-x86_64.pe",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
            .strip_tls = true,
        },
        .{
            .artifact_name = "z-il2cpp-linux-x86_64.so",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
            .strip_tls = false,
        },
        .{
            .artifact_name = "z-il2cpp-linux-aarch64.so",
            .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
            .strip_tls = false,
        },
    };

    for (shared_targets) |spec| {
        const shared_target = b.resolveTargetQuery(spec.query);
        const shared_module = b.createModule(.{
            .root_source_file = b.path("src/c.zig"),
            .target = shared_target,
            .optimize = .ReleaseSmall,
            .link_libc = false,
        });
        const library = b.addLibrary(.{
            .name = "z_il2cpp",
            .root_module = shared_module,
            .linkage = .dynamic,
        });

        const artifact: std.Build.LazyPath = if (spec.strip_tls)
            strippedPe(b, strip_tool, library)
        else
            library.getEmittedBin();

        const install = b.addInstallFileWithDir(artifact, .{ .custom = "shared" }, spec.artifact_name);
        shared_step.dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);

        gen_manifest.addArg(spec.artifact_name);
        gen_manifest.addFileArg(artifact);
    }

    const install_manifest = b.addInstallFileWithDir(manifest_out, .{ .custom = "shared" }, "manifest.json");
    shared_step.dependOn(&install_manifest.step);
    b.getInstallStep().dependOn(&install_manifest.step);

    const smoke_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const smoke_host = b.addExecutable(.{
        .name = "smoke-host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/smoke/host.zig"),
            .target = smoke_target,
            .optimize = .ReleaseSmall,
        }),
    });
    const smoke_host_install = b.addInstallArtifact(smoke_host, .{
        .dest_dir = .{ .override = .{ .custom = "smoke" } },
    });
    const smoke_host_step = b.step("smoke-host", "Build the smoke host");
    smoke_host_step.dependOn(&smoke_host_install.step);
    b.getInstallStep().dependOn(&smoke_host_install.step);

    const hooks_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu });
    const hooks_host = b.addExecutable(.{
        .name = "hooks-host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/hooks/host.zig"),
            .target = hooks_target,
            .optimize = .ReleaseSmall,
            .link_libc = true,
        }),
    });
    addMinHook(b, hooks_host.root_module);
    const hooks_host_install = b.addInstallArtifact(hooks_host, .{
        .dest_dir = .{ .override = .{ .custom = "hooks" } },
    });
    const hooks_host_step = b.step("hooks-host", "Build the hooks host");
    hooks_host_step.dependOn(&hooks_host_install.step);
    b.getInstallStep().dependOn(&hooks_host_install.step);

    const hooks_spike = b.addLibrary(.{
        .name = "zil2cpp-hook-spike",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/hooks/spike.zig"),
            .target = hooks_target,
            .optimize = .ReleaseSmall,
            .link_libc = true,
        }),
    });
    addMinHook(b, hooks_spike.root_module);
    const hooks_spike_install = b.addInstallArtifact(hooks_spike, .{
        .dest_dir = .{ .override = .{ .custom = "hooks" } },
    });
    const hooks_spike_step = b.step("hooks-spike", "Build the hook spike dll");
    hooks_spike_step.dependOn(&hooks_spike_install.step);
    b.getInstallStep().dependOn(&hooks_spike_install.step);

    const test_step = b.step("test", "Run unit tests");

    const root_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(root_tests).step);

    const shared_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/c.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(shared_tests).step);

    const strip_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/strip_pe_tls.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(strip_tests).step);

    const manifest_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/gen_manifest.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(manifest_tests).step);

    const fmt = b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("src"), b.path("tools"), b.path("tests") },
        .check = true,
    });
    const fmt_step = b.step("fmt", "Formatting check");
    fmt_step.dependOn(&fmt.step);
}

const minhook_sources = [_][]const u8{
    "third_party/minhook/src/buffer.c",
    "third_party/minhook/src/hook.c",
    "third_party/minhook/src/trampoline.c",
    "third_party/minhook/src/hde/hde32.c",
    "third_party/minhook/src/hde/hde64.c",
};

fn addMinHook(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFiles(.{ .files = &minhook_sources, .flags = &.{} });
    module.addIncludePath(b.path("third_party/minhook/include"));
    module.addIncludePath(b.path("third_party/minhook/src"));
    module.addIncludePath(b.path("third_party/minhook/src/hde"));
}

const SharedTarget = struct {
    artifact_name: []const u8,
    query: std.Target.Query,
    strip_tls: bool,
};

fn strippedPe(
    b: *std.Build,
    strip_tool: *std.Build.Step.Compile,
    library: *std.Build.Step.Compile,
) std.Build.LazyPath {
    const strip = b.addRunArtifact(strip_tool);
    strip.addFileArg(library.getEmittedBin());
    return strip.addOutputFileArg("stripped.pe");
}
