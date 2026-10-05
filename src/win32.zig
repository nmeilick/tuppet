//! Minimal Win32 bindings for the Windows port: ConPTY, named pipes,
//! process spawning with the pseudoconsole attribute, and console I/O.
//! Only compiled when targeting Windows.

const std = @import("std");
const builtin = @import("builtin");

pub const windows = std.os.windows;

pub const HANDLE = windows.HANDLE;
pub const HPCON = HANDLE;
pub const DWORD = windows.DWORD;
pub const BOOL = c_int;
pub const ULONG = windows.ULONG;
pub const HRESULT = i32;
pub const LPVOID = windows.LPVOID;
pub const LPCVOID = windows.LPCVOID;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPWSTR = windows.LPWSTR;
pub const LPDWORD = ?*DWORD;
pub const PVOID = windows.PVOID;

pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const NULL_HANDLE: HANDLE = null;

pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x1;
pub const FILE_SHARE_WRITE: DWORD = 0x2;
pub const OPEN_EXISTING: DWORD = 3;
pub const CREATE_ALWAYS: DWORD = 2;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
pub const FILE_FLAG_OVERLAPPED: DWORD = 0x40000000;

pub const PIPE_ACCESS_DUPLEX: DWORD = 0x3;
pub const PIPE_TYPE_BYTE: DWORD = 0x0;
pub const PIPE_READMODE_BYTE: DWORD = 0x0;
pub const PIPE_WAIT: DWORD = 0x0;
pub const PIPE_UNLIMITED_INSTANCES: DWORD = 0xFF;
pub const NMPWAIT_USE_DEFAULT_WAIT: DWORD = 0x0;

pub const ERROR_PIPE_BUSY: DWORD = 231;
pub const ERROR_PIPE_CONNECTED: DWORD = 535;
pub const ERROR_BROKEN_PIPE: DWORD = 109;

pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));

pub const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
pub const CREATE_NO_WINDOW: DWORD = 0x08000000;
pub const CREATE_NEW_PROCESS_GROUP: DWORD = 0x00000200;
pub const CREATE_SUSPENDED: DWORD = 0x00000004;
pub const DETACHED_PROCESS: DWORD = 0x00000008;
pub const INFINITE: DWORD = 0xFFFFFFFF;

pub const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;
pub const JobObjectExtendedLimitInformation: c_int = 9;

pub const PROCESS_TERMINATE: DWORD = 0x0001;

pub const STARTF_USESTDHANDLES: DWORD = 0x00000100;
pub const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;

pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: ULONG = 0x00020016;

pub const COORD = extern struct {
    x: i16,
    y: i16,
};

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

pub const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?LPWSTR,
    lpDesktop: ?LPWSTR,
    lpTitle: ?LPWSTR,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?*u8,
    hStdInput: HANDLE,
    hStdOutput: HANDLE,
    hStdError: HANDLE,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: DWORD,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: DWORD,
    Affinity: usize,
    PriorityClass: DWORD,
    SchedulingClass: DWORD,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

pub extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.winapi) HRESULT;

pub extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: COORD) callconv(.winapi) HRESULT;

pub extern "kernel32" fn CreateNamedPipeW(
    lpName: LPCWSTR,
    dwOpenMode: DWORD,
    dwPipeMode: DWORD,
    nMaxInstances: DWORD,
    nOutBufferSize: DWORD,
    nInBufferSize: DWORD,
    nDefaultTimeOut: DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
) callconv(.winapi) HANDLE;

pub extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;

pub extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.winapi) BOOL;

