//! A client's copy of a session's terminal, fed through a stream that
//! tells the client before the copy's history is erased (ED 3), the
//! terminal reset (RIS), or its width switched (DECCOLM), which rewraps
//! the history, so rows the client still has to show are taken out first.

const ghostty = @import("vt");

pub const Handler = struct {
    inner: ghostty.TerminalStream.Handler,
    /// Called before the copy's history goes or is rewrapped.
    before_loss: ?*const fn (ctx: *anyopaque) void = null,
    ctx: *anyopaque = undefined,

    pub fn vt(self: *Handler, comptime action: ghostty.StreamAction.Tag, value: ghostty.StreamAction.Value(action)) void {
        switch (action) {
            .erase_display_scrollback, .full_reset => if (self.before_loss) |f| f(self.ctx),
            .set_mode, .reset_mode => if (value.mode == .@"132_column") if (self.before_loss) |f| f(self.ctx),
            else => {},
        }
        self.inner.vt(action, value);
    }

    pub fn vtPrintAscii(self: *Handler, bytes: []const u8) void {
        self.inner.vtPrintAscii(bytes);
    }

    pub fn deinit(self: *Handler) void {
        self.inner.deinit();
    }
};

pub const Stream = ghostty.Stream(Handler);
