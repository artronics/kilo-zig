const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const kilo_options = @import("kilo_options");
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
});

const io = std.io;

const in_reader = io.getStdIn().reader();
const stdin_fileno = std.os.STDIN_FILENO;

const out_writer = io.getStdOut().writer();
const stdout_fileno = std.os.STDOUT_FILENO;

const Erow = []u8;

const EditorConfig = struct {
    allocator: Allocator,
    cx: usize = 0,
    cy: usize = 0,
    screen_rows: usize = undefined,
    screen_cols: usize = undefined,
    row_offset: usize = 0,
    row: ArrayList(Erow),
    orig_termios: c.struct_termios = undefined,

    fn init(allocator: Allocator) EditorConfig {
        return EditorConfig{
            .allocator = allocator,
            .row = ArrayList(Erow).init(allocator),
        };
    }

    fn deinit(self: EditorConfig) void {
        for (self.row.items) |i| {
            self.allocator.free(i);
        }
        self.row.deinit();
    }
};

var ec: EditorConfig = undefined;

const EditorKey = union(enum) {
    char: u8,

    del_key,

    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,

    page_up,
    page_down,
    home_key,
    end_key,

    timeout,
};

const TerminalError = error{
    tcgetattr,
    tcsetattr,
    window_size,
    cursor_position,
};

fn enableRawMode() !void {
    if (c.tcgetattr(stdin_fileno, &ec.orig_termios) == -1) {
        return TerminalError.tcgetattr;
    }

    var raw = ec.orig_termios;

    raw.c_iflag &= ~@as(c_ulong, c.BRKINT | c.ICRNL | c.INPCK | c.ISTRIP | c.IXON);
    raw.c_oflag &= ~@as(c_ulong, c.OPOST);
    raw.c_cflag |= @as(c_ulong, c.CS8);
    raw.c_lflag &= ~@as(c_ulong, c.ECHO | c.ICANON | c.IEXTEN | c.ISIG);
    raw.c_cc[c.VMIN] = 0;
    raw.c_cc[c.VTIME] = 1;

    if (c.tcsetattr(stdin_fileno, c.TCSAFLUSH, &raw) == -1) {
        return TerminalError.tcsetattr;
    }
}

fn disableRawMode() void {
    _ = c.tcsetattr(stdin_fileno, c.TCSAFLUSH, &ec.orig_termios);
}

fn ctrl_key(ch: u8) u8 {
    return 0x1f & ch;
}

fn editorReadKey() !EditorKey {
    if (in_reader.readByte()) |ch| {
        const esc = 0x1b;
        if (ch == esc) {
            const ch1 = in_reader.readByte() catch esc;
            const ch2 = in_reader.readByte() catch esc;
            return if (ch1 == '[') {
                return switch (ch2) {
                    '0'...'9' => {
                        const ch3 = in_reader.readByte() catch esc;
                        return if (ch3 == '~') {
                            return switch (ch2) {
                                '1' => EditorKey.home_key,
                                '3' => EditorKey.del_key,
                                '4' => EditorKey.end_key,
                                '5' => EditorKey.page_up,
                                '6' => EditorKey.page_down,
                                '7' => EditorKey.home_key,
                                '8' => EditorKey.end_key,
                                else => EditorKey{ .char = esc },
                            };
                        } else return EditorKey{ .char = esc };
                    },
                    'A' => EditorKey.arrow_up,
                    'B' => EditorKey.arrow_down,
                    'C' => EditorKey.arrow_right,
                    'D' => EditorKey.arrow_left,
                    'H' => EditorKey.home_key,
                    'F' => EditorKey.end_key,
                    else => EditorKey{ .char = esc },
                };
            } else if (ch1 == 'O') {
                return switch (ch2) {
                    'H' => EditorKey.home_key,
                    'F' => EditorKey.end_key,
                    else => EditorKey{ .char = esc },
                };
            } else {
                return EditorKey{ .char = esc };
            };
        }
        return EditorKey{ .char = ch };
    } else |err| switch (err) {
        error.EndOfStream => {
            // timeout happened
            // std.log.warn("timeout\r", .{});
            return EditorKey.timeout;
        },
        else => |e| return e,
    }
}

fn getCursorPosition(rows: *usize, cols: *usize) !void {
    try out_writer.writeAll("\x1b[6n");

    // Check and discard the first two bytes
    if (try in_reader.readByte() != '\x1b' or try in_reader.readByte() != '[') return TerminalError.cursor_position;

    var buf: [32]u8 = undefined;
    var response = io.fixedBufferStream(&buf);

    try in_reader.streamUntilDelimiter(response.writer(), ';', 32);
    rows.* = try std.fmt.parseInt(usize, response.buffer[0..try response.getPos()], 10);

    response.reset();

    try in_reader.streamUntilDelimiter(response.writer(), 'R', 32);
    cols.* = try std.fmt.parseInt(usize, response.buffer[0..try response.getPos()], 10);
}

fn getWindowSize(rows: *usize, cols: *usize) !void {
    var ws: c.winsize = undefined;

    if (c.ioctl(stdout_fileno, c.TIOCGWINSZ, &ws) == -1 or ws.ws_col == 0) {
        try out_writer.writeAll("\x1b[999C\x1b[999B");
        try getCursorPosition(rows, cols);
    } else {
        cols.* = ws.ws_col;
        rows.* = ws.ws_row;
    }
}

