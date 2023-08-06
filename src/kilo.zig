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

var editor_config = struct {
    cx: usize = 0,
    cy: usize = 0,
    screen_rows: usize = undefined,
    screen_cols: usize = undefined,
    orig_termios: c.struct_termios = undefined,
}{};

const EditorKey = union(enum) {
    char: u8,

    timeout,

    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,

    page_up,
    page_down,
};

const TerminalError = error{
    tcgetattr,
    tcsetattr,
    window_size,
    cursor_position,
};

fn enableRawMode() !void {
    if (c.tcgetattr(stdin_fileno, &editor_config.orig_termios) == -1) {
        return TerminalError.tcgetattr;
    }

    var raw = editor_config.orig_termios;

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
    _ = c.tcsetattr(stdin_fileno, c.TCSAFLUSH, &editor_config.orig_termios);
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
                                '5' => EditorKey.page_up,
                                '6' => EditorKey.page_down,
                                else => EditorKey{ .char = ch2 },
                            };
                        } else return EditorKey{ .char = ch3 };
                    },
                    'A' => EditorKey.arrow_up,
                    'B' => EditorKey.arrow_down,
                    'C' => EditorKey.arrow_right,
                    'D' => EditorKey.arrow_left,
                    else => EditorKey{ .char = ch2 },
                };
            } else {
                return EditorKey{ .char = ch1 };
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

fn editorMoveCursor(ch: EditorKey) void {
    switch (ch) {
        EditorKey.arrow_left => {
            if (editor_config.cx != 0) {
                editor_config.cx -= 1;
            }
        },
        EditorKey.arrow_right => {
            if (editor_config.cx != editor_config.screen_cols - 1) {
                editor_config.cx += 1;
            }
        },
        EditorKey.arrow_up => {
            if (editor_config.cy != 0) {
                editor_config.cy -= 1;
            }
        },
        EditorKey.arrow_down => {
            if (editor_config.cy != editor_config.screen_rows - 1) {
                editor_config.cy += 1;
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
            for (0..editor_config.screen_rows) |_| {
                editorMoveCursor(EditorKey.arrow_up);
            }
        },
        EditorKey.page_down => {
            for (0..editor_config.screen_rows) |_| {
                editorMoveCursor(EditorKey.arrow_down);
            }
        },
        EditorKey.char => |ch| {
            quit = ch == ctrl_key('q');
        },
        EditorKey.timeout => {},
    }

    return quit;
}

fn editorDrawRows(abuf: *ArrayList(u8)) !void {
    // draw the line | clean the rest of the line | go to the next line
    const rows = editor_config.screen_rows;
    const cols = editor_config.screen_cols;
    for (0..rows - 1) |y| {
        if (y == rows / 3) {
            var buf: [80]u8 = undefined;
            const welcome = try std.fmt.bufPrint(&buf, "KiloZig editor -- version {s}", .{kilo_options.kilo_version});
            const msg = welcome[0..@min(welcome.len, cols)];
            const padding = (cols - msg.len) / 2;
            for (0..padding) |_| {
                try abuf.append(' ');
            }
            try abuf.appendSlice(welcome);
        } else {
            try abuf.appendSlice("~");
        }
        try abuf.appendSlice("\x1b[K");
        try abuf.appendSlice("\r\n");
    }
    try abuf.appendSlice("\x1b[K");
    try abuf.appendSlice("~");
}

fn editorRefreshScreen(allocator: Allocator) !void {
    var abuf = ArrayList(u8).init(allocator);
    defer abuf.deinit();

    try abuf.appendSlice("\x1b[?25l");
    try abuf.appendSlice("\x1b[H");

    try editorDrawRows(&abuf);

    var buf: [32]u8 = undefined;
    const move_cur = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ editor_config.cy + 1, editor_config.cx + 1 });
    try abuf.appendSlice(move_cur);

    try abuf.appendSlice("\x1b[?25h");

    try out_writer.writeAll(abuf.items);
}

fn initEditor() !void {
    try getWindowSize(&editor_config.screen_rows, &editor_config.screen_cols);
}

pub fn main() !void {
    try enableRawMode();
    defer disableRawMode();
    defer {
        out_writer.writeAll("\x1b[2J") catch {};
        out_writer.writeAll("\x1b[H") catch {};
    }
    try initEditor();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    while (true) {
        try editorRefreshScreen(allocator);
        const quit = try editorProcessKeypress();
        if (quit) break;
    }
}

test "kilo test" {}
