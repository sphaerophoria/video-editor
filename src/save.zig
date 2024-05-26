const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

fn fromJsonLeaky(comptime T: type, alloc: Allocator, json: std.json.Value) !T {
    const type_info = @typeInfo(T);
    switch (type_info) {
        .Struct => |s| {
            if (json != .object) {
                std.log.err("JSON for {any} is not object", .{T});
                return error.InvalidData;
            }

            var ret: T = undefined;
            inline for (s.fields) |field| {
                const json_field = json.object.get(field.name) orelse {
                    std.log.err("Field {s} is not present in JSON data for {any}", .{ field.name, T });
                    return error.MissingField;
                };

                @field(ret, field.name) = fromJsonLeaky(field.type, alloc, json_field) catch |e| {
                    std.log.err("Failed to parse {s} for {any}", .{ field.name, T });
                    return e;
                };
            }
            return ret;
        },
        .Float => {
            switch (json) {
                .float => |f| {
                    return @floatCast(f);
                },
                .integer => |i| {
                    return @floatFromInt(i);
                },
                .number_string => |s| {
                    return std.fmt.parseFloat(T, s) catch |e| {
                        std.log.err("Failed to parse float", .{});
                        return e;
                    };
                },
                else => {
                    std.log.err("Expected float, got {any}", .{json});
                    return error.InvalidData;
                },
            }
        },
        .Pointer => |p| {
            if (p.size == .One) {
                @compileError("fromJsonLeaky cannot parse single element pointers");
            }

            if (p.child == u8 and json == .string) {
                return json.string;
            }

            if (json != .array) {
                std.log.err("JSON for {any} is not array", .{T});
                return error.InvalidData;
            }

            // FIXME: arena
            var ret = std.ArrayList(p.child).init(alloc);
            errdefer ret.deinit();
            for (json.array.items) |item| {
                const parsed = fromJsonLeaky(p.child, alloc, item) catch |e| {
                    std.log.err("Failed to parse array element in {any}", .{T});
                    return e;
                };
                try ret.append(parsed);
            }

            return ret.items;
        },
        .Int => {
            switch (json) {
                .integer => |i| {
                    return std.math.cast(T, i) orelse {
                        std.log.err("Integer value does not cast to {any}", .{T});
                        return error.InvalidData;
                    };
                },
                .number_string => |s| {
                    return std.fmt.parseInt(T, s, 10) catch |e| {
                        std.log.err("Failed to parse int", .{});
                        return e;
                    };
                },
                else => {
                    std.log.err("Expected float, got {any}", .{json});
                    return error.InvalidData;
                },
            }
        },
        else => {
            std.log.err("Unimplemented parser for {any}", .{T});
            return error.Unimplemented;
        },
    }
}

pub const Data = struct {
    alloc: Allocator,
    inner: std.json.Parsed(std.json.Value),

    pub fn Loaded(comptime T: type) type {
        return struct {
            arena: *ArenaAllocator,
            value: T,

            pub fn deinit(self: *const @This()) void {
                const alloc = self.arena.child_allocator;
                self.arena.deinit();
                alloc.destroy(self.arena);
            }
        };
    }

    pub const Field = struct {
        alloc: Allocator,
        inner: std.json.Value,

        pub fn as(self: *const @This(), comptime T: type) !Loaded(T) {
            const arena = try self.alloc.create(ArenaAllocator);
            errdefer self.alloc.destroy(arena);

            arena.* = ArenaAllocator.init(self.alloc);
            errdefer arena.deinit();

            return .{
                .arena = arena,
                .value = try fromJsonLeaky(T, arena.allocator(), self.inner),
            };
        }
    };

    pub fn load(alloc: Allocator, path: []const u8) !Data {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var json_reader = std.json.reader(alloc, file.reader());
        defer json_reader.deinit();

        const value = std.json.parseFromTokenSource(std.json.Value, alloc, &json_reader, .{}) catch |e| {
            std.log.err("Save file is invalid json", .{});
            return e;
        };
        errdefer value.deinit();

        if (value.value != .object) {
            std.log.err("Save data expected to be JSON object", .{});
            return error.InvalidData;
        }

        return .{
            .alloc = alloc,
            .inner = value,
        };
    }

    pub fn deinit(self: *const Data) void {
        self.inner.deinit();
    }

    pub fn field(self: *const Data, key: []const u8) ?Field {
        const json = self.inner.value.object.get(key) orelse {
            return null;
        };

        return .{
            .alloc = self.alloc,
            .inner = json,
        };
    }
};

pub const Writer = struct {
    f: std.fs.File,
    json_writer: std.json.WriteStream(std.fs.File.Writer, .{ .checked_to_fixed_depth = 256 }),

    pub const FieldWriter = struct {
        json_writer: *std.json.WriteStream(std.fs.File.Writer, .{ .checked_to_fixed_depth = 256 }),

        pub fn write(self: *const @This(), value: anytype) !void {
            try self.json_writer.write(value);
        }
    };

    pub fn init(path: []const u8) !Writer {
        const f = try std.fs.cwd().createFile(path, .{});
        errdefer f.close();

        var json_writer = std.json.writeStream(f.writer(), .{
            .whitespace = .indent_2,
        });
        errdefer json_writer.deinit();

        try json_writer.beginObject();

        return .{
            .f = f,
            .json_writer = json_writer,
        };
    }

    pub fn finish(self: *Writer) !void {
        defer self.f.close();
        defer self.json_writer.deinit();

        try self.json_writer.endObject();
    }

    pub fn field(self: *Writer, key: []const u8) !FieldWriter {
        try self.json_writer.objectField(key);
        return .{ .json_writer = &self.json_writer };
    }
};