pub extern "kernel32" fn WaitNamedPipeW(lpNamedPipeName: LPCWSTR, nTimeOut: DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;

pub extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetHandleInformation(
    hObject: HANDLE,
    dwMask: DWORD,
    dwFlags: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    lpSize: *usize,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: *anyopaque,
    dwFlags: DWORD,
    // DWORD_PTR in the SDK: pointer-sized, not ULONG.
    attribute: usize,
    lpValue: LPCVOID,
    cbSize: usize,
    lpPreviousValue: ?PVOID,
    lpReturnSize: ?*usize,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) callconv(.winapi) void;

pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?LPCWSTR,
    lpCommandLine: LPWSTR,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?LPVOID,
    lpCurrentDirectory: ?LPCWSTR,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*SECURITY_ATTRIBUTES,
    lpName: ?LPCWSTR,
) callconv(.winapi) HANDLE;

pub extern "kernel32" fn SetInformationJobObject(
    hJob: HANDLE,
    JobObjectInformationClass: c_int,
    lpJobObjectInformation: LPVOID,
    cbJobObjectInformationLength: DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn AssignProcessToJobObject(hJob: HANDLE, hProcess: HANDLE) callconv(.winapi) BOOL;

pub extern "kernel32" fn TerminateJobObject(hJob: HANDLE, uExitCode: windows.UINT) callconv(.winapi) BOOL;

pub extern "kernel32" fn ResumeThread(hThread: HANDLE) callconv(.winapi) DWORD;

pub extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: windows.UINT) callconv(.winapi) BOOL;

pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;

pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;

pub extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;

pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;

pub extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: LPCVOID,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: LPDWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: LPVOID,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: LPDWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

pub extern "kernel32" fn MultiByteToWideChar(
    codePage: DWORD,
    dwFlags: DWORD,
    lpMultiByteStr: [*]const u8,
    cbMultiByte: i32,
    lpWideCharStr: ?[*]u16,
    cchWideChar: i32,
) callconv(.winapi) i32;

pub const CP_UTF8: DWORD = 65001;

// --- named-pipe ownership and identity ---------------------------------

pub const PIPE_NOWAIT: DWORD = 0x1;
pub const PIPE_REJECT_REMOTE_CLIENTS: DWORD = 0x8;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: DWORD = 0x00080000;
pub const SECURITY_SQOS_PRESENT: DWORD = 0x00100000;
pub const SECURITY_IDENTIFICATION: DWORD = 0x00010000;
pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub const ERROR_ACCESS_DENIED: DWORD = 5;
pub const ERROR_NO_DATA: DWORD = 232;
pub const ERROR_PIPE_NOT_CONNECTED: DWORD = 233;
pub const TOKEN_QUERY: DWORD = 0x0008;
pub const TokenUser: c_int = 1;
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
pub const SDDL_REVISION_1: DWORD = 1;

pub const PSID = *anyopaque;

pub const SID_AND_ATTRIBUTES = extern struct {
    Sid: PSID,
    Attributes: DWORD,
};

pub const TOKEN_USER = extern struct {
    User: SID_AND_ATTRIBUTES,
};

pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;

pub extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn GetNamedPipeServerProcessId(Pipe: HANDLE, ServerProcessId: *windows.ULONG) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetNamedPipeHandleState(
    hNamedPipe: HANDLE,
    lpMode: ?*DWORD,
    lpMaxCollectionCount: ?*DWORD,
    lpCollectDataTimeout: ?*DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn FlushFileBuffers(hFile: HANDLE) callconv(.winapi) BOOL;

pub extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub extern "advapi32" fn OpenProcessToken(ProcessHandle: HANDLE, DesiredAccess: DWORD, TokenHandle: *HANDLE) callconv(.winapi) BOOL;

pub extern "advapi32" fn GetTokenInformation(
    TokenHandle: HANDLE,
    TokenInformationClass: c_int,
    TokenInformation: ?*anyopaque,
    TokenInformationLength: DWORD,
    ReturnLength: *DWORD,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn EqualSid(pSid1: PSID, pSid2: PSID) callconv(.winapi) BOOL;

pub extern "advapi32" fn ConvertSidToStringSidW(Sid: PSID, StringSid: *?LPWSTR) callconv(.winapi) BOOL;

pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    StringSecurityDescriptor: LPCWSTR,
    StringSDRevision: DWORD,
    SecurityDescriptor: *?*anyopaque,
    SecurityDescriptorSize: ?*windows.ULONG,
) callconv(.winapi) BOOL;

/// The user SID of a process (its primary token), copied into `buf`.
pub fn processUserSid(process: HANDLE, buf: []align(@alignOf(TOKEN_USER)) u8) ?PSID {
    var token: HANDLE = undefined;
    if (OpenProcessToken(process, TOKEN_QUERY, &token) == 0) return null;
    defer _ = CloseHandle(token);
    var len: DWORD = 0;
    if (GetTokenInformation(token, TokenUser, buf.ptr, @intCast(buf.len), &len) == 0) return null;
    const user: *const TOKEN_USER = @ptrCast(buf.ptr);
    return user.User.Sid;
}

pub const HKEY = *opaque {};
/// HKEY_LOCAL_MACHINE: (HKEY)(LONG)0x80000002, sign-extended.
pub const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, @as(i32, @bitCast(@as(u32, 0x80000002)))))));
pub const RRF_RT_REG_DWORD: DWORD = 0x00000010;

