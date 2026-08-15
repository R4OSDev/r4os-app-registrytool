const r4os = @import("r4os");
const r4std = @import("r4std");
const registry = r4os.registry_core;
const settings = r4std.settings;

const hive_max: usize = 32768;
const export_max: usize = 32768;
const import_max: usize = 32768;
const migrate_max: usize = 32768;
const write_alloc_max: usize = hive_max;
const selftest_max: usize = 512;
const set_data_max: usize = 2048;
const path_max: usize = 256;
const path_scratch_count: usize = 8;
const path_pool_max: usize = 16384;
const key_depth_max: usize = 32;
const key_build_max: usize = 256;
const value_collect_max: usize = 512;

var empty_buffer: [0]u8 = .{};
var hive_buffer: []u8 = empty_buffer[0..];
var export_buffer: []u8 = empty_buffer[0..];
var import_buffer: []u8 = empty_buffer[0..];
var migrate_buffer: []u8 = empty_buffer[0..];
var write_alloc_buffer: []u8 = empty_buffer[0..];
var set_data_buffer: []u8 = empty_buffer[0..];
var path_pool_buffer: []u8 = empty_buffer[0..];
var selftest_buffer: []u8 = empty_buffer[0..];
const path_scratch_init: [path_max + 1]u8 = [_]u8{0xa5} ** (path_max + 1);
const empty_build_value: registry.BuildValue = .{ .key_path = "", .name = "", .value_type = .string, .data = "" };
const empty_build_key: BuildKey = .{ .parent = registry.invalid_index, .name = "" };
var path_scratch: [path_scratch_count][path_max + 1]u8 = [_][path_max + 1]u8{path_scratch_init} ** path_scratch_count;
var value_collect_buffer: [value_collect_max]registry.BuildValue = [_]registry.BuildValue{empty_build_value} ** value_collect_max;
var key_build_buffer: [key_build_max]BuildKey = [_]BuildKey{empty_build_key} ** key_build_max;
var value_key_index_buffer: [value_collect_max]u32 = [_]u32{registry.invalid_index} ** value_collect_max;
var flat_key_order_buffer: [key_build_max]u32 = [_]u32{registry.invalid_index} ** key_build_max;

pub fn r4_app_main(contract: *r4os.App) i32 {
    if (!r4std.init(contract.startContext())) return r4os.abi.err_no_group;
    const allocator = contract.allocator() orelse return r4os.abi.err_no_fn;
    const registry_api = contract.registry() orelse return r4os.abi.err_no_fn;
    var app = App{ .sys = contract.system(), .allocator = allocator, .registry_api = registry_api };
    const args = trim(contract.args());
    if (!initScratch(&app)) return 1;
    defer freeScratch(&app);
    return run(&app, args);
}

const App = struct {
    sys: r4os.r4sys.Context,
    allocator: @import("std").mem.Allocator,
    registry_api: r4os.Registry,

    fn write(self: *App, text: []const u8) void {
        self.sys.write(text);
    }

    fn line(self: *App, text: []const u8) void {
        self.sys.write(text);
        self.sys.write("\r\n");
    }

    fn dec(self: *App, value: u64) void {
        writeDec(self, value);
    }
};

fn initScratch(app: *App) bool {
    const allocator = app.allocator;
    hive_buffer = allocator.alignedAlloc(u8, .fromByteUnits(16), hive_max) catch return scratchFail(app);
    export_buffer = allocator.alignedAlloc(u8, .fromByteUnits(16), export_max) catch return scratchFail(app);
    import_buffer = allocator.alignedAlloc(u8, .fromByteUnits(16), import_max) catch return scratchFail(app);
    migrate_buffer = allocator.alignedAlloc(u8, .fromByteUnits(16), migrate_max) catch return scratchFail(app);
    write_alloc_buffer = allocator.alignedAlloc(u8, .fromByteUnits(16), write_alloc_max) catch return scratchFail(app);
    set_data_buffer = allocator.alignedAlloc(u8, .fromByteUnits(16), set_data_max) catch return scratchFail(app);
    path_pool_buffer = allocator.alignedAlloc(u8, .fromByteUnits(16), path_pool_max) catch return scratchFail(app);
    selftest_buffer = allocator.alignedAlloc(u8, .fromByteUnits(16), selftest_max) catch return scratchFail(app);
    return true;
}

fn scratchFail(app: *App) bool {
    freeScratch(app);
    app.line("REG: scratch-memory");
    // 0.56.34f-Diagnose: warum verweigert der VM-Allocator?
    // (0.57.2: Quelle ist die R4SYS-Gruppentabelle - vm_* dort ist das
    // supportsVmApi-Gate.)
    app.write("REG: alloc-diag r4sys-table v=");
    app.dec(@intCast(app.sys.tableAbiVersion()));
    app.write(" size=");
    app.dec(@intCast(app.sys.tableSize()));
    app.write(" vm=");
    app.dec(if (app.sys.hasFn("vm_reserve")) 1 else 0);
    const astats = app.sys.allocatorStats();
    app.write(" alloc_errors=");
    app.dec(astats.allocation_errors);
    app.write(" small_regions=");
    app.dec(@intCast(astats.small_regions));
    app.write("\r\n");
    return false;
}

fn freeScratch(app: *App) void {
    freeScratchBuffer(app, &hive_buffer);
    freeScratchBuffer(app, &export_buffer);
    freeScratchBuffer(app, &import_buffer);
    freeScratchBuffer(app, &migrate_buffer);
    freeScratchBuffer(app, &write_alloc_buffer);
    freeScratchBuffer(app, &set_data_buffer);
    freeScratchBuffer(app, &path_pool_buffer);
    freeScratchBuffer(app, &selftest_buffer);
}

fn freeScratchBuffer(app: *App, buffer: *[]u8) void {
    if (buffer.*.len != 0) {
        app.allocator.free(buffer.*);
        buffer.* = empty_buffer[0..];
    }
}

fn pathScratch(index: usize) []u8 {
    return path_scratch[index][0..];
}

const Token = struct {
    token: []const u8,
    rest: []const u8,
};

const ExportOut = struct {
    app: *App,
    len: usize = 0,
    overflow: bool = false,
    echo: bool = true,

    fn write(self: *ExportOut, text: []const u8) void {
        if (self.echo) self.app.write(text);
        if (self.len >= export_buffer.len) {
            self.overflow = true;
            return;
        }
        const count = @min(text.len, export_buffer.len - self.len);
        if (count < text.len) self.overflow = true;
        if (count != 0) {
            @memcpy(export_buffer[self.len .. self.len + count], text[0..count]);
            self.len += count;
        }
    }

    fn line(self: *ExportOut, text: []const u8) void {
        self.write(text);
        self.write("\r\n");
    }
};

const LoadedHive = struct {
    present: bool = false,
    valid: bool = false,
    view: ?registry.HiveView = null,
};

const ImportedHive = struct {
    kind: registry.HiveKind,
    bytes: []const u8,
};

const ValueList = struct {
    count: usize = 0,
    path_len: usize = 0,

    fn init() ValueList {
        return .{};
    }

    fn items(self: *const ValueList) []const registry.BuildValue {
        return value_collect_buffer[0..self.count];
    }

    fn append(self: *ValueList, key_path: []const u8, name: []const u8, value_type: registry.ValueType, data: []const u8) bool {
        if (self.count >= value_collect_buffer.len) return false;
        value_collect_buffer[self.count] = .{
            .key_path = key_path,
            .name = name,
            .value_type = value_type,
            .data = data,
        };
        self.count += 1;
        return true;
    }

    fn appendPath(self: *ValueList, text: []const u8) ?[]const u8 {
        if (self.path_len + text.len > path_pool_buffer.len) return null;
        const start = self.path_len;
        @memcpy(path_pool_buffer[start .. start + text.len], text);
        self.path_len += text.len;
        return path_pool_buffer[start..self.path_len];
    }

    fn appendByte(self: *ValueList, byte: u8) bool {
        if (self.path_len >= path_pool_buffer.len) return false;
        path_pool_buffer[self.path_len] = byte;
        self.path_len += 1;
        return true;
    }

    fn appendBytes(self: *ValueList, bytes: []const u8) ?[]const u8 {
        if (self.path_len + bytes.len > path_pool_buffer.len) return null;
        const start = self.path_len;
        if (bytes.len != 0) @memcpy(path_pool_buffer[start .. start + bytes.len], bytes);
        self.path_len += bytes.len;
        return path_pool_buffer[start..self.path_len];
    }
};

const BuildKey = struct {
    parent: u32,
    name: []const u8,
    flat_index: u32 = registry.invalid_index,
};

const MigrateTarget = enum {
    assoc,
    time,
    desktop,
};

const CompositeSetting = struct {
    id: []const u8,
    field: []const u8,
};

const migrate_assoc_selftest =
    \\# R4OS settings
    \\R4S_FORMAT=1
    \\SCHEMA=APPASSOC
    \\APP.NOTEPAD.TITLE=Notepad
    \\APP.NOTEPAD.PATH=C:\R4OS\SOFTWARE\DESKTOP\NOTEPAD.R4X
    \\APP.NOTEPAD.POLICY=gui
    \\APP.NOTEPAD.ARGS=%1
    \\EXT.TXT.APP=NOTEPAD
    \\EXT.TXT.TYPE=Text
    \\EXT.TXT.SHORT=Text
    \\EXT.TXT.PREFIX=[TXT]
    \\EXT.TXT.RANK=3
;

const migrate_time_selftest =
    \\# R4OS settings
    \\R4S_FORMAT=1
    \\SCHEMA=TIME
    \\TIMEZONE=Europe/Berlin
    \\UTC_OFFSET_MINUTES=60
;

const migrate_desktop_selftest =
    \\# R4OS settings
    \\R4S_FORMAT=1
    \\SCHEMA=DESKTOP
    \\DESKTOP_BG=008080
    \\TASKBAR_CLOCK=ON
    \\UI_FONT=C:\R4OS\FONTS\TERMINAL8.R4F
    \\UI_FONT_SIZE=8
    \\TERMINAL_FONT=C:\R4OS\FONTS\TERMINAL8.R4F
    \\TERMINAL_FONT_SIZE=8
    \\TERMINAL_CODEPAGE=437
;

fn run(app: *App, args: []const u8) i32 {
    const first = takeToken(args) orelse {
        usage(app);
        return 1;
    };

    if (equalsIgnoreCase(first.token, "/?") or equalsIgnoreCase(first.token, "HELP")) {
        usage(app);
        return 0;
    }
    if (equalsIgnoreCase(first.token, "ROOTS")) return roots(app);
    if (equalsIgnoreCase(first.token, "QUERY")) return query(app, first.rest);
    if (equalsIgnoreCase(first.token, "ENUM")) return enumKey(app, first.rest);
    if (equalsIgnoreCase(first.token, "SET") or equalsIgnoreCase(first.token, "ADD")) return setValue(app, first.rest);
    if (equalsIgnoreCase(first.token, "DELETE") or equalsIgnoreCase(first.token, "DEL")) return deleteValue(app, first.rest);
    if (equalsIgnoreCase(first.token, "EXPORT")) return exportHive(app, first.rest);
    if (equalsIgnoreCase(first.token, "IMPORT")) return importHive(app, first.rest);
    if (equalsIgnoreCase(first.token, "MIGRATE")) return migrateCommand(app, first.rest);
    if (equalsIgnoreCase(first.token, "MIGRATESELFTEST")) return migrateSelfTest(app);
    if (equalsIgnoreCase(first.token, "SELFTEST")) return selfTest(app);
    if (equalsIgnoreCase(first.token, "APITEST")) return apiSelfTest(app);
    if (equalsIgnoreCase(first.token, "WRITESELFTEST")) return writeSelfTest(app);

    usage(app);
    return 1;
}

