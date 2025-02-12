const std = @import("../std.zig");
const assert = std.debug.assert;
const build = std.build;
const fs = std.fs;
const macho = std.macho;
const math = std.math;
const mem = std.mem;
const testing = std.testing;

const CheckObjectStep = @This();

const Allocator = mem.Allocator;
const Builder = build.Builder;
const Step = build.Step;

pub const base_id = .check_obj;

step: Step,
builder: *Builder,
source: build.FileSource,
max_bytes: usize = 20 * 1024 * 1024,
checks: std.ArrayList(Check),
dump_symtab: bool = false,
obj_format: std.Target.ObjectFormat,

pub fn create(builder: *Builder, source: build.FileSource, obj_format: std.Target.ObjectFormat) *CheckObjectStep {
    const gpa = builder.allocator;
    const self = gpa.create(CheckObjectStep) catch unreachable;
    self.* = .{
        .builder = builder,
        .step = Step.init(.check_file, "CheckObject", gpa, make),
        .source = source.dupe(builder),
        .checks = std.ArrayList(Check).init(gpa),
        .obj_format = obj_format,
    };
    self.source.addStepDependencies(&self.step);
    return self;
}

/// There two types of actions currently suported:
/// * `.match` - is the main building block of standard matchers with optional eat-all token `{*}`
/// and extractors by name such as `{n_value}`. Please note this action is very simplistic in nature
/// i.e., it won't really handle edge cases/nontrivial examples. But given that we do want to use
/// it mainly to test the output of our object format parser-dumpers when testing the linkers, etc.
/// it should be plenty useful in its current form.
/// * `.compute_cmp` - can be used to perform an operation on the extracted global variables
/// using the MatchAction. It currently only supports an addition. The operation is required
/// to be specified in Reverse Polish Notation to ease in operator-precedence parsing (well,
/// to avoid any parsing really).
/// For example, if the two extracted values were saved as `vmaddr` and `entryoff` respectively
/// they could then be added with this simple program `vmaddr entryoff +`.
const Action = struct {
    tag: enum { match, compute_cmp },
    phrase: []const u8,
    expected: ?ComputeCompareExpected = null,

    /// Will return true if the `phrase` was found in the `haystack`.
    /// Some examples include:
    ///
    /// LC 0                     => will match in its entirety
    /// vmaddr {vmaddr}          => will match `vmaddr` and then extract the following value as u64
    ///                             and save under `vmaddr` global name (see `global_vars` param)
    /// name {*}libobjc{*}.dylib => will match `name` followed by a token which contains `libobjc` and `.dylib`
    ///                             in that order with other letters in between
    fn match(act: Action, haystack: []const u8, global_vars: anytype) !bool {
        assert(act.tag == .match);

        var hay_it = mem.tokenize(u8, mem.trim(u8, haystack, " "), " ");
        var needle_it = mem.tokenize(u8, mem.trim(u8, act.phrase, " "), " ");

        while (needle_it.next()) |needle_tok| {
            const hay_tok = hay_it.next() orelse return false;

            if (mem.indexOf(u8, needle_tok, "{*}")) |index| {
                // We have fuzzy matchers within the search pattern, so we match substrings.
                var start = index;
                var n_tok = needle_tok;
                var h_tok = hay_tok;
                while (true) {
                    n_tok = n_tok[start + 3 ..];
                    const inner = if (mem.indexOf(u8, n_tok, "{*}")) |sub_end|
                        n_tok[0..sub_end]
                    else
                        n_tok;
                    if (mem.indexOf(u8, h_tok, inner) == null) return false;
                    start = mem.indexOf(u8, n_tok, "{*}") orelse break;
                }
            } else if (mem.startsWith(u8, needle_tok, "{")) {
                const closing_brace = mem.indexOf(u8, needle_tok, "}") orelse return error.MissingClosingBrace;
                if (closing_brace != needle_tok.len - 1) return error.ClosingBraceNotLast;

                const name = needle_tok[1..closing_brace];
                if (name.len == 0) return error.MissingBraceValue;
                const value = try std.fmt.parseInt(u64, hay_tok, 16);
                try global_vars.putNoClobber(name, value);
            } else {
                if (!mem.eql(u8, hay_tok, needle_tok)) return false;
            }
        }

        return true;
    }

    /// Will return true if the `phrase` is correctly parsed into an RPN program and
    /// its reduced, computed value compares using `op` with the expected value, either
    /// a literal or another extracted variable.
    fn computeCmp(act: Action, gpa: Allocator, global_vars: anytype) !bool {
        var op_stack = std.ArrayList(enum { add }).init(gpa);
        var values = std.ArrayList(u64).init(gpa);

        var it = mem.tokenize(u8, act.phrase, " ");
        while (it.next()) |next| {
            if (mem.eql(u8, next, "+")) {
                try op_stack.append(.add);
            } else {
                const val = global_vars.get(next) orelse {
                    std.debug.print(
                        \\
                        \\========= Variable was not extracted: ===========
                        \\{s}
                        \\
                    , .{next});
                    return error.UnknownVariable;
                };
                try values.append(val);
            }
        }

        var op_i: usize = 1;
        var reduced: u64 = values.items[0];
        for (op_stack.items) |op| {
            const other = values.items[op_i];
            switch (op) {
                .add => {
                    reduced += other;
                },
            }
        }

        const exp_value = switch (act.expected.?.value) {
            .variable => |name| global_vars.get(name) orelse {
                std.debug.print(
                    \\
                    \\========= Variable was not extracted: ===========
                    \\{s}
                    \\
                , .{name});
                return error.UnknownVariable;
            },
            .literal => |x| x,
        };
        return math.compare(reduced, act.expected.?.op, exp_value);
    }
};

