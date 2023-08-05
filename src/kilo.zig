const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
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
    orig_termios: c.struct_termios = undefined,
    screen_rows: usize = undefined,
    screen_cols: usize = undefined,
}{};

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

fn editorReadKey() !?u8 {
    if (in_reader.readByte()) |ch| {
        return ch;
    } else |err| switch (err) {
        error.EndOfStream => {
            // timeout happened
            // std.log.warn("timeout\r", .{});
            return null;
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

fn editorProcessKeypress() !bool {
    if (try editorReadKey()) |ch| {
        if (std.ascii.isControl(ch)) {
            std.log.warn("{d}\r", .{ch});
        } else {
            std.log.warn("{d} ('{c}')\r", .{ ch, ch });
        }
        return ch == ctrl_key('q');
    } else {
        // timeout
        return false;
    }
}

fn editorDrawRows(abuf: *ArrayList(u8)) !void {
    for (0..editor_config.screen_rows - 1) |_| {
        try abuf.appendSlice("~\r\n");
    }
    try abuf.appendSlice("~");
}

fn editorRefreshScreen(allocator: Allocator) !void {
    var abuf = ArrayList(u8).init(allocator);
    defer abuf.deinit();

    try abuf.appendSlice("\x1b[?25l");
    try abuf.appendSlice("\x1b[2J");
    try abuf.appendSlice("\x1b[H");

    try editorDrawRows(&abuf);

    try abuf.appendSlice("\x1b[H");
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
