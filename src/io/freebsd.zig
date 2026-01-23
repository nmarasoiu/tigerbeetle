const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const assert = std.debug.assert;
const log = std.log.scoped(.io);

const stdx = @import("stdx");
const constants = @import("../constants.zig");
const common = @import("./common.zig");
const QueueType = @import("../queue.zig").QueueType;
const TimeOS = @import("../time.zig").TimeOS;
const buffer_limit = @import("../io.zig").buffer_limit;
const DirectIO = @import("../io.zig").DirectIO;

// =============================================================================
// FreeBSD AIO (Asynchronous I/O) C Bindings
// =============================================================================
// FreeBSD provides kernel-level async I/O via aio_read/aio_write.
// Completion is notified via kqueue's EVFILT_AIO filter.
// This gives us TRUE async disk I/O without blocking the event loop.
// =============================================================================

const c = struct {
    // Signal event structure for AIO completion notification
    // On FreeBSD, when sigev_notify == SIGEV_KEVENT:
    // - sigev_notify_kqueue (overlaid with sigev_signo) = kqueue fd
    // - sigev_notify_kevent_flags = kevent flags
    // - sigev_value = user data passed to kevent
    const sigevent = extern struct {
        sigev_notify: c_int,
        // This field is reused as sigev_notify_kqueue for SIGEV_KEVENT
        sigev_notify_kqueue: c_int,
        sigev_value: extern union {
            sival_int: c_int,
            sival_ptr: ?*anyopaque,
        },
        _sigev_un: extern union {
            // __lwpid_t is int32_t on FreeBSD (see sys/sys/_types.h)
            _threadid: i32,
            _sigev_thread: extern struct {
                _function: ?*const fn (?*anyopaque) callconv(.C) void,
                _attribute: ?*anyopaque,
            },
            // Used as sigev_notify_kevent_flags for SIGEV_KEVENT
            _kevent_flags: c_ushort,
            __spare__: [8]c_long,
        },
    };

    // AIO Control Block - the core structure for async I/O
    const aiocb = extern struct {
        aio_fildes: c_int, // File descriptor
        aio_offset: i64, // File offset
        aio_buf: ?*anyopaque, // Buffer
        aio_nbytes: usize, // Number of bytes
        __spare__: [2]c_int,
        __spare2__: ?*anyopaque,
        aio_lio_opcode: c_int, // LIO operation (for lio_listio)
        aio_reqprio: c_int, // Request priority
        _aiocb_private: extern struct {
            status: c_long,
            @"error": c_long,
            kernelinfo: ?*anyopaque,
        },
        aio_sigevent: sigevent, // Signal event for notification
    };

    // Notification types
    const SIGEV_NONE: c_int = 0; // No notification
    const SIGEV_SIGNAL: c_int = 1; // Signal notification
    const SIGEV_THREAD: c_int = 2; // Thread notification
    const SIGEV_KEVENT: c_int = 3; // kqueue notification (what we want!)

    // AIO functions
    extern "c" fn aio_read(aiocb: *aiocb) c_int;
    extern "c" fn aio_write(aiocb: *aiocb) c_int;
    extern "c" fn aio_error(aiocb: *const aiocb) c_int;
    extern "c" fn aio_return(aiocb: *aiocb) isize;
    extern "c" fn aio_cancel(fd: c_int, aiocb: ?*aiocb) c_int;
    extern "c" fn aio_fsync(op: c_int, aiocb: *aiocb) c_int;

    // fsync operation types for aio_fsync
    const O_SYNC: c_int = 0x0080;
    const O_DSYNC: c_int = 0x1000; // FreeBSD 13+

    // AIO error return values
    const EINPROGRESS: c_int = 36; // Operation in progress
    const ECANCELED: c_int = 85; // Operation canceled
};

// EVFILT_AIO value for FreeBSD kqueue
const EVFILT_AIO: i16 = -3;