const ComputeCompareExpected = struct {
    op: math.CompareOperator,
    value: union(enum) {
        variable: []const u8,
        literal: u64,
    },

    pub fn format(
        value: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s} ", .{@tagName(value.op)});
        switch (value.value) {
            .variable => |name| try writer.writeAll(name),
            .literal => |x| try writer.print("{x}", .{x}),
        }
    }
};

const Check = struct {
    builder: *Builder,
    actions: std.ArrayList(Action),

    fn create(b: *Builder) Check {
        return .{
            .builder = b,
            .actions = std.ArrayList(Action).init(b.allocator),
        };
    }

    fn match(self: *Check, phrase: []const u8) void {
        self.actions.append(.{
            .tag = .match,
            .phrase = self.builder.dupe(phrase),
        }) catch unreachable;
    }

    fn computeCmp(self: *Check, phrase: []const u8, expected: ComputeCompareExpected) void {
        self.actions.append(.{
            .tag = .compute_cmp,
            .phrase = self.builder.dupe(phrase),
            .expected = expected,
        }) catch unreachable;
    }
};

/// Creates a new sequence of actions with `phrase` as the first anchor searched phrase.
pub fn checkStart(self: *CheckObjectStep, phrase: []const u8) void {
    var new_check = Check.create(self.builder);
    new_check.match(phrase);
    self.checks.append(new_check) catch unreachable;
}

/// Adds another searched phrase to the latest created Check with `CheckObjectStep.checkStart(...)`.
/// Asserts at least one check already exists.
pub fn checkNext(self: *CheckObjectStep, phrase: []const u8) void {
    assert(self.checks.items.len > 0);
    const last = &self.checks.items[self.checks.items.len - 1];
    last.match(phrase);
}

/// Creates a new check checking specifically symbol table parsed and dumped from the object
/// file.
/// Issuing this check will force parsing and dumping of the symbol table.
pub fn checkInSymtab(self: *CheckObjectStep) void {
    self.dump_symtab = true;
    const symtab_label = switch (self.obj_format) {
        .macho => MachODumper.symtab_label,
        else => @panic("TODO other parsers"),
    };
    self.checkStart(symtab_label);
}

/// Creates a new standalone, singular check which allows running simple binary operations
/// on the extracted variables. It will then compare the reduced program with the value of
/// the expected variable.
pub fn checkComputeCompare(
    self: *CheckObjectStep,
    program: []const u8,
    expected: ComputeCompareExpected,
) void {
    var new_check = Check.create(self.builder);
    new_check.computeCmp(program, expected);
    self.checks.append(new_check) catch unreachable;
}

fn make(step: *Step) !void {
    const self = @fieldParentPtr(CheckObjectStep, "step", step);

    const gpa = self.builder.allocator;
    const src_path = self.source.getPath(self.builder);
    const contents = try fs.cwd().readFileAlloc(gpa, src_path, self.max_bytes);

    const output = switch (self.obj_format) {
        .macho => try MachODumper.parseAndDump(contents, .{
            .gpa = gpa,
            .dump_symtab = self.dump_symtab,
        }),
        .elf => @panic("TODO elf parser"),
        .coff => @panic("TODO coff parser"),
        .wasm => @panic("TODO wasm parser"),
        else => unreachable,
    };

    var vars = std.StringHashMap(u64).init(gpa);

    for (self.checks.items) |chk| {
        var it = mem.tokenize(u8, output, "\r\n");
        for (chk.actions.items) |act| {
            switch (act.tag) {
                .match => {
                    while (it.next()) |line| {
                        if (try act.match(line, &vars)) break;
                    } else {
                        std.debug.print(
                            \\
                            \\========= Expected to find: ==========================
                            \\{s}
                            \\========= But parsed file does not contain it: =======
                            \\{s}
                            \\
                        , .{ act.phrase, output });
                        return error.TestFailed;
                    }
                },
                .compute_cmp => {
                    const res = act.computeCmp(gpa, vars) catch |err| switch (err) {
                        error.UnknownVariable => {
                            std.debug.print(
                                \\========= From parsed file: =====================
                                \\{s}
                                \\
                            , .{output});
                            return error.TestFailed;
                        },
                        else => |e| return e,
                    };
                    if (!res) {
                        std.debug.print(
                            \\
                            \\========= Comparison failed for action: ===========
                            \\{s} {s}
                            \\========= From parsed file: =======================
                            \\{s}
                            \\
                        , .{ act.phrase, act.expected.?, output });
                        return error.TestFailed;
                    }
                },
            }
        }
    }
}