fn usage(app: *App) void {
    app.line("REG.R4X - R4OS Registry Tool");
    app.line("Usage:");
    app.line("  REG ROOTS");
    app.line("  REG QUERY root\\key [value]");
    app.line("  REG ENUM root\\key");
    app.line("  REG SET root\\key value type data");
    app.line("  REG DELETE root\\key value");
    app.line("  REG EXPORT root [path]");
    app.line("  REG IMPORT path");
    app.line("  REG MIGRATE ASSOC|TIME|DESKTOP|ALL");
    app.line("  REG SELFTEST");
    app.line("  REG APITEST");
    app.line("  REG WRITESELFTEST");
    app.line("  REG MIGRATESELFTEST");
    app.line("");
    app.line("Roots: SYSTEM");
    app.line("Types: string, u32, u64, bool, binary, multi_string");
}

fn roots(app: *App) i32 {
    app.line("R4OS Registry Roots");
    printRoot(app, "SYSTEM", "SYSTEM.R4R", .system);
    return 0;
}

fn printRoot(app: *App, short: []const u8, long: []const u8, kind: registry.HiveKind) void {
    const path = hivePathZ(kind, pathScratch(0)) orelse return;
    app.write("  ");
    app.write(short);
    app.write(" / ");
    app.write(long);
    app.write(" -> ");
    app.write(spanZPtr(path));
    app.write(" [");
    app.write(if (app.sys.exists(path)) "present" else "missing");
    app.line("]");
}

fn query(app: *App, rest_raw: []const u8) i32 {
    const path_part = takeToken(rest_raw) orelse {
        usage(app);
        return 1;
    };
    const parsed = registry.parseRoot(path_part.token) orelse return fail(app, "bad-root");
    if (!activeHiveKind(parsed.kind)) return fail(app, "inactive-root");
    const hive = loadHive(app, parsed.kind) orelse return 1;

    if (takeToken(path_part.rest)) |value_part| {
        const key_index = hive.findKey(path_part.token) orelse return fail(app, "key-not-found");
        const value_index = hive.findValue(key_index, value_part.token) orelse return fail(app, "value-not-found");
        printValue(app, hive, hive.valueAt(value_index));
        return 0;
    }

    if (hive.findKey(path_part.token)) |key_index| {
        printKey(app, hive, key_index);
        return 0;
    }

    if (splitValuePath(path_part.token, pathScratch(0)[0..path_max])) |split| {
        const key_index = hive.findKey(split.parent) orelse return fail(app, "key-not-found");
        const value_index = hive.findValue(key_index, split.value) orelse return fail(app, "value-not-found");
        printValue(app, hive, hive.valueAt(value_index));
        return 0;
    }

    return fail(app, "key-not-found");
}

fn enumKey(app: *App, rest_raw: []const u8) i32 {
    const path_part = takeToken(rest_raw) orelse {
        usage(app);
        return 1;
    };
    const parsed = registry.parseRoot(path_part.token) orelse return fail(app, "bad-root");
    if (!activeHiveKind(parsed.kind)) return fail(app, "inactive-root");
    const hive = loadHive(app, parsed.kind) orelse return 1;
    const key_index = hive.findKey(path_part.token) orelse return fail(app, "key-not-found");
    const key = hive.keyAt(key_index);

    app.write("Key: ");
    app.line(path_part.token);

    app.line("Subkeys:");
    if (key.child_count == 0) {
        app.line("  <none>");
    } else {
        var offset: u32 = 0;
        while (offset < key.child_count) : (offset += 1) {
            const child = hive.keyAt(key.first_child_index + offset);
            app.write("  [");
            app.write(hive.keyName(child));
            app.line("]");
        }
    }

    app.line("Values:");
    if (key.value_count == 0) {
        app.line("  <none>");
    } else {
        var offset: u32 = 0;
        while (offset < key.value_count) : (offset += 1) {
            app.write("  ");
            printValue(app, hive, hive.valueAt(key.first_value_index + offset));
        }
    }
    return 0;
}

fn setValue(app: *App, rest_raw: []const u8) i32 {
    const key_part = takeToken(rest_raw) orelse {
        usage(app);
        return 1;
    };
    const value_part = takeToken(key_part.rest) orelse {
        usage(app);
        return 1;
    };
    const type_part = takeToken(value_part.rest) orelse {
        usage(app);
        return 1;
    };
    const data_text = trim(type_part.rest);
    if (data_text.len == 0) return fail(app, "missing-data");

    const parsed = registry.parseRoot(key_part.token) orelse return fail(app, "bad-root");
    if (!activeHiveKind(parsed.kind)) return fail(app, "inactive-root");
    const value_type = parseValueType(type_part.token) orelse return fail(app, "bad-type");
    const data = parseSetData(value_type, data_text, set_data_buffer[0..]) orelse return fail(app, "bad-data");

    const existing = loadHiveSilent(app, parsed.kind);
    if (existing.present and !existing.valid) return 1;

    var list = ValueList.init();
    var target_key_index: ?u32 = null;
    if (existing.view) |hive| {
        target_key_index = hive.findKey(key_part.token);
        if (!collectExistingValues(app, hive, &list, target_key_index, value_part.token, false)) return 1;
    }
    if (!list.append(key_part.token, value_part.token, value_type, data)) return fail(app, "too-many-values");

    const generation = if (existing.view) |hive| hive.header.generation + 1 else 1;
    return buildAndCommit(app, parsed.kind, generation, list.items());
}

fn deleteValue(app: *App, rest_raw: []const u8) i32 {
    const key_part = takeToken(rest_raw) orelse {
        usage(app);
        return 1;
    };
    const value_part = takeToken(key_part.rest) orelse {
        usage(app);
        return 1;
    };

    const parsed = registry.parseRoot(key_part.token) orelse return fail(app, "bad-root");
    if (!activeHiveKind(parsed.kind)) return fail(app, "inactive-root");
    const hive = loadHive(app, parsed.kind) orelse return 1;
    const key_index = hive.findKey(key_part.token) orelse return fail(app, "key-not-found");
    _ = hive.findValue(key_index, value_part.token) orelse return fail(app, "value-not-found");

    var list = ValueList.init();
    if (!collectExistingValues(app, hive, &list, key_index, value_part.token, false)) return 1;
    return buildAndCommit(app, parsed.kind, hive.header.generation + 1, list.items());
}

fn importHive(app: *App, rest_raw: []const u8) i32 {
    const path_part = takeToken(rest_raw) orelse {
        usage(app);
        return 1;
    };
    const path = makeZ(path_part.token, pathScratch(0)) orelse return fail(app, "path-too-long");
    const read = app.sys.fileRead(path, import_buffer[0..]);
    if (read <= 0) return fail(app, "import-read-failed");
    if (read >= import_buffer.len) return fail(app, "import-too-large");

    const imported = importTextHiveFixed(app, import_buffer[0..@intCast(read)], 1) orelse return 1;
    return commitHiveBytes(app, imported.kind, imported.bytes);
}

fn importTextHiveFixed(app: *App, text_raw: []const u8, generation: u64) ?ImportedHive {
    var list = ValueList.init();
    var text = stripUtf8Bom(text_raw);
    var seen_header = false;
    var hive_kind: ?registry.HiveKind = null;
    var current_key: []const u8 = "";

    while (text.len > 0) {
        const line_end = findByte(text, '\n') orelse text.len;
        const raw_line = stripLineEnding(text[0..line_end]);
        text = if (line_end < text.len) text[line_end + 1 ..] else text[line_end..];

        const line = trim(raw_line);
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;

        if (!seen_header) {
            if (!equalsIgnoreCase(line, "R4REG_FORMAT=1")) return importFail(app, "import-invalid-header");
            seen_header = true;
            continue;
        }

        if (line[0] == '[') {
            if (line.len < 3 or line[line.len - 1] != ']') return importFail(app, "import-invalid-section");
            const section = trim(line[1 .. line.len - 1]);
            const parsed = registry.parseRoot(section) orelse return importFail(app, "bad-root");
            if (!activeHiveKind(parsed.kind)) return importFail(app, "inactive-root");
            if (hive_kind) |kind| {
                if (kind != parsed.kind) return importFail(app, "root-mismatch");
            } else {
                hive_kind = parsed.kind;
            }
            current_key = list.appendPath(section) orelse return importFail(app, "path-pool-full");
            continue;
        }

        if (current_key.len == 0) return importFail(app, "import-value-without-section");
        const equals = findByte(line, '=') orelse return importFail(app, "import-invalid-value");
        const left = trim(line[0..equals]);
        const right = trim(line[equals + 1 ..]);
        const colon = findByte(left, ':');
        const value_name_raw = if (colon) |pos| trim(left[0..pos]) else left;
        const value_type = if (colon) |pos| parseValueType(trim(left[pos + 1 ..])) orelse return importFail(app, "bad-type") else registry.ValueType.string;
        if (!validName(value_name_raw, true)) return importFail(app, "BadName");

        const parsed_data = parseSetData(value_type, right, set_data_buffer[0..]) orelse return importFail(app, "bad-data");
        const value_name = list.appendPath(value_name_raw) orelse return importFail(app, "path-pool-full");
        const data = list.appendBytes(parsed_data) orelse return importFail(app, "path-pool-full");
        if (!list.append(current_key, value_name, value_type, data)) return importFail(app, "too-many-values");
    }

    if (!seen_header) return importFail(app, "import-invalid-header");
    const kind = hive_kind orelse return importFail(app, "bad-root");
    const bytes = buildHiveFixed(app, kind, generation, list.items()) orelse return null;
    return .{ .kind = kind, .bytes = bytes };
}

fn exportHive(app: *App, rest_raw: []const u8) i32 {
    const root_part = takeToken(rest_raw) orelse {
        usage(app);
        return 1;
    };
    const parsed = registry.parseRoot(root_part.token) orelse return fail(app, "bad-root");
    if (!activeHiveKind(parsed.kind)) return fail(app, "inactive-root");
    const hive = loadHive(app, parsed.kind) orelse return 1;
    const out_path = takeToken(root_part.rest);

    var out = ExportOut{
        .app = app,
        .echo = out_path == null,
    };
    writeExport(&out, hive);
    if (out.overflow) return fail(app, "export-too-large");

    if (out_path) |path_part| {
        const path = makeZ(path_part.token, pathScratch(0)) orelse return fail(app, "path-too-long");
        const written = app.sys.fileWrite(path, export_buffer[0..out.len]);
        if (written < 0 or @as(usize, @intCast(written)) != out.len) return fail(app, "write-failed");
        app.write("REG export saved: ");
        app.write(path_part.token);
        app.line("");
    }
    return 0;
}

fn loadHive(app: *App, kind: registry.HiveKind) ?registry.HiveView {
    const path = hivePathZ(kind, pathScratch(0)) orelse return null;
    const read = app.sys.fileRead(path, hive_buffer[0..]);
    if (read <= 0) {
        app.write("REG: hive missing or unreadable: ");
        app.write(spanZPtr(path));
        app.line("");
        return null;
    }
    if (read >= hive_buffer.len) {
        app.line("REG: hive too large for REG.R4X buffer");
        return null;
    }
    return registry.HiveView.parse(hive_buffer[0..@intCast(read)]) catch |err| {
        app.write("REG: hive parse failed: ");
        app.write(@errorName(err));
        app.line("");
        return null;
    };
}

