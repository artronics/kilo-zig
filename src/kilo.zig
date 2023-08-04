const std = @import("std");
const c = @cImport({
    @cInclude("termios.h");
});

const io = std.io;

const stdin_fileno = std.os.STDIN_FILENO;
var orig_termios: c.struct_termios = undefined;

fn enableRawMode() void {
    _ = c.tcgetattr(stdin_fileno, &orig_termios);

    var raw = orig_termios;

    raw.c_iflag &= ~@as(c_ulong, c.BRKINT | c.ICRNL | c.INPCK | c.ISTRIP | c.IXON);
    raw.c_oflag &= ~@as(c_ulong, c.OPOST);
    raw.c_cflag |= @as(c_ulong, c.CS8);
    raw.c_lflag &= ~@as(c_ulong, c.ECHO | c.ICANON | c.IEXTEN | c.ISIG);

    _ = c.tcsetattr(stdin_fileno, c.TCSAFLUSH, &raw);
}

fn disableRawMode() void {
    _ = c.tcsetattr(stdin_fileno, c.TCSAFLUSH, &orig_termios);
}

pub fn main() !void {
    const in_reader = io.getStdIn().reader();
    enableRawMode();
    defer disableRawMode();

    var ch: u8 = try in_reader.readByte();
    // var ch: u8 = '0';
    while (ch != 'q') : (ch = try in_reader.readByte()) {
        if (std.ascii.isControl(ch)) {
            std.log.warn("{d}\r", .{ch});
        } else {
            std.log.warn("{d} ('{c}')\r", .{ ch, ch });
        }
    }
}

test "kilo test" {}
