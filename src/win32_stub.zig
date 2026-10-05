//! Empty placeholder so pty.zig/plat.zig/ipc.zig/session.zig can import
//! win32.zig on non-Windows targets without a platform switch at the
//! import site. The union members using these types are never touched
//! on POSIX; plain integer/empty types keep them embeddable.

pub const HANDLE = usize;
pub const HPCON = usize;
pub const DWORD = u32;
pub const PROCESS_INFORMATION = struct {};
pub const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));