fn loadHiveSilent(app: *App, kind: registry.HiveKind) LoadedHive {
    const path = hivePathZ(kind, pathScratch(0)) orelse return .{ .present = true };
    const read = app.sys.fileRead(path, hive_buffer[0..]);
    if (read <= 0) return .{};
    if (read >= hive_buffer.len) {
        app.line("REG: hive too large for REG.R4X buffer");
        return .{ .present = true };
    }
    const hive = registry.HiveView.parse(hive_buffer[0..@intCast(read)]) catch |err| {
        app.write("REG: hive parse failed: ");
        app.write(@errorName(err));
        app.line("");
        return .{ .present = true };
    };
    return .{ .present = true, .valid = true, .view = hive };
}

fn collectExistingValues(app: *App, hive: registry.HiveView, list: *ValueList, skip_key_index: ?u32, skip_value_name: []const u8, require_skip: bool) bool {
    var skipped = false;
    var key_index: u32 = 0;
    while (key_index < hive.header.key_count) : (key_index += 1) {
        const key = hive.keyAt(key_index);
        if (key.value_count == 0) continue;

        const key_path = keyPathForBuild(hive, key_index, list) orelse {
            _ = fail(app, "path-pool-full");
            return false;
        };
        var value_offset: u32 = 0;
        while (value_offset < key.value_count) : (value_offset += 1) {
            const value = hive.valueAt(key.first_value_index + value_offset);
            if (skip_key_index != null and key_index == skip_key_index.? and equalsIgnoreCase(hive.valueName(value), skip_value_name)) {
                skipped = true;
                continue;
            }
            if (!list.append(key_path, hive.valueName(value), value.value_type, hive.valueData(value))) {
                _ = fail(app, "too-many-values");
                return false;
            }
        }
    }
    if (require_skip and !skipped) {
        _ = fail(app, "value-not-found");
        return false;
    }
    return true;
}

fn keyPathForBuild(hive: registry.HiveView, key_index: u32, list: *ValueList) ?[]const u8 {
    const start = list.path_len;
    const root = hive.header.hive_kind.shortRoot();
    _ = list.appendPath(root) orelse return null;

    var parts: [key_depth_max]u32 = undefined;
    var count: usize = 0;
    var current = key_index;
    while (current != 0 and count < parts.len) {
        parts[count] = current;
        count += 1;
        current = hive.keyAt(current).parent_index;
        if (current >= hive.header.key_count) return null;
    }
    if (current != 0) return null;

    while (count > 0) {
        count -= 1;
        if (!list.appendByte('\\')) return null;
        _ = list.appendPath(hive.keyName(hive.keyAt(parts[count]))) orelse return null;
    }
    return path_pool_buffer[start..list.path_len];
}

fn buildAndCommit(app: *App, kind: registry.HiveKind, generation: u64, values: []const registry.BuildValue) i32 {
    const bytes = buildHiveFixed(app, kind, generation, values) orelse return 1;
    return commitHiveBytes(app, kind, bytes);
}

fn buildHiveFixed(app: *App, kind: registry.HiveKind, generation: u64, values: []const registry.BuildValue) ?[]const u8 {
    if (values.len > value_collect_buffer.len) return buildFail(app, "too-many-values");
    resetWriteAllocator();

    var key_count: u32 = 1;
    key_build_buffer[0] = .{ .parent = registry.invalid_index, .name = "" };

    var value_index: usize = 0;
    while (value_index < values.len) : (value_index += 1) {
        if (!validValuePayload(values[value_index].value_type, values[value_index].data)) return buildFail(app, "bad-data");
        if (!validName(values[value_index].name, true)) return buildFail(app, "BadName");
        const key_index = ensureBuildKey(kind, values[value_index].key_path, &key_count) orelse return buildFail(app, "InvalidPath");
        var prior: usize = 0;
        while (prior < value_index) : (prior += 1) {
            if (value_key_index_buffer[prior] == key_index and equalsIgnoreCase(values[prior].name, values[value_index].name)) {
                return buildFail(app, "DuplicateValue");
            }
        }
        value_key_index_buffer[value_index] = key_index;
    }

    var flat_count: u32 = 0;
    flat_key_order_buffer[flat_count] = 0;
    key_build_buffer[0].flat_index = 0;
    flat_count += 1;
    var cursor: u32 = 0;
    while (cursor < flat_count) : (cursor += 1) {
        const parent = flat_key_order_buffer[cursor];
        var child: u32 = 1;
        while (child < key_count) : (child += 1) {
            if (key_build_buffer[child].parent == parent) {
                key_build_buffer[child].flat_index = flat_count;
                flat_key_order_buffer[flat_count] = child;
                flat_count += 1;
            }
        }
    }

    var string_heap_size: usize = 0;
    var data_heap_size: usize = 0;
    var flat_i: u32 = 0;
    while (flat_i < flat_count) : (flat_i += 1) {
        const build_i = flat_key_order_buffer[flat_i];
        string_heap_size += key_build_buffer[build_i].name.len;
        value_index = 0;
        while (value_index < values.len) : (value_index += 1) {
            if (value_key_index_buffer[value_index] == build_i) {
                string_heap_size += values[value_index].name.len;
                data_heap_size += values[value_index].data.len;
            }
        }
    }

    const key_table_offset = registry.header_size;
    const key_table_size = @as(usize, key_count) * registry.key_record_size;
    const value_table_offset = key_table_offset + key_table_size;
    const value_table_size = values.len * registry.value_record_size;
    const string_heap_offset = value_table_offset + value_table_size;
    const data_heap_offset = string_heap_offset + string_heap_size;
    const file_size = data_heap_offset + data_heap_size;
    if (file_size > write_alloc_buffer.len or file_size > import_buffer.len) return buildFail(app, "hive-too-large");

    var zero_index: usize = 0;
    while (zero_index < file_size) : (zero_index += 1) write_alloc_buffer[zero_index] = 0;

    var string_cursor: usize = 0;
    var data_cursor: usize = 0;
    var flat_value_index: u32 = 0;
    flat_i = 0;
    while (flat_i < flat_count) : (flat_i += 1) {
        const build_i = flat_key_order_buffer[flat_i];
        const key = key_build_buffer[build_i];
        const name_offset = appendBuildString(key.name, string_heap_offset, &string_cursor) orelse return buildFail(app, "hive-too-large");
        const child_info = childRangeForFlat(build_i, key_count);
        const value_info = valueRangeForBuild(values, build_i);
        const first_value = if (value_info.count == 0) registry.invalid_index else flat_value_index;
        writeKeyRecord(
            write_alloc_buffer[0..],
            key_table_offset + @as(usize, flat_i) * registry.key_record_size,
            if (key.parent == registry.invalid_index) registry.invalid_index else key_build_buffer[key.parent].flat_index,
            name_offset,
            @intCast(key.name.len),
            first_value,
            value_info.count,
            child_info.first,
            child_info.count,
        );

        value_index = 0;
        while (value_index < values.len) : (value_index += 1) {
            if (value_key_index_buffer[value_index] != build_i) continue;
            const value = values[value_index];
            const value_name_offset = appendBuildString(value.name, string_heap_offset, &string_cursor) orelse return buildFail(app, "hive-too-large");
            const data_offset = appendBuildData(value.data, data_heap_offset, &data_cursor) orelse return buildFail(app, "hive-too-large");
            writeValueRecord(
                write_alloc_buffer[0..],
                value_table_offset + @as(usize, flat_value_index) * registry.value_record_size,
                flat_i,
                value_name_offset,
                @intCast(value.name.len),
                value.value_type,
                data_offset,
                @intCast(value.data.len),
            );
            flat_value_index += 1;
        }
    }

    @memcpy(write_alloc_buffer[0..4], registry.magic);
    writeU16(write_alloc_buffer[0..], 4, 1);
    writeU16(write_alloc_buffer[0..], 6, @intCast(registry.header_size));
    writeU16(write_alloc_buffer[0..], 8, 1);
    writeU16(write_alloc_buffer[0..], 10, @intFromEnum(kind));
    writeU64(write_alloc_buffer[0..], 16, @intCast(file_size));
    writeU64(write_alloc_buffer[0..], 24, generation);
    writeU32(write_alloc_buffer[0..], 32, @intCast(key_table_offset));
    writeU32(write_alloc_buffer[0..], 36, key_count);
    writeU32(write_alloc_buffer[0..], 40, @intCast(value_table_offset));
    writeU32(write_alloc_buffer[0..], 44, @intCast(values.len));
    writeU32(write_alloc_buffer[0..], 48, @intCast(string_heap_offset));
    writeU32(write_alloc_buffer[0..], 52, @intCast(string_heap_size));
    writeU32(write_alloc_buffer[0..], 56, @intCast(data_heap_offset));
    writeU32(write_alloc_buffer[0..], 60, @intCast(data_heap_size));

    const bytes = write_alloc_buffer[0..file_size];
    _ = registry.HiveView.parse(bytes) catch |err| {
        app.write("REG: generated hive invalid: ");
        app.write(@errorName(err));
        app.line("");
        return null;
    };
    return bytes;
}

const RangeInfo = struct {
    first: u32,
    count: u32,
};

fn childRangeForFlat(build_index: u32, key_count: u32) RangeInfo {
    var first: u32 = registry.invalid_index;
    var count: u32 = 0;
    var index: u32 = 1;
    while (index < key_count) : (index += 1) {
        if (key_build_buffer[index].parent == build_index) {
            if (first == registry.invalid_index) first = key_build_buffer[index].flat_index;
            count += 1;
        }
    }
    return .{ .first = first, .count = count };
}

fn valueRangeForBuild(values: []const registry.BuildValue, build_index: u32) RangeInfo {
    var count: u32 = 0;
    var index: usize = 0;
    while (index < values.len) : (index += 1) {
        if (value_key_index_buffer[index] == build_index) count += 1;
    }
    return .{ .first = registry.invalid_index, .count = count };
}

fn ensureBuildKey(kind: registry.HiveKind, path: []const u8, key_count: *u32) ?u32 {
    const parsed = registry.parseRoot(path) orelse return null;
    if (parsed.kind != kind) return null;
    var current: u32 = 0;
    var rest = parsed.rest;
    while (nextPathComponent(&rest)) |component| {
        if (!validName(component, false)) return null;
        if (findBuildChild(current, component, key_count.*)) |child| {
            current = child;
            continue;
        }
        if (key_count.* >= key_build_buffer.len) return null;
        const next_index = key_count.*;
        key_build_buffer[next_index] = .{ .parent = current, .name = component };
        key_count.* += 1;
        current = next_index;
    }
    return current;
}

fn findBuildChild(parent: u32, name: []const u8, key_count: u32) ?u32 {
    var index: u32 = 1;
    while (index < key_count) : (index += 1) {
        if (key_build_buffer[index].parent == parent and equalsIgnoreCase(key_build_buffer[index].name, name)) return index;
    }
    return null;
}