pub extern "advapi32" fn RegGetValueW(
    hkey: HKEY,
    lpSubKey: LPCWSTR,
    lpValue: LPCWSTR,
    dwFlags: DWORD,
    pdwType: ?*DWORD,
    pvData: ?*anyopaque,
    pcbData: ?*DWORD,
) callconv(.winapi) i32;

/// The number of times Windows has booted, which identifies the current
/// boot.
pub fn bootCount() ?u32 {
    const key = std.unicode.utf8ToUtf16LeStringLiteral("SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management\\PrefetchParameters");
    const value = std.unicode.utf8ToUtf16LeStringLiteral("BootId");
    var data: DWORD = 0;
    var size: DWORD = @sizeOf(DWORD);
    if (RegGetValueW(HKEY_LOCAL_MACHINE, key, value, RRF_RT_REG_DWORD, null, &data, &size) != 0) return null;
    return data;
}

pub const RRF_RT_REG_SZ: DWORD = 0x00000002;

/// The machine's MachineGuid, which identifies this Windows installation.
pub fn machineGuid(buf: []u8) ?[]const u8 {
    const key = std.unicode.utf8ToUtf16LeStringLiteral("SOFTWARE\\Microsoft\\Cryptography");
    const value = std.unicode.utf8ToUtf16LeStringLiteral("MachineGuid");
    var wide: [64]u16 = undefined;
    var size: DWORD = @sizeOf(@TypeOf(wide));
    if (RegGetValueW(HKEY_LOCAL_MACHINE, key, value, RRF_RT_REG_SZ, null, &wide, &size) != 0) return null;
    const chars = std.mem.sliceTo(wide[0 .. size / 2], 0);
    const len = std.unicode.utf16LeToUtf8(buf, chars) catch return null;
    return buf[0..len];
}

/// Convert a UTF-8 string to a UTF-16 buffer (allocated by the caller).
pub fn utf8ToUtf16(buf: []u16, s: []const u8) ![]u16 {
    // MultiByteToWideChar fails on empty input; empty UTF-8 is valid.
    if (s.len == 0) {
        if (buf.len == 0) return error.BufferTooSmall;
        buf[0] = 0;
        return buf[0..1];
    }
    const n = MultiByteToWideChar(CP_UTF8, 0, s.ptr, @intCast(s.len), null, 0);
    if (n <= 0) return error.InvalidUtf8;
    if (@as(usize, @intCast(n)) + 1 > buf.len) return error.BufferTooSmall;
    _ = MultiByteToWideChar(CP_UTF8, 0, s.ptr, @intCast(s.len), buf.ptr, n);
    buf[@intCast(n)] = 0;
    return buf[0..@intCast(n + 1)];
}

/// Handle error reporting for the daemon log.
pub fn lastErrorName() []const u8 {
    return @tagName(std.os.windows.unexpectedError(GetLastError()));
}

comptime {
    _ = builtin;
}