fn editorAppendRow(allocator: Allocator, row: []const u8) !void {
    var row_cp = try allocator.alloc(u8, row.len);
    @memcpy(row_cp, row);

    try ec.row.append(row_cp);
}

fn editorOpen(allocator: Allocator, file: []const u8) !void {
    var f = try std.fs.cwd().openFile(file, .{});
    defer f.close();

    const content = try f.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(content);

    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (i < content.len and content[i] == '\r') i += 1;
        var line_start: usize = i;

        while (i < content.len and content[i] != '\n') : (i += 1) {}
        try editorAppendRow(allocator, content[line_start..i]);
    }
}

fn editorMoveCursor(ch: EditorKey) void {
    switch (ch) {
        EditorKey.arrow_left => {
            if (ec.cx != 0) {
                ec.cx -= 1;
            }
        },
        EditorKey.arrow_right => {
            if (ec.cx != ec.screen_cols - 1) {
                ec.cx += 1;
            }
        },
        EditorKey.arrow_up => {
            if (ec.cy != 0) {
                ec.cy -= 1;
            }
        },
        EditorKey.arrow_down => {
            if (ec.cy < ec.row.items.len) {
                ec.cy += 1;
            }
        },
        else => unreachable,
    }
}

fn editorProcessKeypress() !bool {
    const key = try editorReadKey();
    var quit = false;
    switch (key) {
        EditorKey.arrow_left, EditorKey.arrow_right, EditorKey.arrow_up, EditorKey.arrow_down => {
            editorMoveCursor(key);
        },
        EditorKey.page_up => {
            for (0..ec.screen_rows) |_| {
                editorMoveCursor(EditorKey.arrow_up);
            }
        },
        EditorKey.page_down => {
            for (0..ec.screen_rows) |_| {
                editorMoveCursor(EditorKey.arrow_down);
            }
        },
        EditorKey.home_key => {
            ec.cx = 0;
        },
        EditorKey.end_key => {
            ec.cx += ec.screen_cols - 1;
        },
        EditorKey.del_key => {},
        EditorKey.char => |ch| {
            quit = ch == ctrl_key('q');
        },
        EditorKey.timeout => {},
    }

    return quit;
}

fn editorScroll() void {
    if (ec.cy < ec.row_offset) {
        ec.row_offset = ec.cy;
    }
    if (ec.cy >= ec.row_offset + ec.screen_rows) {
        ec.row_offset = ec.cy - ec.screen_rows + 1;
    }
}

fn editorDrawRows(abuf: *ArrayList(u8)) !void {
    // draw the line | clean the rest of the line | go to the next line
    const rows = ec.screen_rows;
    const cols = ec.screen_cols;
    const num_rows = ec.row.items.len;
    for (0..rows - 1) |y| {
        var file_row = y + ec.row_offset;
        if (file_row >= num_rows) {
            if (num_rows == 0 and y == rows / 3) {
                var buf: [80]u8 = undefined;
                const welcome = try std.fmt.bufPrint(&buf, "KiloZig editor -- version {s}", .{kilo_options.kilo_version});
                const msg = welcome[0..@min(welcome.len, cols)];
                var padding = (cols - msg.len) / 2;
                if (padding != 0) {
                    try abuf.append('~');
                    padding -= 1;
                }
                for (0..padding) |_| {
                    try abuf.append(' ');
                }
                try abuf.appendSlice(welcome);
            } else {
                try abuf.appendSlice("~");
            }
        } else {
            const row = ec.row.items[file_row];
            const l = @min(ec.screen_cols, row.len);
            try abuf.appendSlice(row[0..l]);
        }

        try abuf.appendSlice("\x1b[K");
        if (y < ec.screen_rows - 1) {
            try abuf.appendSlice("\r\n");
        }
    }
}

fn editorRefreshScreen(allocator: Allocator) !void {
    var abuf = ArrayList(u8).init(allocator);
    defer abuf.deinit();

    editorScroll();

    try abuf.appendSlice("\x1b[?25l");
    try abuf.appendSlice("\x1b[H");

    try editorDrawRows(&abuf);

    var buf: [32]u8 = undefined;
    const move_cur = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ ec.cy - ec.row_offset + 1, ec.cx + 1 });
    try abuf.appendSlice(move_cur);

    try abuf.appendSlice("\x1b[?25h");

    try out_writer.writeAll(abuf.items);
}

fn initEditor(allocator: Allocator) !void {
    ec = EditorConfig.init(allocator);
    try getWindowSize(&ec.screen_rows, &ec.screen_cols);
}

pub fn main() !void {
    try enableRawMode();
    defer disableRawMode();
    defer {
        out_writer.writeAll("\x1b[2J") catch {};
        out_writer.writeAll("\x1b[H") catch {};
    }
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    try initEditor(allocator);
    defer ec.deinit();

    const args = try std.process.argsAlloc(allocator);
    if (args.len > 1) {
        try editorOpen(allocator, args[1]);
    }

    while (true) {
        try editorRefreshScreen(allocator);
        const quit = try editorProcessKeypress();
        if (quit) break;
    }
}

test "kilo test" {}
