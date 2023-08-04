const std = @import("std");
const c = @cImport({
    @cInclude("termios.h");
});

const io = std.io;

const stdin_fileno = std.os.STDIN_FILENO;
var orig_termios: c.struct_termios = undefined;

const TerminalError = error{
    tcgetattr,
    tcsetattr,
};

fn enableRawMode() !void {
    if (c.tcgetattr(stdin_fileno, &orig_termios) == -1) {
        return TerminalError.tcgetattr;
    }

    var raw = orig_termios;

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
    _ = c.tcsetattr(stdin_fileno, c.TCSAFLUSH, &orig_termios);
}

pub fn main() !void {
    const in_reader = io.getStdIn().reader();

    try enableRawMode();
    defer disableRawMode();

    while (true) {
        if (in_reader.readByte()) |ch| {
            if (std.ascii.isControl(ch)) {
                std.log.warn("{d}\r", .{ch});
            } else {
                std.log.warn("{d} ('{c}')\r", .{ ch, ch });
            }

            if (ch == 'q') break;
        } else |err| switch (err) {
            error.EndOfStream => {
                // timeout happened
                // std.log.warn("timeout\r", .{});
            },
            else => |e| return e,
        }
    }
}

test "kilo test" {}