fn nextPathComponent(rest: *[]const u8) ?[]const u8 {
    var text = trimSeparators(rest.*);
    if (text.len == 0) {
        rest.* = "";
        return null;
    }
    var index: usize = 0;
    while (index < text.len and text[index] != '\\' and text[index] != '/') : (index += 1) {}
    const component = text[0..index];
    rest.* = if (index < text.len) text[index + 1 ..] else text[index..];
    return component;
}

fn trimSeparators(text_raw: []const u8) []const u8 {
    var text = trim(text_raw);
    while (text.len > 0 and (text[0] == '\\' or text[0] == '/')) text = text[1..];
    while (text.len > 0 and (text[text.len - 1] == '\\' or text[text.len - 1] == '/')) text = text[0 .. text.len - 1];
    return text;
}

fn appendBuildString(text: []const u8, heap_offset: usize, cursor: *usize) ?u32 {
    if (text.len > 0xffff) return null;
    const start = cursor.*;
    if (heap_offset + start + text.len > write_alloc_buffer.len) return null;
    if (text.len != 0) @memcpy(write_alloc_buffer[heap_offset + start .. heap_offset + start + text.len], text);
    cursor.* += text.len;
    return @intCast(start);
}

fn appendBuildData(data: []const u8, heap_offset: usize, cursor: *usize) ?u32 {
    const start = cursor.*;
    if (heap_offset + start + data.len > write_alloc_buffer.len) return null;
    if (data.len != 0) @memcpy(write_alloc_buffer[heap_offset + start .. heap_offset + start + data.len], data);
    cursor.* += data.len;
    return @intCast(start);
}

fn buildFail(app: *App, text: []const u8) ?[]const u8 {
    _ = fail(app, text);
    return null;
}

fn importFail(app: *App, text: []const u8) ?ImportedHive {
    _ = fail(app, text);
    return null;
}

fn validValuePayload(value_type: registry.ValueType, data: []const u8) bool {
    switch (value_type) {
        .string, .binary => return true,
        .u32 => return data.len == 4,
        .u64 => return data.len == 8,
        .bool => return data.len == 1 and (data[0] == 0 or data[0] == 1),
        .multi_string => return validMultiString(data),
    }
}

fn validMultiString(data: []const u8) bool {
    if (data.len < 4) return false;
    const count = readU32(data, 0);
    var offset: usize = 4;
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        if (offset + 2 > data.len) return false;
        const len = readU16(data, offset);
        offset += 2;
        if (offset + len > data.len) return false;
        offset += len;
    }
    return offset == data.len;
}

fn validName(name: []const u8, allow_empty: bool) bool {
    if (name.len == 0) return allow_empty;
    if (name.len > 63) return false;
    for (name) |ch| {
        if (ch < 0x20 or ch == 0x7f or ch == 0 or ch == '\\' or ch == '/' or ch == '=') return false;
    }
    return true;
}

fn commitHiveBytes(app: *App, kind: registry.HiveKind, bytes: []const u8) i32 {
    _ = registry.HiveView.parse(bytes) catch |err| {
        app.write("REG: generated hive invalid: ");
        app.write(@errorName(err));
        app.line("");
        return 1;
    };

    _ = app.sys.dirCreate(literalZ("C:\\R4OS", pathScratch(0)) orelse return fail(app, "path-too-long"));
    _ = app.sys.dirCreate(literalZ("C:\\R4OS\\REGISTRY", pathScratch(1)) orelse return fail(app, "path-too-long"));

    const tmp_path = hiveTmpPathZ(kind, pathScratch(2)) orelse return fail(app, "path-too-long");
    const hive_path = hivePathZ(kind, pathScratch(3)) orelse return fail(app, "path-too-long");
    const bak_path = hiveBakPathZ(kind, pathScratch(4)) orelse return fail(app, "path-too-long");
    _ = app.sys.fileDelete(tmp_path);
    const written = app.sys.fileWrite(tmp_path, bytes);
    if (written < 0 or @as(usize, @intCast(written)) != bytes.len) return fail(app, "tmp-write-failed");

    const read_back = app.sys.fileRead(tmp_path, import_buffer[0..]);
    if (read_back < 0 or @as(usize, @intCast(read_back)) != bytes.len) return fail(app, "tmp-verify-read-failed");
    _ = registry.HiveView.parse(import_buffer[0..@intCast(read_back)]) catch |err| {
        app.write("REG: tmp verify failed: ");
        app.write(@errorName(err));
        app.line("");
        return 1;
    };

    if (app.sys.exists(hive_path)) {
        _ = app.sys.fileDelete(bak_path);
        if (app.sys.fileCopy(hive_path, bak_path) <= 0) return fail(app, "backup-failed");
        _ = app.sys.fileDelete(hive_path);
    }
    if (app.sys.fileRename(tmp_path, hive_path) <= 0) return fail(app, "replace-failed");

    app.write("REG wrote: ");
    app.write(spanZPtr(hive_path));
    app.line("");
    return 0;
}

fn resetWriteAllocator() void {
    for (write_alloc_buffer[0..]) |*byte| byte.* = 0x96;
}

fn printKey(app: *App, hive: registry.HiveView, key_index: u32) void {
    const key = hive.keyAt(key_index);
    app.write("Values: ");
    app.dec(key.value_count);
    app.write(", Subkeys: ");
    app.dec(key.child_count);
    app.line("");

    var offset: u32 = 0;
    while (offset < key.value_count) : (offset += 1) {
        printValue(app, hive, hive.valueAt(key.first_value_index + offset));
    }
}

fn printValue(app: *App, hive: registry.HiveView, value: registry.ValueRecord) void {
    const name = hive.valueName(value);
    if (name.len == 0) {
        app.write("(Default)");
    } else {
        app.write(name);
    }
    app.write(":");
    app.write(valueTypeName(value.value_type));
    app.write("=");
    printValueData(app, value.value_type, hive.valueData(value));
    app.line("");
}

fn printValueData(app: *App, value_type: registry.ValueType, data: []const u8) void {
    switch (value_type) {
        .string => writeEscapedString(app, data),
        .u32 => app.dec(readU32(data, 0)),
        .u64 => app.dec(readU64(data, 0)),
        .bool => app.write(if (data.len == 1 and data[0] != 0) "true" else "false"),
        .binary => writeBinary(app, data),
        .multi_string => writeMultiString(app, data),
    }
}

fn writeExport(out: *ExportOut, hive: registry.HiveView) void {
    out.line("R4REG_FORMAT=1");
    out.line("");

    var wrote_key = false;
    var key_index: u32 = 0;
    while (key_index < hive.header.key_count) : (key_index += 1) {
        const key = hive.keyAt(key_index);
        if (key.value_count == 0) continue;
        wrote_key = true;

        out.write("[");
        writeKeyPathOut(out, hive, key_index);
        out.line("]");

        var value_offset: u32 = 0;
        while (value_offset < key.value_count) : (value_offset += 1) {
            const value = hive.valueAt(key.first_value_index + value_offset);
            out.write(hive.valueName(value));
            out.write(":");
            out.write(valueTypeName(value.value_type));
            out.write("=");
            writeValueDataOut(out, value.value_type, hive.valueData(value));
            out.line("");
        }
        out.line("");
    }

    if (!wrote_key) {
        out.write("[");
        out.write(hive.header.hive_kind.shortRoot());
        out.line("]");
        out.line("");
    }
}

fn writeValueDataOut(out: *ExportOut, value_type: registry.ValueType, data: []const u8) void {
    switch (value_type) {
        .string => writeEscapedStringOut(out, data),
        .u32 => writeDecOut(out, readU32(data, 0)),
        .u64 => writeDecOut(out, readU64(data, 0)),
        .bool => out.write(if (data.len == 1 and data[0] != 0) "true" else "false"),
        .binary => writeBinaryOut(out, data),
        .multi_string => writeMultiStringOut(out, data),
    }
}

fn writeKeyPathOut(out: *ExportOut, hive: registry.HiveView, key_index: u32) void {
    var parts: [key_depth_max]u32 = undefined;
    var count: usize = 0;
    var current = key_index;
    while (current != 0 and count < parts.len) {
        parts[count] = current;
        count += 1;
        current = hive.keyAt(current).parent_index;
        if (current >= hive.header.key_count) break;
    }

    out.write(hive.header.hive_kind.shortRoot());
    while (count > 0) {
        count -= 1;
        out.write("\\");
        out.write(hive.keyName(hive.keyAt(parts[count])));
    }
}

fn selfTest(app: *App) i32 {
    const len = writeSelftestHive(selftest_buffer[0..]);
    const hive = registry.HiveView.parse(selftest_buffer[0..len]) catch |err| {
        app.write("REG selftest parse failed: ");
        app.write(@errorName(err));
        app.line("");
        return 1;
    };
    const value = hive.getValue("SYSTEM\\System", "Enabled") orelse return fail(app, "selftest-query");
    if (value.asBool() != true) return fail(app, "selftest-bool");

    var out = ExportOut{ .app = app, .echo = false };
    writeExport(&out, hive);
    if (out.overflow or out.len == 0) return fail(app, "selftest-export");

    app.line("REG selftest: OK");
    return 0;
}

fn migrateCommand(app: *App, rest_raw: []const u8) i32 {
    const target_part = takeToken(rest_raw) orelse {
        usage(app);
        return 1;
    };

    if (!app.sys.hasFn("registry_set_value")) return fail(app, "migrate-api-missing");

    if (equalsIgnoreCase(target_part.token, "ALL")) {
        if (migrateConfigFile(app, .assoc, migrateSourcePath(.assoc)) != 0) return 1;
        if (migrateConfigFile(app, .time, migrateSourcePath(.time)) != 0) return 1;
        if (migrateConfigFile(app, .desktop, migrateSourcePath(.desktop)) != 0) return 1;
        return 0;
    }

    const target = parseMigrateTarget(target_part.token) orelse {
        usage(app);
        return 1;
    };
    return migrateConfigFile(app, target, migrateSourcePath(target));
}

fn migrateConfigFile(app: *App, target: MigrateTarget, source_path_text: []const u8) i32 {
    const source_path = makeZ(source_path_text, pathScratch(0)) orelse return fail(app, "path-too-long");
    const read = app.sys.fileRead(source_path, migrate_buffer[0..]);
    if (read <= 0) return fail(app, "migrate-read-failed");
    if (read >= migrate_buffer.len) return fail(app, "migrate-too-large");

    const count = migrateConfigBytes(app, target, migrate_buffer[0..@intCast(read)]) orelse return 1;
    app.write("REG migrate ");
    app.write(migrateTargetName(target));
    app.write(": ");
    app.dec(count);
    app.line(" values");
    return 0;
}

fn migrateConfigBytes(app: *App, target: MigrateTarget, bytes_raw: []const u8) ?usize {
    if (!validateSettingsDocument(app, bytes_raw, migrateSchema(target))) return null;

    var count: usize = 0;
    var iter = settings.EntryIterator.init(bytes_raw);
    while (iter.next()) |entry| {
        if (equalsIgnoreCase(entry.key, settings.format_key) or equalsIgnoreCase(entry.key, settings.schema_key)) continue;
        const ok = switch (target) {
            .assoc => migrateAssocEntry(app, entry),
            .time => migrateTimeEntry(app, entry),
            .desktop => migrateDesktopEntry(app, entry),
        };
        if (!ok) return null;
        count += 1;
    }

    if (count == 0) return migrateFailCount(app, "migrate-empty-config");
    return count;
}

