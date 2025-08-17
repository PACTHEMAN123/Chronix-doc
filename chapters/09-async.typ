#import "../template.typ": img

= 异步任务

相较于初赛，我们实现了更多的 IO 多路复用、事件通知的机制和系统调用。在实现相关的系统调用中，我们大量使用了 rust 的 future。

== IO 多路复用

=== ppoll / pselect

ppoll 和 pselect 是对传统 poll 和 select 的扩展版本，除了提供更高精度的超时参数外，还允许在调用时原子性地更改线程的信号屏蔽字，从而避免在解除信号屏蔽和进入阻塞等待之间产生竞态条件，因此它们更适合在涉及信号处理的场景下使用。

当用户尝试通过 ppoll / pselect 系统调用同时轮询多个 fd，我们会将将多个 fd 的轮询的 future 包装为一个统一的 `PPollFuture` / `PSelectFuture`。当有超时需求时，可以将 `PPollFuture`  / `PSelectFuture` 作为 `TimedTaskFuture` 的 future 字段，在每次轮询时检查时钟是否超时。

```rust
/// A future wrapper for a timed task.
pub struct TimedTaskFuture<F: Future + Send + 'static> {
    /// the specific time point when the task expires
    expire: Duration,
    /// the future which use the task
    future: F,
    /// whether the task is in the timer manager
    in_manager: bool,
}
```

我们还需要处理被信号中断的情况，所以我们提供了 `IntrBySignalFuture`，每一次轮询检查是否收到非阻塞信息。最后通过 rust 内置的 `Select2Futures` 即可实现可被信号中断、可定时的多 IO 轮询。

=== epoll

epoll 是高性能 I/O 多路复用机制，相比 poll 和 select 更适合大规模 fd 的场景；用户先将 fd 注册到内核维护的 epoll 实例中，随后只需等待内核在这些 fd 上有事件发生时进行通知。

我们使用 EPollInstance 来管理轮询的 fd。`interest` 和 `ready` 分别维护了轮询的所有的 fd 及其信息、ready 的 fd 以及它返回的信息。

```rust
pub struct EPollInstance {
    interest: SpinNoIrqLock<BTreeMap<usize, EPollFd>>,
    ready: SpinNoIrqLock<Vec<(usize, EPollEvent)>>,
    file_inner: FileInner, 
}
```




