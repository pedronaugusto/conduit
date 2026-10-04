//! Bounded, ordered input for a child on a pipe.
//!
//! `Child.inputWriter` takes the child's stdin pipe and starts its one writing
//! task. `queue` copies bytes and never waits for the child to read; `end`
//! closes the pipe after those bytes, and `wait` reports delivery or the first
//! failure. Delivery means written to the pipe, not consumed by the child.
//!
//! The writer owns its pipe independently of the Child. It may move before
//! being shared, but must not be copied. `queue`, `end` and `wait` may run on
//! several tasks; `cancel` has one caller at a time. Stop all callers before
//! `deinit`, which cancels and joins the writing task before freeing anything.
//! The allocator and Io used to create it must outlive it. Its own allocator
//! calls are serialized; a shared allocator must support its other users.

pub const InputWriter = @import("Child/Child.zig").InputWriter;