fn validateSettingsDocument(app: *App, bytes_raw: []const u8, expected_schema: []const u8) bool {
    var text = stripUtf8Bom(bytes_raw);
    var saw_format = false;
    var saw_schema = false;

    while (text.len > 0) {
        const line_end = findByte(text, '\n') orelse text.len;
        const raw_line = stripLineEnding(text[0..line_end]);
        text = if (line_end < text.len) text[line_end + 1 ..] else text[line_end..];

        const line = trim(raw_line);
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;

        const entry = settings.parseLine(line) orelse return migrateFailBool(app, "migrate-invalid-setting");
        if (equalsIgnoreCase(entry.key, settings.format_key)) {
            const format = settings.parseU32(entry.value) orelse return migrateFailBool(app, "migrate-bad-format");
            if (format != settings.current_format_version) return migrateFailBool(app, "migrate-bad-format");
            saw_format = true;
        } else if (equalsIgnoreCase(entry.key, settings.schema_key)) {
            if (!equalsIgnoreCase(entry.value, expected_schema)) return migrateFailBool(app, "migrate-schema-mismatch");
            saw_schema = true;
        }
    }

    if (!saw_format) return migrateFailBool(app, "migrate-missing-format");
    if (!saw_schema) return migrateFailBool(app, "migrate-missing-schema");
    return true;
}

fn migrateAssocEntry(app: *App, entry: settings.Entry) bool {
    if (startsWithIgnoreCase(entry.key, "APP.")) {
        const setting = splitPrefixedSetting(entry.key, "APP.") orelse return migrateFailBool(app, "migrate-bad-assoc-key");
        if (!validName(setting.id, false) or !validName(setting.field, false)) return migrateFailBool(app, "migrate-bad-assoc-key");
        const key_path = makePrefixedZ("SYSTEM\\Software\\R4OS\\Apps\\", setting.id, pathScratch(0)) orelse return migrateFailBool(app, "path-too-long");
        return migrateSetStringKeyZ(app, key_path, assocAppFieldName(setting.field), entry.value);
    }

    if (startsWithIgnoreCase(entry.key, "EXT.")) {
        const setting = splitPrefixedSetting(entry.key, "EXT.") orelse return migrateFailBool(app, "migrate-bad-assoc-key");
        if (!validName(setting.id, false) or !validName(setting.field, false)) return migrateFailBool(app, "migrate-bad-assoc-key");
        const key_path = makePrefixedZ("SYSTEM\\Software\\Classes\\.", setting.id, pathScratch(0)) orelse return migrateFailBool(app, "path-too-long");
        const field_name = assocExtFieldName(setting.field);
        if (equalsIgnoreCase(setting.field, "RANK")) {
            const rank = settings.parseU32(entry.value) orelse return migrateFailBool(app, "migrate-bad-rank");
            return migrateSetU32KeyZ(app, key_path, field_name, rank);
        }
        return migrateSetStringKeyZ(app, key_path, field_name, entry.value);
    }

    return migrateSetStringPath(app, "SYSTEM\\Software\\R4OS\\Associations\\Raw", entry.key, entry.value);
}

fn migrateTimeEntry(app: *App, entry: settings.Entry) bool {
    return migrateSetStringPath(app, "SYSTEM\\System\\Time", entry.key, entry.value);
}

fn migrateDesktopEntry(app: *App, entry: settings.Entry) bool {
    if (equalsIgnoreCase(entry.key, "TASKBAR_CLOCK")) {
        const value = settings.parseBool(entry.value) orelse return migrateFailBool(app, "migrate-bad-bool");
        return migrateSetBoolPath(app, "SYSTEM\\Shell\\Desktop\\Settings", entry.key, value);
    }
    if (equalsIgnoreCase(entry.key, "UI_FONT_SIZE") or
        equalsIgnoreCase(entry.key, "TERMINAL_FONT_SIZE") or
        equalsIgnoreCase(entry.key, "TERMINAL_CODEPAGE"))
    {
        const value = settings.parseU32(entry.value) orelse return migrateFailBool(app, "migrate-bad-u32");
        return migrateSetU32Path(app, "SYSTEM\\Shell\\Desktop\\Settings", entry.key, value);
    }
    return migrateSetStringPath(app, "SYSTEM\\Shell\\Desktop\\Settings", entry.key, entry.value);
}

fn migrateSetStringPath(app: *App, key_path_text: []const u8, value_name_text: []const u8, value: []const u8) bool {
    const key_path = makeZ(key_path_text, pathScratch(0)) orelse return migrateFailBool(app, "path-too-long");
    return migrateSetStringKeyZ(app, key_path, value_name_text, value);
}

fn migrateSetU32Path(app: *App, key_path_text: []const u8, value_name_text: []const u8, value: u32) bool {
    const key_path = makeZ(key_path_text, pathScratch(0)) orelse return migrateFailBool(app, "path-too-long");
    return migrateSetU32KeyZ(app, key_path, value_name_text, value);
}

fn migrateSetBoolPath(app: *App, key_path_text: []const u8, value_name_text: []const u8, value: bool) bool {
    const key_path = makeZ(key_path_text, pathScratch(0)) orelse return migrateFailBool(app, "path-too-long");
    return migrateSetBoolKeyZ(app, key_path, value_name_text, value);
}

fn migrateSetStringKeyZ(app: *App, key_path: [*:0]const u8, value_name_text: []const u8, value: []const u8) bool {
    const value_name = makeZ(value_name_text, pathScratch(1)) orelse return migrateFailBool(app, "path-too-long");
    return migrateApiOk(app, app.sys.registrySetString(key_path, value_name, value), "migrate-set-string");
}

fn migrateSetU32KeyZ(app: *App, key_path: [*:0]const u8, value_name_text: []const u8, value: u32) bool {
    const value_name = makeZ(value_name_text, pathScratch(1)) orelse return migrateFailBool(app, "path-too-long");
    return migrateApiOk(app, app.sys.registrySetU32(key_path, value_name, value), "migrate-set-u32");
}

fn migrateSetBoolKeyZ(app: *App, key_path: [*:0]const u8, value_name_text: []const u8, value: bool) bool {
    const value_name = makeZ(value_name_text, pathScratch(1)) orelse return migrateFailBool(app, "path-too-long");
    return migrateApiOk(app, app.sys.registrySetBool(key_path, value_name, value), "migrate-set-bool");
}

fn migrateApiOk(app: *App, result: i32, text: []const u8) bool {
    if (result == r4os.abi.registry_api_result_ok) return true;
    return migrateFailBool(app, text);
}

fn migrateSelfTest(app: *App) i32 {
    deleteMigrateSelfTestTemps(app);

    const had_system = backupMigrateHive(app, .system) orelse return fail(app, "migrate-selftest-backup-system");
    cleanupHiveFiles(app, .system);

    _ = migrateConfigBytes(app, .assoc, migrate_assoc_selftest) orelse return migrateSelfTestFail(app, had_system, "migrate-selftest-assoc");
    _ = migrateConfigBytes(app, .time, migrate_time_selftest) orelse return migrateSelfTestFail(app, had_system, "migrate-selftest-time");
    _ = migrateConfigBytes(app, .desktop, migrate_desktop_selftest) orelse return migrateSelfTestFail(app, had_system, "migrate-selftest-desktop");

    if (!expectStringValue(app, "SYSTEM\\Software\\R4OS\\Apps\\NOTEPAD", "Path", "C:\\R4OS\\SOFTWARE\\DESKTOP\\NOTEPAD.R4X")) return migrateSelfTestFail(app, had_system, "migrate-selftest-app-path");
    if (!expectStringValue(app, "SYSTEM\\Software\\Classes\\.TXT", "DefaultApp", "NOTEPAD")) return migrateSelfTestFail(app, had_system, "migrate-selftest-ext-app");
    if (!expectU32Value(app, "SYSTEM\\Software\\Classes\\.TXT", "Rank", 3)) return migrateSelfTestFail(app, had_system, "migrate-selftest-ext-rank");
    if (!expectStringValue(app, "SYSTEM\\System\\Time", "TIMEZONE", "Europe/Berlin")) return migrateSelfTestFail(app, had_system, "migrate-selftest-timezone");
    if (!expectStringValue(app, "SYSTEM\\Shell\\Desktop\\Settings", "DESKTOP_BG", "008080")) return migrateSelfTestFail(app, had_system, "migrate-selftest-bg");
    if (!expectBoolValue(app, "SYSTEM\\Shell\\Desktop\\Settings", "TASKBAR_CLOCK", true)) return migrateSelfTestFail(app, had_system, "migrate-selftest-clock");
    if (!expectU32Value(app, "SYSTEM\\Shell\\Desktop\\Settings", "TERMINAL_CODEPAGE", 437)) return migrateSelfTestFail(app, had_system, "migrate-selftest-codepage");

    restoreMigrateSelfTest(app, had_system);
    app.line("REG migrate selftest: OK");
    return 0;
}

fn migrateSelfTestFail(app: *App, had_system: bool, text: []const u8) i32 {
    restoreMigrateSelfTest(app, had_system);
    return fail(app, text);
}

fn backupMigrateHive(app: *App, kind: registry.HiveKind) ?bool {
    return backupHiveFile(app, kind);
}

fn restoreMigrateSelfTest(app: *App, had_system: bool) void {
    restoreMigrateHive(app, .system, had_system);
    deleteMigrateSelfTestTemps(app);
}

fn restoreMigrateHive(app: *App, kind: registry.HiveKind, restore_original: bool) void {
    restoreHiveFile(app, kind, restore_original);
}

fn deleteMigrateSelfTestTemps(app: *App) void {
    deleteMigrateBackup(app, .system);
}

fn deleteMigrateBackup(app: *App, kind: registry.HiveKind) void {
    deleteHiveBackup(app, kind);
}

fn parseMigrateTarget(text: []const u8) ?MigrateTarget {
    if (equalsIgnoreCase(text, "ASSOC")) return .assoc;
    if (equalsIgnoreCase(text, "TIME")) return .time;
    if (equalsIgnoreCase(text, "DESKTOP")) return .desktop;
    return null;
}

fn migrateTargetName(target: MigrateTarget) []const u8 {
    return switch (target) {
        .assoc => "ASSOC",
        .time => "TIME",
        .desktop => "DESKTOP",
    };
}

fn migrateSourcePath(target: MigrateTarget) []const u8 {
    return switch (target) {
        .assoc => settings.paths.assoc,
        .time => settings.paths.time,
        .desktop => settings.paths.desktop,
    };
}

fn migrateSchema(target: MigrateTarget) []const u8 {
    return switch (target) {
        .assoc => "APPASSOC",
        .time => "TIME",
        .desktop => "DESKTOP",
    };
}

fn assocAppFieldName(field: []const u8) []const u8 {
    if (equalsIgnoreCase(field, "TITLE")) return "Title";
    if (equalsIgnoreCase(field, "PATH")) return "Path";
    if (equalsIgnoreCase(field, "POLICY")) return "Policy";
    if (equalsIgnoreCase(field, "ARGS")) return "Args";
    return field;
}

fn assocExtFieldName(field: []const u8) []const u8 {
    if (equalsIgnoreCase(field, "APP")) return "DefaultApp";
    if (equalsIgnoreCase(field, "TYPE")) return "Type";
    if (equalsIgnoreCase(field, "SHORT")) return "Short";
    if (equalsIgnoreCase(field, "PREFIX")) return "Prefix";
    if (equalsIgnoreCase(field, "RANK")) return "Rank";
    return field;
}