const Opts = struct {
    gpa: ?Allocator = null,
    dump_symtab: bool = false,
};

const MachODumper = struct {
    const symtab_label = "symtab";

    fn parseAndDump(bytes: []const u8, opts: Opts) ![]const u8 {
        const gpa = opts.gpa orelse unreachable; // MachO dumper requires an allocator
        var stream = std.io.fixedBufferStream(bytes);
        const reader = stream.reader();

        const hdr = try reader.readStruct(macho.mach_header_64);
        if (hdr.magic != macho.MH_MAGIC_64) {
            return error.InvalidMagicNumber;
        }

        var output = std.ArrayList(u8).init(gpa);
        const writer = output.writer();

        var symtab_cmd: ?macho.symtab_command = null;
        var i: u16 = 0;
        while (i < hdr.ncmds) : (i += 1) {
            var cmd = try macho.LoadCommand.read(gpa, reader);

            if (opts.dump_symtab and cmd.cmd() == .SYMTAB) {
                symtab_cmd = cmd.symtab;
            }

            try dumpLoadCommand(cmd, i, writer);
            try writer.writeByte('\n');
        }

        if (symtab_cmd) |cmd| {
            try writer.writeAll(symtab_label ++ "\n");
            const strtab = bytes[cmd.stroff..][0..cmd.strsize];
            const raw_symtab = bytes[cmd.symoff..][0 .. cmd.nsyms * @sizeOf(macho.nlist_64)];
            const symtab = mem.bytesAsSlice(macho.nlist_64, raw_symtab);

            for (symtab) |sym| {
                if (sym.stab()) continue;
                const sym_name = mem.sliceTo(@ptrCast([*:0]const u8, strtab.ptr + sym.n_strx), 0);
                try writer.print("{s} {x}\n", .{ sym_name, sym.n_value });
            }
        }

        return output.toOwnedSlice();
    }

    fn dumpLoadCommand(lc: macho.LoadCommand, index: u16, writer: anytype) !void {
        // print header first
        try writer.print(
            \\LC {d}
            \\cmd {s}
            \\cmdsize {d}
        , .{ index, @tagName(lc.cmd()), lc.cmdsize() });

        switch (lc.cmd()) {
            .SEGMENT_64 => {
                // TODO dump section headers
                const seg = lc.segment.inner;
                try writer.writeByte('\n');
                try writer.print(
                    \\segname {s}
                    \\vmaddr {x}
                    \\vmsize {x}
                    \\fileoff {x}
                    \\filesz {x}
                , .{
                    seg.segName(),
                    seg.vmaddr,
                    seg.vmsize,
                    seg.fileoff,
                    seg.filesize,
                });

                for (lc.segment.sections.items) |sect| {
                    try writer.writeByte('\n');
                    try writer.print(
                        \\sectname {s}
                        \\addr {x}
                        \\size {x}
                        \\offset {x}
                        \\align {x}
                    , .{
                        sect.sectName(),
                        sect.addr,
                        sect.size,
                        sect.offset,
                        sect.@"align",
                    });
                }
            },

            .ID_DYLIB,
            .LOAD_DYLIB,
            => {
                const dylib = lc.dylib.inner.dylib;
                try writer.writeByte('\n');
                try writer.print(
                    \\name {s}
                    \\timestamp {d}
                    \\current version {x}
                    \\compatibility version {x}
                , .{
                    mem.sliceTo(lc.dylib.data, 0),
                    dylib.timestamp,
                    dylib.current_version,
                    dylib.compatibility_version,
                });
            },

            .MAIN => {
                try writer.writeByte('\n');
                try writer.print(
                    \\entryoff {x}
                    \\stacksize {x}
                , .{ lc.main.entryoff, lc.main.stacksize });
            },

            .RPATH => {
                try writer.writeByte('\n');
                try writer.print(
                    \\path {s}
                , .{
                    mem.sliceTo(lc.rpath.data, 0),
                });
            },

            else => {},
        }
    }
};