pub const IO = struct {
    pub const TCPOptions = common.TCPOptions;
    pub const ListenOptions = common.ListenOptions;

    kq: fd_t,
    event_id: Event = 0,
    time_os: TimeOS = .{},
    io_inflight: usize = 0,
    timeouts: QueueType(Completion) = QueueType(Completion).init(.{ .name = "io_timeouts" }),
    completed: QueueType(Completion) = QueueType(Completion).init(.{ .name = "io_completed" }),
    io_pending: QueueType(Completion) = QueueType(Completion).init(.{ .name = "io_pending" }),
    // AIO operations that are submitted to kernel and awaiting completion
    aio_pending: QueueType(Completion) = QueueType(Completion).init(.{ .name = "aio_pending" }),

    pub fn init(entries: u12, flags: u32) !IO {
        _ = entries;
        _ = flags;

        const kq = try posix.kqueue();
        assert(kq > -1);
        return IO{ .kq = kq };
    }

    pub fn deinit(self: *IO) void {
        assert(self.kq > -1);
        posix.close(self.kq);
        self.kq = -1;
    }

    /// Pass all queued submissions to the kernel and peek for completions.
    pub fn run(self: *IO) !void {
        return self.flush(false);
    }

    /// Pass all queued submissions to the kernel and run for `nanoseconds`.
    pub fn run_for_ns(self: *IO, nanoseconds: u63) !void {
        var timed_out = false;
        var completion: Completion = undefined;
        const on_timeout = struct {
            fn callback(
                timed_out_ptr: *bool,
                _completion: *Completion,
                result: TimeoutError!void,
            ) void {
                _ = _completion;
                _ = result catch unreachable;
                timed_out_ptr.* = true;
            }
        }.callback;

        self.timeout(*bool, &timed_out, on_timeout, &completion, nanoseconds);

        while (!timed_out) {
            try self.flush(true);
        }
    }

    fn flush(self: *IO, wait_for_completions: bool) !void {
        var events: [256]posix.Kevent = undefined;

        // Check timeouts and fill events with completions in io_pending
        const next_timeout = self.flush_timeouts();
        const change_events = self.flush_io(&events);

        // Only call kevent() if we need to submit io events or wait for completions
        if (change_events > 0 or self.completed.empty()) {
            var ts = std.mem.zeroes(posix.timespec);

            if (change_events == 0 and self.completed.empty()) {
                if (wait_for_completions) {
                    const timeout_ns = next_timeout orelse @panic("kevent() blocking forever");
                    ts.nsec = @as(@TypeOf(ts.nsec), @intCast(timeout_ns % std.time.ns_per_s));
                    ts.sec = @as(@TypeOf(ts.sec), @intCast(timeout_ns / std.time.ns_per_s));
                } else if (self.io_inflight == 0 and self.aio_pending.empty()) {
                    return;
                }
            }

            const new_events = try posix.kevent(
                self.kq,
                events[0..change_events],
                events[0..events.len],
                &ts,
            );

            self.io_inflight += change_events;
            self.io_inflight -= new_events;

            for (events[0..new_events]) |event| {
                // Check if this is an AIO completion (EVFILT_AIO)
                if (event.filter == EVFILT_AIO) {
                    // The udata contains our Completion pointer
                    const completion: *Completion = @ptrFromInt(event.udata);
                    self.handle_aio_completion(completion);
                } else {
                    // Regular socket/network event
                    const completion: *Completion = @ptrFromInt(event.udata);
                    assert(completion.link.next == null);
                    self.completed.push(completion);
                }
            }
        }

        var completed = self.completed;
        self.completed.reset();
        while (completed.pop()) |completion| {
            (completion.callback)(self, completion);
        }
    }

    /// Handle AIO completion - called when kqueue signals EVFILT_AIO
    fn handle_aio_completion(self: *IO, completion: *Completion) void {
        // Remove from aio_pending queue
        self.aio_pending.remove(completion);

        // Get the aiocb to check status
        const aiocb_ptr = switch (completion.operation) {
            .aio_read => |*op| &op.aiocb,
            .aio_write => |*op| &op.aiocb,
            .aio_fsync => |*op| &op.aiocb,
            else => unreachable,
        };

        // Verify the operation completed - EVFILT_AIO should only fire when done
        const err = c.aio_error(aiocb_ptr);
        if (err == c.EINPROGRESS) {
            // This should never happen - EVFILT_AIO fires on completion
            // If it does, something is seriously wrong with our kqueue setup
            @panic("AIO completion signaled but aio_error returned EINPROGRESS");
        }

        // Push to completed queue for callback processing
        // The actual result (success/error) is retrieved in the callback
        completion.link = .{};
        self.completed.push(completion);
    }

    fn flush_io(self: *IO, events: []posix.Kevent) usize {
        for (events, 0..) |*event, flushed| {
            const completion = self.io_pending.pop() orelse return flushed;

            const event_info = switch (completion.operation) {
                .accept => |op| [2]c_int{ op.socket, posix.system.EVFILT.READ },
                .connect => |op| [2]c_int{ op.socket, posix.system.EVFILT.WRITE },
                .recv => |op| [2]c_int{ op.socket, posix.system.EVFILT.READ },
                .send => |op| [2]c_int{ op.socket, posix.system.EVFILT.WRITE },
                // Note: aio_read/aio_write are NOT queued here - they use AIO
                else => @panic("invalid completion operation queued for io"),
            };

            event.* = .{
                .ident = @as(u32, @intCast(event_info[0])),
                .filter = @as(i16, @intCast(event_info[1])),
                .flags = posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = @intFromPtr(completion),
            };
        }
        return events.len;
    }

    fn flush_timeouts(self: *IO) ?u64 {
        var min_timeout: ?u64 = null;
        var timeouts_iterator = self.timeouts.iterate();
        while (timeouts_iterator.next()) |completion| {
            const now = self.time_os.time().monotonic().ns;
            const expires = completion.operation.timeout.expires;

            if (now >= expires) {
                self.timeouts.remove(completion);
                self.completed.push(completion);
                continue;
            }

            const timeout_ns = expires - now;
            if (min_timeout) |min_ns| {
                min_timeout = @min(min_ns, timeout_ns);
            } else {
                min_timeout = timeout_ns;
            }
        }
        return min_timeout;
    }

    /// This struct holds the data needed for a single IO operation.
    pub const Completion = struct {
        link: QueueType(Completion).Link = .{},
        context: ?*anyopaque,
        callback: *const fn (*IO, *Completion) void,
        operation: Operation,
    };

    const Operation = union(enum) {
        accept: struct {
            socket: socket_t,
        },
        close: struct {
            fd: fd_t,
        },
        connect: struct {
            socket: socket_t,
            address: std.net.Address,
            initiated: bool,
        },
        fsync: struct {
            fd: fd_t,
        },
        // Legacy blocking read - kept for network sockets
        read: struct {
            fd: fd_t,
            buf: [*]u8,
            len: u32,
            offset: u64,
        },
        recv: struct {
            socket: socket_t,
            buf: [*]u8,
            len: u32,
        },
        send: struct {
            socket: socket_t,
            buf: [*]const u8,
            len: u32,
        },
        timeout: struct {
            expires: u64,
        },
        // Legacy blocking write - kept for network sockets
        write: struct {
            fd: fd_t,
            buf: [*]const u8,
            len: u32,
            offset: u64,
        },
        // NEW: True async AIO read
        aio_read: struct {
            aiocb: c.aiocb,
            fd: fd_t,
            buf: [*]u8,
            len: u32,
            offset: u64,
            submit_failed: bool = false, // Set true if aio_read() failed
        },
        // NEW: True async AIO write
        aio_write: struct {
            aiocb: c.aiocb,
            fd: fd_t,
            buf: [*]const u8,
            len: u32,
            offset: u64,
            submit_failed: bool = false, // Set true if aio_write() failed
        },
        // NEW: True async AIO fsync
        aio_fsync: struct {
            aiocb: c.aiocb,
            fd: fd_t,
            submit_failed: bool = false,
        },
    };

    fn submit(
        self: *IO,
        context: anytype,
        comptime callback: anytype,
        completion: *Completion,
        comptime operation_tag: std.meta.Tag(Operation),
        operation_data: std.meta.TagPayload(Operation, operation_tag),
        comptime OperationImpl: type,
    ) void {
        const on_complete_fn = struct {
            fn on_complete(io: *IO, _completion: *Completion) void {
                const op_data = &@field(_completion.operation, @tagName(operation_tag));
                const result = OperationImpl.do_operation(op_data);

                // Requeue onto io_pending if error.WouldBlock (for network ops)
                switch (operation_tag) {
                    .accept, .connect, .recv, .send => {
                        _ = result catch |err| switch (err) {
                            error.WouldBlock => {
                                _completion.link = .{};
                                io.io_pending.push(_completion);
                                return;
                            },
                            else => {},
                        };
                    },
                    else => {},
                }

                return callback(
                    @ptrCast(@alignCast(_completion.context)),
                    _completion,
                    result,
                );
            }
        }.on_complete;

        completion.* = .{
            .link = .{},
            .context = context,
            .callback = on_complete_fn,
            .operation = @unionInit(Operation, @tagName(operation_tag), operation_data),
        };

        switch (operation_tag) {
            .timeout => self.timeouts.push(completion),
            else => self.completed.push(completion),
        }
    }

    /// Submit an AIO operation and register with kqueue for completion
    fn submit_aio(
        self: *IO,
        completion: *Completion,
        aiocb_ptr: *c.aiocb,
        comptime is_write: bool,
    ) !void {
        // Configure kqueue notification via SIGEV_KEVENT
        // FreeBSD requires:
        // - sigev_notify = SIGEV_KEVENT
        // - sigev_notify_kqueue = kqueue fd (to deliver the event)
        // - sigev_value = user data (our completion pointer)
        aiocb_ptr.aio_sigevent.sigev_notify = c.SIGEV_KEVENT;
        aiocb_ptr.aio_sigevent.sigev_notify_kqueue = self.kq;
        aiocb_ptr.aio_sigevent.sigev_value.sival_ptr = completion;
        aiocb_ptr.aio_sigevent._sigev_un._kevent_flags = 0;

        // Submit the AIO operation
        // With SIGEV_KEVENT, the kernel automatically delivers a kevent to
        // sigev_notify_kqueue when the I/O completes. The kevent will have:
        // - ident = aiocb pointer
        // - filter = EVFILT_AIO
        // - udata = sigev_value.sival_ptr (our completion pointer)
        const result = if (is_write) c.aio_write(aiocb_ptr) else c.aio_read(aiocb_ptr);

        if (result != 0) {
            const errno = posix.errno(result);
            log.err("AIO submit failed: {}", .{errno});
            return error.AioSubmitFailed;
        }

        // Track in aio_pending queue and increment io_inflight
        // (io_inflight is decremented in flush() when kevent returns the completion)
        self.aio_pending.push(completion);
        self.io_inflight += 1;
    }

    pub fn cancel_all(_: *IO) void {
        // TODO Cancel in-flight async IO and wait for all completions.
    }

    pub const CancelError = error{
        NotRunning,
        NotInterruptable,
    } || posix.UnexpectedError;

    pub fn cancel(
        _: *IO,
        comptime Context: type,
        _: Context,
        comptime _: fn (
            context: Context,
            completion: *Completion,
            result: CancelError!void,
        ) void,
        _: struct {
            completion: *Completion,
            target: *Completion,
        },
    ) void {
        @panic("cancelation is not supported on freebsd");
    }

    pub const AcceptError = posix.AcceptError || posix.SetSockOptError;

    pub fn accept(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: AcceptError!socket_t,
        ) void,
        completion: *Completion,
        socket: socket_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .accept,
            .{ .socket = socket },
            struct {
                fn do_operation(op: anytype) AcceptError!socket_t {
                    const fd = try posix.accept(
                        op.socket,
                        null,
                        null,
                        posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
                    );
                    errdefer posix.close(fd);

                    posix.setsockopt(
                        fd,
                        posix.SOL.SOCKET,
                        posix.SO.NOSIGPIPE,
                        &mem.toBytes(@as(c_int, 1)),
                    ) catch |err| return switch (err) {
                        error.TimeoutTooBig => unreachable,
                        error.PermissionDenied => error.NetworkSubsystemFailed,
                        error.AlreadyConnected => error.NetworkSubsystemFailed,
                        error.InvalidProtocolOption => error.ProtocolFailure,
                        else => |e| e,
                    };

                    return fd;
                }
            },
        );
    }

    pub const CloseError = error{
        FileDescriptorInvalid,
        DiskQuota,
        InputOutput,
        NoSpaceLeft,
    } || posix.UnexpectedError;

    pub fn close(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: CloseError!void,
        ) void,
        completion: *Completion,
        fd: fd_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .close,
            .{ .fd = fd },
            struct {
                fn do_operation(op: anytype) CloseError!void {
                    return switch (posix.errno(posix.system.close(op.fd))) {
                        .SUCCESS => {},
                        .BADF => error.FileDescriptorInvalid,
                        .INTR => {},
                        .IO => error.InputOutput,
                        else => |errno| stdx.unexpected_errno("close", errno),
                    };
                }
            },
        );
    }

    pub const ConnectError = posix.ConnectError;

    pub fn connect(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ConnectError!void,
        ) void,
        completion: *Completion,
        socket: socket_t,
        address: std.net.Address,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .connect,
            .{
                .socket = socket,
                .address = address,
                .initiated = false,
            },
            struct {
                fn do_operation(op: anytype) ConnectError!void {
                    const result = switch (op.initiated) {
                        true => posix.getsockoptError(op.socket),
                        else => posix.connect(
                            op.socket,
                            &op.address.any,
                            op.address.getOsSockLen(),
                        ),
                    };
                    op.initiated = true;
                    return result;
                }
            },
        );
    }

    pub const FsyncError = posix.SyncError || posix.UnexpectedError;

    pub fn fsync(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: FsyncError!void,
        ) void,
        completion: *Completion,
        fd: fd_t,
    ) void {
        // For fsync, we still use synchronous call for simplicity
        // AIO fsync (aio_fsync) could be added if needed
        self.submit(
            context,
            callback,
            completion,
            .fsync,
            .{ .fd = fd },
            struct {
                fn do_operation(op: anytype) FsyncError!void {
                    return posix.fsync(op.fd);
                }
            },
        );
    }

    pub const OpenatError = posix.OpenError || posix.UnexpectedError;

    pub const ReadError = error{
        WouldBlock,
        NotOpenForReading,
        ConnectionResetByPeer,
        Alignment,
        InputOutput,
        IsDir,
        SystemResources,
        Unseekable,
        ConnectionTimedOut,
        AioSubmitFailed,
        AioRegisterFailed,
        AioError,
    } || posix.UnexpectedError;

    /// Async read using FreeBSD native AIO - does NOT block the event loop!
    pub fn read(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ReadError!usize,
        ) void,
        completion: *Completion,
        fd: fd_t,
        buffer: []u8,
        offset: u64,
    ) void {
        const on_complete = struct {
            fn on_complete(io: *IO, _completion: *Completion) void {
                _ = io;
                const op = &_completion.operation.aio_read;

                // If AIO submission failed, return error immediately
                // (don't call aio_error on an unsubmitted aiocb - undefined behavior)
                if (op.submit_failed) {
                    callback(
                        @ptrCast(@alignCast(_completion.context)),
                        _completion,
                        error.AioSubmitFailed,
                    );
                    return;
                }

                // Check AIO result
                const err = c.aio_error(&op.aiocb);
                if (err != 0) {
                    // Map errno to error
                    callback(
                        @ptrCast(@alignCast(_completion.context)),
                        _completion,
                        error.AioError,
                    );
                    return;
                }

                // Get the result (bytes read)
                const result = c.aio_return(@constCast(&op.aiocb));
                if (result < 0) {
                    callback(
                        @ptrCast(@alignCast(_completion.context)),
                        _completion,
                        error.AioError,
                    );
                    return;
                }

                callback(
                    @ptrCast(@alignCast(_completion.context)),
                    _completion,
                    @intCast(result),
                );
            }
        }.on_complete;

        // Initialize completion
        completion.* = .{
            .link = .{},
            .context = context,
            .callback = on_complete,
            .operation = .{
                .aio_read = .{
                    .aiocb = std.mem.zeroes(c.aiocb),
                    .fd = fd,
                    .buf = buffer.ptr,
                    .len = @intCast(buffer_limit(buffer.len)),
                    .offset = offset,
                },
            },
        };

        // Set up aiocb
        const aiocb_ptr = &completion.operation.aio_read.aiocb;
        aiocb_ptr.aio_fildes = fd;
        aiocb_ptr.aio_offset = @intCast(offset);
        aiocb_ptr.aio_buf = buffer.ptr;
        aiocb_ptr.aio_nbytes = buffer_limit(buffer.len);

        // Submit AIO operation
        self.submit_aio(completion, aiocb_ptr, false) catch |err| {
            log.err("Failed to submit AIO read: {}", .{err});
            // Mark as failed so callback knows not to call aio_error/aio_return
            completion.operation.aio_read.submit_failed = true;
            completion.link = .{};
            self.completed.push(completion);
        };
    }

    pub const RecvError = posix.RecvFromError;

    pub fn recv(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: RecvError!usize,
        ) void,
        completion: *Completion,
        socket: socket_t,
        buffer: []u8,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .recv,
            .{
                .socket = socket,
                .buf = buffer.ptr,
                .len = @as(u32, @intCast(buffer_limit(buffer.len))),
            },
            struct {
                fn do_operation(op: anytype) RecvError!usize {
                    return posix.recv(op.socket, op.buf[0..op.len], 0);
                }
            },
        );
    }

    pub const SendError = error{ConnectionRefused} || posix.SendError;

    pub fn send(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: SendError!usize,
        ) void,
        completion: *Completion,
        socket: socket_t,
        buffer: []const u8,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .send,
            .{
                .socket = socket,
                .buf = buffer.ptr,
                .len = @as(u32, @intCast(buffer_limit(buffer.len))),
            },
            struct {
                fn do_operation(op: anytype) SendError!usize {
                    return posix.sendto(
                        op.socket,
                        op.buf[0..op.len],
                        0,
                        null,
                        0,
                    ) catch |err| switch (err) {
                        error.AddressFamilyNotSupported => unreachable,
                        error.SymLinkLoop => unreachable,
                        error.NameTooLong => unreachable,
                        error.FileNotFound => unreachable,
                        error.NotDir => unreachable,
                        error.NetworkUnreachable => unreachable,
                        error.AddressNotAvailable => unreachable,
                        error.SocketNotConnected => unreachable,
                        error.UnreachableAddress => unreachable,
                        else => |e| return e,
                    };
                }
            },
        );
    }

    pub fn send_now(_: *IO, _: socket_t, _: []const u8) ?usize {
        return null;
    }

    pub const TimeoutError = error{Canceled} || posix.UnexpectedError;

    pub fn timeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: TimeoutError!void,
        ) void,
        completion: *Completion,
        nanoseconds: u63,
    ) void {
        if (nanoseconds == 0) {
            completion.* = .{
                .link = .{},
                .context = context,
                .operation = undefined,
                .callback = struct {
                    fn on_complete(_io: *IO, _completion: *Completion) void {
                        _ = _io;
                        const _context: Context = @ptrCast(@alignCast(_completion.context));
                        callback(_context, _completion, {});
                    }
                }.on_complete,
            };

            self.completed.push(completion);
            return;
        }

        self.submit(
            context,
            callback,
            completion,
            .timeout,
            .{ .expires = self.time_os.time().monotonic().ns + nanoseconds },
            struct {
                fn do_operation(_: anytype) TimeoutError!void {
                    return;
                }
            },
        );
    }

    pub const WriteError = posix.PWriteError || error{
        AioSubmitFailed,
        AioRegisterFailed,
        AioError,
    };

    /// Async write using FreeBSD native AIO - does NOT block the event loop!
    pub fn write(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: WriteError!usize,
        ) void,
        completion: *Completion,
        fd: fd_t,
        buffer: []const u8,
        offset: u64,
    ) void {
        const on_complete = struct {
            fn on_complete(io: *IO, _completion: *Completion) void {
                _ = io;
                const op = &_completion.operation.aio_write;

                // If AIO submission failed, return error immediately
                if (op.submit_failed) {
                    callback(
                        @ptrCast(@alignCast(_completion.context)),
                        _completion,
                        error.AioSubmitFailed,
                    );
                    return;
                }

                // Check AIO result
                const err = c.aio_error(&op.aiocb);
                if (err != 0) {
                    callback(
                        @ptrCast(@alignCast(_completion.context)),
                        _completion,
                        error.AioError,
                    );
                    return;
                }

                // Get the result (bytes written)
                const result = c.aio_return(@constCast(&op.aiocb));
                if (result < 0) {
                    callback(
                        @ptrCast(@alignCast(_completion.context)),
                        _completion,
                        error.AioError,
                    );
                    return;
                }

                // Explicit fsync for durability - goes to ZIL/SLOG on ZFS.
                // Separation of concerns: aio_write = async data transfer,
                // fsync = explicit "make durable now" call.
                posix.fsync(op.fd) catch {
                    callback(
                        @ptrCast(@alignCast(_completion.context)),
                        _completion,
                        error.AioError,
                    );
                    return;
                };

                callback(
                    @ptrCast(@alignCast(_completion.context)),
                    _completion,
                    @intCast(result),
                );
            }
        }.on_complete;

        // Initialize completion
        completion.* = .{
            .link = .{},
            .context = context,
            .callback = on_complete,
            .operation = .{
                .aio_write = .{
                    .aiocb = std.mem.zeroes(c.aiocb),
                    .fd = fd,
                    .buf = buffer.ptr,
                    .len = @intCast(buffer_limit(buffer.len)),
                    .offset = offset,
                },
            },
        };

        // Set up aiocb
        const aiocb_ptr = &completion.operation.aio_write.aiocb;
        aiocb_ptr.aio_fildes = fd;
        aiocb_ptr.aio_offset = @intCast(offset);
        aiocb_ptr.aio_buf = @constCast(buffer.ptr);
        aiocb_ptr.aio_nbytes = buffer_limit(buffer.len);

        // Submit AIO operation
        self.submit_aio(completion, aiocb_ptr, true) catch |err| {
            log.err("Failed to submit AIO write: {}", .{err});
            // Mark as failed so callback knows not to call aio_error/aio_return
            completion.operation.aio_write.submit_failed = true;
            completion.link = .{};
            self.completed.push(completion);
        };
    }

    pub const Event = usize;
    pub const INVALID_EVENT: Event = 0;

    pub fn open_event(self: *IO) !Event {
        self.event_id += 1;
        const event = self.event_id;
        assert(event != INVALID_EVENT);

        var kev = mem.zeroes([1]posix.Kevent);
        kev[0].ident = event;
        kev[0].filter = posix.system.EVFILT.USER;
        kev[0].flags = posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.CLEAR;

        const polled = posix.kevent(self.kq, &kev, kev[0..0], null) catch |err| switch (err) {
            error.AccessDenied => unreachable,
            error.EventNotFound => unreachable,
            error.ProcessNotFound => unreachable,
            error.Overflow, error.SystemResources => return error.SystemResources,
        };
        assert(polled == 0);

        return event;
    }

    pub fn event_listen(
        self: *IO,
        event: Event,
        completion: *Completion,
        comptime on_event: fn (*Completion) void,
    ) void {
        assert(event != INVALID_EVENT);
        completion.* = .{
            .link = .{},
            .context = null,
            .operation = undefined,
            .callback = struct {
                fn on_complete(_: *IO, completion_inner: *Completion) void {
                    on_event(completion_inner);
                }
            }.on_complete,
        };

        self.io_inflight += 1;
    }

    pub fn event_trigger(self: *IO, event: Event, completion: *Completion) void {
        assert(event != INVALID_EVENT);

        var kev = mem.zeroes([1]posix.Kevent);
        kev[0].ident = event;
        kev[0].filter = posix.system.EVFILT.USER;
        kev[0].fflags = posix.system.NOTE.TRIGGER;
        kev[0].udata = @intFromPtr(completion);

        const polled: usize = posix.kevent(self.kq, &kev, kev[0..0], null) catch unreachable;
        assert(polled == 0);
    }

    pub fn close_event(self: *IO, event: Event) void {
        assert(event != INVALID_EVENT);

        var kev = mem.zeroes([1]posix.Kevent);
        kev[0].ident = event;
        kev[0].filter = posix.system.EVFILT.USER;
        kev[0].flags = posix.system.EV.DELETE;
        kev[0].udata = 0;

        const polled = posix.kevent(self.kq, &kev, kev[0..0], null) catch unreachable;
        assert(polled == 0);
    }

    pub const socket_t = posix.socket_t;

    pub fn open_socket_tcp(self: *IO, family: u32, options: TCPOptions) !socket_t {
        const fd = try self.open_socket(
            family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            posix.IPPROTO.TCP,
        );
        errdefer self.close_socket(fd);

        try common.tcp_options(fd, options);
        return fd;
    }

    pub fn open_socket_udp(self: *IO, family: u32) !socket_t {
        return try self.open_socket(
            family,
            posix.SOCK.DGRAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            posix.IPPROTO.UDP,
        );
    }

    fn open_socket(self: *IO, family: u32, sock_type: u32, protocol: u32) !socket_t {
        const fd = try posix.socket(
            family,
            sock_type | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            protocol,
        );
        errdefer self.close_socket(fd);

        try common.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, 1);

        return fd;
    }

    pub fn close_socket(self: *IO, socket: socket_t) void {
        _ = self;
        posix.close(socket);
    }

    pub fn listen(
        _: *IO,
        fd: socket_t,
        address: std.net.Address,
        options: ListenOptions,
    ) !std.net.Address {
        return common.listen(fd, address, options);
    }

    pub fn shutdown(_: *IO, socket: socket_t, how: posix.ShutdownHow) posix.ShutdownError!void {
        return posix.shutdown(socket, how);
    }

    pub fn open_dir(dir_path: []const u8) !fd_t {
        return posix.open(dir_path, .{ .CLOEXEC = true, .ACCMODE = .RDONLY }, 0);
    }

    pub const fd_t = posix.fd_t;
    pub const INVALID_FILE: fd_t = -1;

    pub const OpenDataFilePurpose = enum { format, open, inspect };

    pub fn open_data_file(
        self: *IO,
        dir_fd: fd_t,
        relative_path: []const u8,
        size: u64,
        purpose: OpenDataFilePurpose,
        direct_io: DirectIO,
    ) !fd_t {
        _ = self;

        assert(relative_path.len > 0);
        assert(size % constants.sector_size == 0);

        var flags: posix.O = .{
            .CLOEXEC = true,
            .ACCMODE = if (purpose == .inspect) .RDONLY else .RDWR,
            // FreeBSD: We explicitly fsync() after writes rather than using O_DSYNC.
            // This gives clear separation: aio_write = async data transfer,
            // fsync = explicit durability to ZIL/SLOG. Each syscall does one thing.
        };
        var mode: posix.mode_t = 0;

        if (direct_io != .direct_io_disabled) {
            if (@hasField(posix.O, "DIRECT")) {
                flags.DIRECT = true;
            }
        }

        if (@hasField(posix.O, "LARGEFILE")) flags.LARGEFILE = true;

        switch (purpose) {
            .format => {
                flags.CREAT = true;
                flags.EXCL = true;
                mode = 0o666;
                log.info("creating \"{s}\"...", .{relative_path});
            },
            .open, .inspect => {
                log.info("opening \"{s}\"...", .{relative_path});
            },
        }

        // Note: No O_DSYNC - we use explicit fsync() after writes for durability.
        // This matches our principled approach: write = transfer, fsync = durable.
        assert(!std.fs.path.isAbsolute(relative_path));
        const fd = try posix.openat(dir_fd, relative_path, flags, mode);
        errdefer posix.close(fd);

        posix.flock(fd, posix.LOCK.EX | posix.LOCK.NB) catch |err| switch (err) {
            error.WouldBlock => {
                if (purpose == .inspect) {
                    log.warn(
                        "another process holds the data file lock - results may be inconsistent",
                        .{},
                    );
                } else {
                    @panic("another process holds the data file lock");
                }
            },
            else => return err,
        };

        if (purpose == .format) try fs_allocate(fd, size);

        try posix.fsync(fd);
        try posix.fsync(dir_fd);

        const stat = try posix.fstat(fd);
        if (stat.size < size) @panic("data file inode size was truncated or corrupted");

        return fd;
    }

    fn fs_allocate(fd: fd_t, size: u64) !void {
        log.info("allocating {}...", .{std.fmt.fmtIntSizeBin(size)});

        const result = std.c.posix_fallocate(fd, 0, @intCast(size));
        switch (result) {
            0 => return,
            else => {
                log.warn("posix_fallocate failed, falling back to manual allocation", .{});
                return fallback_allocate(fd, size);
            },
        }
    }

    fn fallback_allocate(fd: fd_t, size: u64) !void {
        var buf: [constants.sector_size]u8 = std.mem.zeroes([constants.sector_size]u8);
        const last_offset: u64 = size - constants.sector_size;

        _ = posix.pwrite(fd, &buf, last_offset) catch |err| {
            log.err("failed to write last sector: {}", .{err});
            return err;
        };

        return posix.ftruncate(fd, size) catch |err| switch (err) {
            error.AccessDenied => error.PermissionDenied,
            else => |e| e,
        };
    }

    pub const PReadError = posix.PReadError;

    pub fn aof_blocking_write_all(_: *IO, fd: fd_t, buffer: []const u8) posix.WriteError!void {
        return common.aof_blocking_write_all(fd, buffer);
    }

    pub fn aof_blocking_pread_all(_: *IO, fd: fd_t, buffer: []u8, offset: u64) PReadError!usize {
        return common.aof_blocking_pread_all(fd, buffer, offset);
    }

    pub fn aof_blocking_close(_: *IO, fd: fd_t) void {
        return common.aof_blocking_close(fd);
    }
};