fn splitPrefixedSetting(key: []const u8, prefix: []const u8) ?CompositeSetting {
    if (!startsWithIgnoreCase(key, prefix)) return null;
    const rest = key[prefix.len..];
    const dot = findByte(rest, '.') orelse return null;
    if (dot == 0 or dot + 1 >= rest.len) return null;
    return .{ .id = rest[0..dot], .field = rest[dot + 1 ..] };
}

fn makePrefixedZ(comptime prefix: []const u8, value: []const u8, out: []u8) ?[*:0]const u8 {
    const len = prefix.len + value.len;
    if (len + 1 > out.len) return null;
    inline for (prefix, 0..) |ch, index| {
        out[index] = ch;
    }
    if (value.len != 0) @memcpy(out[prefix.len..len], value);
    out[len] = 0;
    return @ptrCast(out.ptr);
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (text.len < prefix.len) return false;
    return equalsIgnoreCase(text[0..prefix.len], prefix);
}

fn migrateFailBool(app: *App, text: []const u8) bool {
    _ = fail(app, text);
    return false;
}

fn migrateFailCount(app: *App, text: []const u8) ?usize {
    _ = fail(app, text);
    return null;
}

fn writeSelfTest(app: *App) i32 {
    _ = app.sys.dirCreate(literalZ("C:\\TEMP", pathScratch(0)) orelse return fail(app, "path-too-long"));
    deleteLiteralPath(app, "C:\\TEMP\\RGWST.R4T");

    const had_system_hive = backupHiveFile(app, .system) orelse return fail(app, "write-selftest-backup");
    if (!had_system_hive) cleanupSystemHiveFiles(app);

    if (setValue(app, "SYSTEM\\RegSelftest Name string \"OK\"") != 0) return writeSelfTestFail(app, had_system_hive, "write-selftest-set-string");
    if (!expectStringValue(app, "SYSTEM\\RegSelftest", "Name", "OK")) return writeSelfTestFail(app, had_system_hive, "write-selftest-read-string");

    if (setValue(app, "SYSTEM\\RegSelftest Count u32 46") != 0) return writeSelfTestFail(app, had_system_hive, "write-selftest-set-u32");
    if (!expectU32Value(app, "SYSTEM\\RegSelftest", "Count", 46)) return writeSelfTestFail(app, had_system_hive, "write-selftest-read-u32");

    if (exportHive(app, "SYSTEM C:\\TEMP\\RGWST.R4T") != 0) return writeSelfTestFail(app, had_system_hive, "write-selftest-export");
    if (deleteValue(app, "SYSTEM\\RegSelftest Name") != 0) return writeSelfTestFail(app, had_system_hive, "write-selftest-delete");
    if (!expectMissingValue(app, "SYSTEM\\RegSelftest", "Name")) return writeSelfTestFail(app, had_system_hive, "write-selftest-delete-verify");

    if (importHive(app, "C:\\TEMP\\RGWST.R4T") != 0) return writeSelfTestFail(app, had_system_hive, "write-selftest-import");
    if (!expectStringValue(app, "SYSTEM\\RegSelftest", "Name", "OK")) return writeSelfTestFail(app, had_system_hive, "write-selftest-import-string");
    if (!expectU32Value(app, "SYSTEM\\RegSelftest", "Count", 46)) return writeSelfTestFail(app, had_system_hive, "write-selftest-import-u32");

    if (deleteValue(app, "SYSTEM\\RegSelftest Name") != 0) return writeSelfTestFail(app, had_system_hive, "write-selftest-clean-name");
    if (deleteValue(app, "SYSTEM\\RegSelftest Count") != 0) return writeSelfTestFail(app, had_system_hive, "write-selftest-clean-count");
    restoreWriteSelfTest(app, had_system_hive);

    app.line("REG write selftest: OK");
    return 0;
}

fn apiSelfTest(app: *App) i32 {
    const had_system_hive = backupHiveFile(app, .system) orelse return fail(app, "api-selftest-backup");
    if (!had_system_hive) cleanupSystemHiveFiles(app);

    if (!app.sys.hasFn("registry_get_value")) return apiSelfTestFail(app, had_system_hive, "api-selftest-read-api-missing");
    if (!app.sys.hasFn("registry_set_value")) return apiSelfTestFail(app, had_system_hive, "api-selftest-write-api-missing");
    if (!expectApiInactiveRoot(app)) return apiSelfTestFail(app, had_system_hive, "api-selftest-inactive-root");
    if (!expectApiMissingSystemHive(app)) return apiSelfTestFail(app, had_system_hive, "api-selftest-missing-system-hive");
    if (!expectApiCorruptSystemHive(app)) return apiSelfTestFail(app, had_system_hive, "api-selftest-corrupt-system-hive");
    cleanupSystemHiveFiles(app);

    var facade_key = r4os.RegistryPath.parse("SYSTEM\\RegApiSelftest") catch return apiSelfTestFail(app, had_system_hive, "path-too-long");

    if (app.registry_api.setString(&facade_key, "Name", "OK") != .ok) return apiSelfTestFail(app, had_system_hive, "api-selftest-set-string");
    if (!expectApiString(app, "SYSTEM\\RegApiSelftest", "Name", "OK")) return apiSelfTestFail(app, had_system_hive, "api-selftest-read-string");
    if (!expectApiEnumValue(app, "SYSTEM\\RegApiSelftest", 0, "Name", r4os.abi.registry_value_type_string)) return apiSelfTestFail(app, had_system_hive, "api-selftest-enum-string");

    if (app.registry_api.setU32(&facade_key, "Count", 46) != .ok) return apiSelfTestFail(app, had_system_hive, "api-selftest-set-u32");
    if (!expectApiU32(app, "SYSTEM\\RegApiSelftest", "Count", 46)) return apiSelfTestFail(app, had_system_hive, "api-selftest-read-u32");

    if (app.registry_api.delete(&facade_key, "Name") != .ok) return apiSelfTestFail(app, had_system_hive, "api-selftest-delete-string");
    if (!expectApiMissing(app, "SYSTEM\\RegApiSelftest", "Name")) return apiSelfTestFail(app, had_system_hive, "api-selftest-missing-string");

    if (app.registry_api.delete(&facade_key, "Count") != .ok) return apiSelfTestFail(app, had_system_hive, "api-selftest-delete-u32");
    if (!expectApiMissing(app, "SYSTEM\\RegApiSelftest", "Count")) return apiSelfTestFail(app, had_system_hive, "api-selftest-missing-u32");
    restoreApiSelfTest(app, had_system_hive);

    app.line("REG inactive root selftest: OK");
    app.line("REG missing system hive selftest: OK");
    app.line("REG corrupt system hive selftest: OK");
    app.line("REG api selftest: OK");
    return 0;
}

fn apiSelfTestFail(app: *App, restore_original: bool, text: []const u8) i32 {
    restoreApiSelfTest(app, restore_original);
    return fail(app, text);
}

fn restoreApiSelfTest(app: *App, restore_original: bool) void {
    restoreHiveFile(app, .system, restore_original);
}

fn expectApiEnumValue(app: *App, key_path_text: []const u8, index: u32, value_name_text: []const u8, value_type: u16) bool {
    const key_path = makeZ(key_path_text, pathScratch(0)) orelse return false;
    var key_info: r4os.abi.RegistryKeyInfo = .{};
    if (app.sys.registryKeyInfo(key_path, &key_info) != r4os.abi.registry_api_result_ok) return false;
    if (index >= key_info.value_count) return false;

    var enum_info: r4os.abi.RegistryValueInfo = .{};
    if (app.sys.registryEnumValue(key_path, index, &enum_info) != r4os.abi.registry_api_result_ok) return false;
    if (enum_info.value_type != value_type) return false;
    return fixedZEquals(enum_info.name[0..], value_name_text);
}

fn expectApiString(app: *App, key_path_text: []const u8, value_name_text: []const u8, expected: []const u8) bool {
    const key_path = makeZ(key_path_text, pathScratch(0)) orelse return false;
    const value_name = makeZ(value_name_text, pathScratch(1)) orelse return false;

    var value_info: r4os.abi.RegistryValueInfo = .{};
    var data: [64]u8 = .{0xA5} ** 64;
    const got = app.sys.registryGetValue(key_path, value_name, &value_info, data[0..]);
    if (got != @as(i32, @intCast(expected.len))) return false;
    if (value_info.value_type != r4os.abi.registry_value_type_string) return false;
    if (value_info.data_len != expected.len) return false;
    return bytesEqual(data[0..expected.len], expected);
}

fn expectApiU32(app: *App, key_path_text: []const u8, value_name_text: []const u8, expected: u32) bool {
    const key_path = makeZ(key_path_text, pathScratch(0)) orelse return false;
    const value_name = makeZ(value_name_text, pathScratch(1)) orelse return false;

    var value_info: r4os.abi.RegistryValueInfo = .{};
    var data: [4]u8 = .{0} ** 4;
    const got = app.sys.registryGetValue(key_path, value_name, &value_info, data[0..]);
    if (got != 4) return false;
    if (value_info.value_type != r4os.abi.registry_value_type_u32) return false;
    if (value_info.data_len != 4) return false;
    return readU32(data[0..], 0) == expected;
}

fn expectApiMissing(app: *App, key_path_text: []const u8, value_name_text: []const u8) bool {
    const key_path = makeZ(key_path_text, pathScratch(0)) orelse return false;
    const value_name = makeZ(value_name_text, pathScratch(1)) orelse return false;

    var value_info: r4os.abi.RegistryValueInfo = .{};
    var data: [4]u8 = .{0} ** 4;
    const got = app.sys.registryGetValue(key_path, value_name, &value_info, data[0..]);
    return got == r4os.abi.registry_api_result_key_not_found or got == r4os.abi.registry_api_result_value_not_found;
}

fn expectApiInactiveRoot(app: *App) bool {
    const key_path = makeZ("SOFTWARE\\RegApiSelftest", pathScratch(0)) orelse return false;
    const value_name = makeZ("Name", pathScratch(1)) orelse return false;

    var key_info: r4os.abi.RegistryKeyInfo = .{};
    var enum_key: [32]u8 = .{0} ** 32;
    var value_info: r4os.abi.RegistryValueInfo = .{};
    var data: [8]u8 = .{0} ** 8;

    if (app.sys.registryKeyInfo(key_path, &key_info) != r4os.abi.registry_api_result_unsupported) return false;
    if (app.sys.registryEnumKey(key_path, 0, enum_key[0..]) != r4os.abi.registry_api_result_unsupported) return false;
    if (app.sys.registryEnumValue(key_path, 0, &value_info) != r4os.abi.registry_api_result_unsupported) return false;
    if (app.sys.registryGetValue(key_path, value_name, &value_info, data[0..]) != r4os.abi.registry_api_result_unsupported) return false;
    if (app.sys.registrySetString(key_path, value_name, "NO") != r4os.abi.registry_api_result_unsupported) return false;
    if (app.sys.registryDeleteValue(key_path, value_name) != r4os.abi.registry_api_result_unsupported) return false;
    return true;
}

fn expectApiMissingSystemHive(app: *App) bool {
    cleanupSystemHiveFiles(app);
    const key_path = makeZ("SYSTEM\\RegApiSelftest", pathScratch(0)) orelse return false;
    const value_name = makeZ("Name", pathScratch(1)) orelse return false;

    var key_info: r4os.abi.RegistryKeyInfo = .{};
    var value_info: r4os.abi.RegistryValueInfo = .{};
    var data: [4]u8 = .{0} ** 4;

    if (app.sys.registryKeyInfo(key_path, &key_info) != r4os.abi.registry_api_result_hive_not_found) return false;
    if (app.sys.registryGetValue(key_path, value_name, &value_info, data[0..]) != r4os.abi.registry_api_result_hive_not_found) return false;
    return true;
}