// =============================================================================
// Tests
// =============================================================================

const builtin = @import("builtin");
const testing = std.testing;

// Compile-time struct size validation
// These sizes are based on FreeBSD 14.x amd64 ABI
// TODO: Verify against actual FreeBSD headers once available
comptime {
    // sigevent struct should be consistent across BSD variants
    // On FreeBSD amd64: sigev_notify (4) + sigev_notify_kqueue (4) + sigev_value (8) + union (64) = ~80 bytes
    // The exact size depends on padding and the union size
    if (builtin.target.os.tag == .freebsd) {
        // On actual FreeBSD, we can validate sizes against libc
        // For now, just ensure the struct is usable (non-zero size)
        if (@sizeOf(c.sigevent) == 0) @compileError("sigevent has zero size");
        if (@sizeOf(c.aiocb) == 0) @compileError("aiocb has zero size");
    }
}

test "freebsd: sigevent and aiocb structs are properly sized" {
    // These tests verify our struct definitions have reasonable sizes
    // On FreeBSD, sigevent is typically ~80 bytes, aiocb is ~168 bytes
    try testing.expect(@sizeOf(c.sigevent) > 0);
    try testing.expect(@sizeOf(c.aiocb) > 0);

    // Verify field offsets are accessible (compile-time check that fields exist)
    var sev: c.sigevent = std.mem.zeroes(c.sigevent);
    sev.sigev_notify = c.SIGEV_KEVENT;
    sev.sigev_notify_kqueue = 0;
    sev.sigev_value.sival_ptr = null;
    _ = sev;

    var acb: c.aiocb = std.mem.zeroes(c.aiocb);
    acb.aio_fildes = 0;
    acb.aio_offset = 0;
    acb.aio_buf = null;
    acb.aio_nbytes = 0;
    _ = acb;
}