fn expectApiCorruptSystemHive(app: *App) bool {
    cleanupSystemHiveFiles(app);
    const hive_path = hivePathZ(.system, pathScratch(0)) orelse return false;
    if (app.sys.fileWrite(hive_path, "BROKEN") != 6) return false;

    const key_path = makeZ("SYSTEM\\RegApiSelftest", pathScratch(1)) orelse return false;
    const value_name = makeZ("Name", pathScratch(2)) orelse return false;

    var key_info: r4os.abi.RegistryKeyInfo = .{};
    var value_info: r4os.abi.RegistryValueInfo = .{};
    var data: [4]u8 = .{0} ** 4;

    if (app.sys.registryKeyInfo(key_path, &key_info) != r4os.abi.registry_api_result_hive_corrupt) return false;
    if (app.sys.registryGetValue(key_path, value_name, &value_info, data[0..]) != r4os.abi.registry_api_result_hive_corrupt) return false;
    return true;
}

fn writeSelfTestFail(app: *App, restore_original: bool, text: []const u8) i32 {
    restoreWriteSelfTest(app, restore_original);
    return fail(app, text);
}

fn restoreWriteSelfTest(app: *App, restore_original: bool) void {
    restoreHiveFile(app, .system, restore_original);
    deleteLiteralPath(app, "C:\\TEMP\\RGWST.R4T");
}

fn cleanupSystemHiveFiles(app: *App) void {
    cleanupHiveFiles(app, .system);
}

fn cleanupHiveFiles(app: *App, kind: registry.HiveKind) void {
    _ = app.sys.fileDelete(hiveTmpPathZ(kind, pathScratch(0)) orelse return);
    _ = app.sys.fileDelete(hiveBakPathZ(kind, pathScratch(1)) orelse return);
    _ = app.sys.fileDelete(hivePathZ(kind, pathScratch(2)) orelse return);
}

fn deleteLiteralPath(app: *App, comptime path: []const u8) void {
    _ = app.sys.fileDelete(literalZ(path, pathScratch(0)) orelse return);
}

fn backupHiveFile(app: *App, kind: registry.HiveKind) ?bool {
    deleteHiveBackup(app, kind);
    const hive_path = hivePathZ(kind, pathScratch(0)) orelse return null;
    if (!app.sys.exists(hive_path)) return false;
    const backup_path = hiveSelftestBackupPathZ(kind, pathScratch(1)) orelse return null;
    if (app.sys.fileCopy(hive_path, backup_path) <= 0) return null;
    return true;
}

fn restoreHiveFile(app: *App, kind: registry.HiveKind, restore_original: bool) void {
    if (restore_original) {
        cleanupHiveFiles(app, kind);
        const backup_path = hiveSelftestBackupPathZ(kind, pathScratch(0)) orelse return;
        const hive_path = hivePathZ(kind, pathScratch(1)) orelse return;
        _ = app.sys.fileCopy(backup_path, hive_path);
    } else {
        cleanupHiveFiles(app, kind);
    }
    deleteHiveBackup(app, kind);
}

fn deleteHiveBackup(app: *App, kind: registry.HiveKind) void {
    _ = app.sys.fileDelete(hiveSelftestBackupPathZ(kind, pathScratch(0)) orelse return);
}

fn expectStringValue(app: *App, key_path: []const u8, value_name: []const u8, expected: []const u8) bool {
    const value = loadValueSilent(app, key_path, value_name) orelse return false;
    const text = value.asString() orelse return false;
    return bytesEqual(text, expected);
}

fn expectU32Value(app: *App, key_path: []const u8, value_name: []const u8, expected: u32) bool {
    const value = loadValueSilent(app, key_path, value_name) orelse return false;
    return value.asU32() == expected;
}

fn expectBoolValue(app: *App, key_path: []const u8, value_name: []const u8, expected: bool) bool {
    const value = loadValueSilent(app, key_path, value_name) orelse return false;
    return value.asBool() == expected;
}

fn expectMissingValue(app: *App, key_path: []const u8, value_name: []const u8) bool {
    const parsed = registry.parseRoot(key_path) orelse return false;
    const loaded = loadHiveSilent(app, parsed.kind);
    if (!loaded.valid) return false;
    const hive = loaded.view.?;
    const key_index = hive.findKey(key_path) orelse return true;
    return hive.findValue(key_index, value_name) == null;
}

fn loadValueSilent(app: *App, key_path: []const u8, value_name: []const u8) ?registry.Value {
    const parsed = registry.parseRoot(key_path) orelse return null;
    const loaded = loadHiveSilent(app, parsed.kind);
    if (!loaded.valid) return null;
    return loaded.view.?.getValue(key_path, value_name);
}

fn fail(app: *App, text: []const u8) i32 {
    app.write("REG: ");
    app.write(text);
    app.line("");
    return 1;
}

fn activeHiveKind(kind: registry.HiveKind) bool {
    return kind == .system;
}

fn hivePathZ(kind: registry.HiveKind, out: []u8) ?[*:0]const u8 {
    return switch (kind) {
        .system => literalZ("C:\\R4OS\\REGISTRY\\SYSTEM.R4R", out),
        else => null,
    };
}

fn hiveTmpPathZ(kind: registry.HiveKind, out: []u8) ?[*:0]const u8 {
    return switch (kind) {
        .system => literalZ("C:\\R4OS\\REGISTRY\\SYSTEM.TMP", out),
        else => null,
    };
}

fn hiveBakPathZ(kind: registry.HiveKind, out: []u8) ?[*:0]const u8 {
    return switch (kind) {
        .system => literalZ("C:\\R4OS\\REGISTRY\\SYSTEM.BAK", out),
        else => null,
    };
}

fn hiveSelftestBackupPathZ(kind: registry.HiveKind, out: []u8) ?[*:0]const u8 {
    return switch (kind) {
        .system => literalZ("C:\\R4OS\\REGISTRY\\REGSYS.SAV", out),
        else => null,
    };
}

fn valueTypeName(value_type: registry.ValueType) []const u8 {
    return switch (value_type) {
        .string => "string",
        .u32 => "u32",
        .u64 => "u64",
        .bool => "bool",
        .binary => "binary",
        .multi_string => "multi_string",
    };
}

fn parseValueType(text: []const u8) ?registry.ValueType {
    if (equalsIgnoreCase(text, "string")) return .string;
    if (equalsIgnoreCase(text, "u32")) return .u32;
    if (equalsIgnoreCase(text, "u64")) return .u64;
    if (equalsIgnoreCase(text, "bool")) return .bool;
    if (equalsIgnoreCase(text, "binary")) return .binary;
    if (equalsIgnoreCase(text, "multi_string")) return .multi_string;
    return null;
}

fn parseSetData(value_type: registry.ValueType, text: []const u8, out: []u8) ?[]const u8 {
    return switch (value_type) {
        .string => parseStringData(text, out),
        .u32 => parseIntegerData(text, out, 4),
        .u64 => parseIntegerData(text, out, 8),
        .bool => parseBoolData(text, out),
        .binary => parseBinaryData(text, out),
        .multi_string => parseMultiStringData(text, out),
    };
}

fn parseStringData(text: []const u8, out: []u8) ?[]const u8 {
    const input = trim(text);
    if (input.len == 0) return out[0..0];
    if (input[0] == '"') {
        const parsed = parseQuotedString(input, out) orelse return null;
        if (trim(parsed.rest).len != 0) return null;
        return parsed.value;
    }
    if (input.len > out.len) return null;
    @memcpy(out[0..input.len], input);
    return out[0..input.len];
}

const ParsedString = struct {
    value: []const u8,
    rest: []const u8,
};

fn parseQuotedString(text: []const u8, out: []u8) ?ParsedString {
    const input = trim(text);
    if (input.len == 0 or input[0] != '"') return null;
    var out_len: usize = 0;
    var index: usize = 1;
    while (index < input.len) : (index += 1) {
        const ch = input[index];
        if (ch == '"') return .{ .value = out[0..out_len], .rest = input[index + 1 ..] };
        if (out_len >= out.len) return null;
        if (ch != '\\') {
            out[out_len] = ch;
            out_len += 1;
            continue;
        }

        index += 1;
        if (index >= input.len) return null;
        const escaped = input[index];
        const value: u8 = switch (escaped) {
            '\\' => '\\',
            '"' => '"',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'x' => blk: {
                if (index + 2 >= input.len) return null;
                const hi = hexNibble(input[index + 1]) orelse return null;
                const lo = hexNibble(input[index + 2]) orelse return null;
                index += 2;
                break :blk (hi << 4) | lo;
            },
            else => return null,
        };
        out[out_len] = value;
        out_len += 1;
    }
    return null;
}

fn parseIntegerData(text: []const u8, out: []u8, comptime byte_count: usize) ?[]const u8 {
    if (out.len < byte_count) return null;
    const value = parseUnsigned(text) orelse return null;
    if (byte_count == 4 and value > 0xffff_ffff) return null;
    if (byte_count == 4) {
        writeU32(out, 0, @intCast(value));
    } else {
        writeU64(out, 0, value);
    }
    return out[0..byte_count];
}

fn parseUnsigned(text: []const u8) ?u64 {
    const max_u64: u64 = 0xffff_ffff_ffff_ffff;
    const input = trim(text);
    if (input.len == 0) return null;
    var value: u64 = 0;
    var index: usize = 0;
    var base: u64 = 10;
    if (input.len > 2 and input[0] == '0' and (input[1] == 'x' or input[1] == 'X')) {
        base = 16;
        index = 2;
        if (index >= input.len) return null;
    }
    while (index < input.len) : (index += 1) {
        const digit = if (base == 16) hexNibble(input[index]) orelse return null else decimalDigit(input[index]) orelse return null;
        const digit64: u64 = digit;
        if (value > (max_u64 - digit64) / base) return null;
        value = value * base + digit64;
    }
    return value;
}

fn parseBoolData(text: []const u8, out: []u8) ?[]const u8 {
    if (out.len < 1) return null;
    const input = trim(text);
    if (equalsIgnoreCase(input, "true") or equalsIgnoreCase(input, "1")) {
        out[0] = 1;
    } else if (equalsIgnoreCase(input, "false") or equalsIgnoreCase(input, "0")) {
        out[0] = 0;
    } else {
        return null;
    }
    return out[0..1];
}

fn parseBinaryData(text: []const u8, out: []u8) ?[]const u8 {
    var half: ?u8 = null;
    var out_len: usize = 0;
    for (text) |ch| {
        if (isSpace(ch)) continue;
        const nibble = hexNibble(ch) orelse return null;
        if (half) |hi| {
            if (out_len >= out.len) return null;
            out[out_len] = (hi << 4) | nibble;
            out_len += 1;
            half = null;
        } else {
            half = nibble;
        }
    }
    if (half != null) return null;
    return out[0..out_len];
}