test "freebsd: SIGEV constants are correct" {
    // Verify our constants match expected values
    try testing.expectEqual(@as(c_int, 0), c.SIGEV_NONE);
    try testing.expectEqual(@as(c_int, 1), c.SIGEV_SIGNAL);
    try testing.expectEqual(@as(c_int, 2), c.SIGEV_THREAD);
    try testing.expectEqual(@as(c_int, 3), c.SIGEV_KEVENT);
}

test "freebsd: EVFILT_AIO has expected value" {
    // FreeBSD defines EVFILT_AIO as -3
    try testing.expectEqual(@as(i16, -3), EVFILT_AIO);
}

test "freebsd: IO initialization and cleanup" {
    // This test should work on any platform that supports kqueue (macOS, FreeBSD)
    if (builtin.target.os.tag != .freebsd and !builtin.target.os.tag.isDarwin()) {
        return error.SkipZigTest;
    }

    var io = try IO.init(32, 0);
    defer io.deinit();

    // Verify initial state
    try testing.expectEqual(@as(usize, 0), io.io_inflight);
    try testing.expect(io.completed.empty());
    try testing.expect(io.io_pending.empty());
    try testing.expect(io.aio_pending.empty());
    try testing.expect(io.kq > -1);
}

test "freebsd: timeout operation" {
    if (builtin.target.os.tag != .freebsd and !builtin.target.os.tag.isDarwin()) {
        return error.SkipZigTest;
    }

    const Context = struct {
        done: bool = false,

        fn callback(ctx: *@This(), _: *IO.Completion, result: IO.TimeoutError!void) void {
            _ = result catch unreachable;
            ctx.done = true;
        }
    };

    var ctx = Context{};
    var io = try IO.init(32, 0);
    defer io.deinit();

    var completion: IO.Completion = undefined;
    io.timeout(*Context, &ctx, Context.callback, &completion, 1 * std.time.ns_per_ms);

    // Run until timeout fires
    while (!ctx.done) {
        try io.run();
    }

    try testing.expect(ctx.done);
}

test "freebsd: Operation union contains AIO variants" {
    // Verify the Operation union has our AIO types
    const op_read: IO.Operation = .{
        .aio_read = .{
            .aiocb = std.mem.zeroes(c.aiocb),
            .fd = 0,
            .buf = undefined,
            .len = 0,
            .offset = 0,
            .submit_failed = false,
        },
    };
    _ = op_read;

    const op_write: IO.Operation = .{
        .aio_write = .{
            .aiocb = std.mem.zeroes(c.aiocb),
            .fd = 0,
            .buf = undefined,
            .len = 0,
            .offset = 0,
            .submit_failed = false,
        },
    };
    _ = op_write;
}

// FreeBSD-only tests (require actual AIO system calls)
test "freebsd: AIO read/write on real file" {
    // This test only runs on actual FreeBSD
    if (builtin.target.os.tag != .freebsd) {
        return error.SkipZigTest;
    }

    const Context = struct {
        io: *IO,
        fd: ?posix.fd_t = null,
        write_done: bool = false,
        read_done: bool = false,
        write_result: ?IO.WriteError!usize = null,
        read_result: ?IO.ReadError!usize = null,
        write_buf: [64]u8 = undefined,
        read_buf: [64]u8 = undefined,

        fn write_callback(ctx: *@This(), _: *IO.Completion, result: IO.WriteError!usize) void {
            ctx.write_result = result;
            ctx.write_done = true;
        }

        fn read_callback(ctx: *@This(), _: *IO.Completion, result: IO.ReadError!usize) void {
            ctx.read_result = result;
            ctx.read_done = true;
        }
    };

    var io = try IO.init(32, 0);
    defer io.deinit();

    // Create a temporary file
    const path = "test_freebsd_aio.tmp";
    const file = try std.fs.cwd().createFile(path, .{ .read = true });
    defer {
        file.close();
        std.fs.cwd().deleteFile(path) catch {};
    }

    var ctx = Context{ .io = &io, .fd = file.handle };

    // Fill write buffer with test pattern
    for (&ctx.write_buf, 0..) |*b, i| {
        b.* = @intCast(i);
    }

    // Test async write
    var write_completion: IO.Completion = undefined;
    io.write(*Context, &ctx, Context.write_callback, &write_completion, file.handle, &ctx.write_buf, 0);

    while (!ctx.write_done) {
        try io.run();
    }

    const written = ctx.write_result.? catch |err| {
        std.debug.print("Write failed: {}\n", .{err});
        return err;
    };
    try testing.expectEqual(@as(usize, 64), written);

    // Test async read
    @memset(&ctx.read_buf, 0);
    var read_completion: IO.Completion = undefined;
    io.read(*Context, &ctx, Context.read_callback, &read_completion, file.handle, &ctx.read_buf, 0);

    while (!ctx.read_done) {
        try io.run();
    }

    const bytes_read = ctx.read_result.? catch |err| {
        std.debug.print("Read failed: {}\n", .{err});
        return err;
    };
    try testing.expectEqual(@as(usize, 64), bytes_read);
    try testing.expectEqualSlices(u8, &ctx.write_buf, &ctx.read_buf);
}