fn parseMultiStringData(text: []const u8, out: []u8) ?[]const u8 {
    const input = trim(text);
    if (input.len < 2 or input[0] != '(' or input[input.len - 1] != ')') return null;
    if (out.len < 4) return null;
    var count: u32 = 0;
    var out_len: usize = 4;
    var rest = trim(input[1 .. input.len - 1]);
    while (rest.len > 0) {
        if (out_len + 2 > out.len) return null;
        const parsed = parseQuotedString(rest, out[out_len + 2 ..]) orelse return null;
        if (parsed.value.len > 0xffff) return null;
        writeU16(out, out_len, @intCast(parsed.value.len));
        out_len += 2 + parsed.value.len;
        count += 1;
        rest = trim(parsed.rest);
        if (rest.len == 0) break;
        if (rest[0] != ',') return null;
        rest = trim(rest[1..]);
        if (rest.len == 0) return null;
    }
    writeU32(out, 0, count);
    return out[0..out_len];
}

fn decimalDigit(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    return null;
}

fn hexNibble(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

const SplitValue = struct {
    parent: []const u8,
    value: []const u8,
};

fn splitValuePath(path: []const u8, parent_buf: []u8) ?SplitValue {
    const root = registry.parseRoot(path) orelse return null;
    if (root.rest.len == 0) return null;
    var last_sep: ?usize = null;
    var index: usize = 0;
    while (index < path.len) : (index += 1) {
        if (path[index] == '\\' or path[index] == '/') last_sep = index;
    }
    const sep = last_sep orelse return null;
    if (sep == 0 or sep + 1 >= path.len or sep > parent_buf.len) return null;
    @memcpy(parent_buf[0..sep], path[0..sep]);
    return .{ .parent = parent_buf[0..sep], .value = path[sep + 1 ..] };
}

fn writeEscapedString(app: *App, text: []const u8) void {
    app.write("\"");
    for (text) |ch| writeEscapedByte(app, ch);
    app.write("\"");
}

fn writeEscapedByte(app: *App, ch: u8) void {
    switch (ch) {
        '\\' => app.write("\\\\"),
        '"' => app.write("\\\""),
        '\n' => app.write("\\n"),
        '\r' => app.write("\\r"),
        '\t' => app.write("\\t"),
        else => {
            if (ch < 0x20 or ch == 0x7f) {
                app.write("\\x");
                writeHexByte(app, ch);
            } else {
                app.write(&[_]u8{ch});
            }
        },
    }
}

fn writeEscapedStringOut(out: *ExportOut, text: []const u8) void {
    out.write("\"");
    for (text) |ch| writeEscapedByteOut(out, ch);
    out.write("\"");
}

fn writeEscapedByteOut(out: *ExportOut, ch: u8) void {
    switch (ch) {
        '\\' => out.write("\\\\"),
        '"' => out.write("\\\""),
        '\n' => out.write("\\n"),
        '\r' => out.write("\\r"),
        '\t' => out.write("\\t"),
        else => {
            if (ch < 0x20 or ch == 0x7f) {
                out.write("\\x");
                writeHexByteOut(out, ch);
            } else {
                out.write(&[_]u8{ch});
            }
        },
    }
}

fn writeBinary(app: *App, data: []const u8) void {
    for (data, 0..) |byte, index| {
        if (index != 0) app.write(" ");
        writeHexByte(app, byte);
    }
}

fn writeBinaryOut(out: *ExportOut, data: []const u8) void {
    for (data, 0..) |byte, index| {
        if (index != 0) out.write(" ");
        writeHexByteOut(out, byte);
    }
}

fn writeMultiString(app: *App, data: []const u8) void {
    app.write("(");
    const count = readU32(data, 0);
    var offset: usize = 4;
    var index: u32 = 0;
    while (index < count and offset + 2 <= data.len) : (index += 1) {
        const len = readU16(data, offset);
        offset += 2;
        if (offset + len > data.len) break;
        if (index != 0) app.write(",");
        writeEscapedString(app, data[offset .. offset + len]);
        offset += len;
    }
    app.write(")");
}

fn writeMultiStringOut(out: *ExportOut, data: []const u8) void {
    out.write("(");
    const count = readU32(data, 0);
    var offset: usize = 4;
    var index: u32 = 0;
    while (index < count and offset + 2 <= data.len) : (index += 1) {
        const len = readU16(data, offset);
        offset += 2;
        if (offset + len > data.len) break;
        if (index != 0) out.write(",");
        writeEscapedStringOut(out, data[offset .. offset + len]);
        offset += len;
    }
    out.write(")");
}

fn writeHexByte(app: *App, byte: u8) void {
    const digits = "0123456789ABCDEF";
    app.write(&[_]u8{ digits[byte >> 4], digits[byte & 0x0f] });
}

fn writeHexByteOut(out: *ExportOut, byte: u8) void {
    const digits = "0123456789ABCDEF";
    out.write(&[_]u8{ digits[byte >> 4], digits[byte & 0x0f] });
}

fn writeDec(app: *App, value: u64) void {
    var buf: [20]u8 = undefined;
    var pos = buf.len;
    var n = value;
    if (n == 0) {
        app.write("0");
        return;
    }
    while (n > 0) {
        pos -= 1;
        buf[pos] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    app.write(buf[pos..]);
}

fn writeDecOut(out: *ExportOut, value: u64) void {
    var buf: [20]u8 = undefined;
    var pos = buf.len;
    var n = value;
    if (n == 0) {
        out.write("0");
        return;
    }
    while (n > 0) {
        pos -= 1;
        buf[pos] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    out.write(buf[pos..]);
}

fn takeToken(text_raw: []const u8) ?Token {
    const text = trim(text_raw);
    if (text.len == 0) return null;
    if (text[0] == '"') {
        var index: usize = 1;
        while (index < text.len) : (index += 1) {
            if (text[index] == '"') {
                return .{ .token = text[1..index], .rest = text[index + 1 ..] };
            }
        }
        return .{ .token = text[1..], .rest = "" };
    }
    var index: usize = 0;
    while (index < text.len and !isSpace(text[index])) : (index += 1) {}
    return .{ .token = text[0..index], .rest = text[index..] };
}

fn makeZ(text: []const u8, out: []u8) ?[*:0]const u8 {
    if (text.len + 1 > out.len) return null;
    if (text.len != 0) @memcpy(out[0..text.len], text);
    out[text.len] = 0;
    return @ptrCast(out.ptr);
}

fn literalZ(comptime text: []const u8, out: []u8) ?[*:0]const u8 {
    if (text.len + 1 > out.len) return null;
    inline for (text, 0..) |ch, index| {
        out[index] = ch;
    }
    out[text.len] = 0;
    return @ptrCast(out.ptr);
}

fn zSlice(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn spanZPtr(ptr: [*:0]const u8) []const u8 {
    return zSlice(ptr);
}

fn findByte(text: []const u8, needle: u8) ?usize {
    for (text, 0..) |ch, index| {
        if (ch == needle) return index;
    }
    return null;
}

fn stripUtf8Bom(text: []const u8) []const u8 {
    if (text.len >= 3 and text[0] == 0xef and text[1] == 0xbb and text[2] == 0xbf) return text[3..];
    return text;
}

fn stripLineEnding(text: []const u8) []const u8 {
    if (text.len > 0 and text[text.len - 1] == '\r') return text[0 .. text.len - 1];
    return text;
}

fn trim(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and isSpace(text[start])) : (start += 1) {}
    while (end > start and isSpace(text[end - 1])) : (end -= 1) {}
    return text[start..end];
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (asciiUpper(a[index]) != asciiUpper(b[index])) return false;
    }
    return true;
}

fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var index: usize = 0;
    while (index < a.len) : (index += 1) {
        if (a[index] != b[index]) return false;
    }
    return true;
}

fn fixedZEquals(buf: []const u8, expected: []const u8) bool {
    var len: usize = 0;
    while (len < buf.len and buf[len] != 0) : (len += 1) {}
    return bytesEqual(buf[0..len], expected);
}

fn asciiUpper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) |
        (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, readU32(bytes, offset)) |
        (@as(u64, readU32(bytes, offset + 4)) << 32);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @intCast(value & 0xff);
    bytes[offset + 1] = @intCast((value >> 8) & 0xff);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @intCast(value & 0xff);
    bytes[offset + 1] = @intCast((value >> 8) & 0xff);
    bytes[offset + 2] = @intCast((value >> 16) & 0xff);
    bytes[offset + 3] = @intCast((value >> 24) & 0xff);
}

fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    writeU32(bytes, offset, @intCast(value & 0xffff_ffff));
    writeU32(bytes, offset + 4, @intCast(value >> 32));
}

fn writeSelftestHive(out: []u8) usize {
    const header_size = registry.header_size;
    const key_table_offset = header_size;
    const key_table_size = registry.key_record_size * 2;
    const value_table_offset = key_table_offset + key_table_size;
    const value_table_size = registry.value_record_size * 2;
    const string_heap_offset = value_table_offset + value_table_size;
    const string_heap = "SystemNameEnabled";
    const data_heap_offset = string_heap_offset + string_heap.len;
    const data_heap = "R4OS" ++ "\x01";
    const file_size = data_heap_offset + data_heap.len;

    var index: usize = 0;
    while (index < file_size) : (index += 1) out[index] = 0;
    @memcpy(out[0..4], registry.magic);
    writeU16(out, 4, 1);
    writeU16(out, 6, header_size);
    writeU16(out, 8, 1);
    writeU16(out, 10, @intFromEnum(registry.HiveKind.system));
    writeU64(out, 16, file_size);
    writeU64(out, 24, 1);
    writeU32(out, 32, key_table_offset);
    writeU32(out, 36, 2);
    writeU32(out, 40, value_table_offset);
    writeU32(out, 44, 2);
    writeU32(out, 48, string_heap_offset);
    writeU32(out, 52, string_heap.len);
    writeU32(out, 56, data_heap_offset);
    writeU32(out, 60, data_heap.len);

    writeKeyRecord(out, key_table_offset, registry.invalid_index, 0, 0, registry.invalid_index, 0, 1, 1);
    writeKeyRecord(out, key_table_offset + registry.key_record_size, 0, 0, 6, 0, 2, registry.invalid_index, 0);

    writeValueRecord(out, value_table_offset, 1, 6, 4, .string, 0, 4);
    writeValueRecord(out, value_table_offset + registry.value_record_size, 1, 10, 7, .bool, 4, 1);

    @memcpy(out[string_heap_offset .. string_heap_offset + string_heap.len], string_heap);
    @memcpy(out[data_heap_offset .. data_heap_offset + data_heap.len], data_heap);
    return file_size;
}

fn writeKeyRecord(out: []u8, offset: usize, parent: u32, name_offset: u32, name_len: u16, first_value: u32, value_count: u32, first_child: u32, child_count: u32) void {
    writeU32(out, offset + 0, parent);
    writeU32(out, offset + 4, name_offset);
    writeU16(out, offset + 8, name_len);
    writeU32(out, offset + 12, first_value);
    writeU32(out, offset + 16, value_count);
    writeU32(out, offset + 20, first_child);
    writeU32(out, offset + 24, child_count);
}

fn writeValueRecord(out: []u8, offset: usize, owner: u32, name_offset: u32, name_len: u16, value_type: registry.ValueType, data_offset: u32, data_len: u32) void {
    writeU32(out, offset + 0, owner);
    writeU32(out, offset + 4, name_offset);
    writeU16(out, offset + 8, name_len);
    writeU16(out, offset + 10, @intFromEnum(value_type));
    writeU32(out, offset + 16, data_offset);
    writeU32(out, offset + 20, data_len);
}
