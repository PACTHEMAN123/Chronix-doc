#import "../template.typ": img, tbl

= 进程间通信

== 信号机制

信号是一种进程间通信（IPC）机制，用于向进程发送 *异步* 通知，让进程响应特定事件。每种信号都有一个 *编号* 和特定的 *行为* 。行为可以是 *默认*，*忽略*，或者用户自定义处理行为 *handler*（通过系统调用设置）

=== 数据结构设计

==== SigAction

```rust
#[derive(Clone, Copy)]
#[repr(C)]
/// signal action struct under riscv-linux arch
pub struct SigAction {
    pub sa_handler: usize,
    pub sa_flags: u32,
    pub sa_restorer: usize,
    pub sa_mask: [SigSet; 1],
}

#[derive(Clone, Copy)]
/// signal action warpper for kernel
pub struct KSigAction {
    /// inner sigaction
    pub sa: SigAction,
    /// is user defined?
    pub is_user: bool,
}
```
- `SigAction` 会在系统调用 `sigaction()` 中用到,用来注册信号处理的行为.
  - `sa_handler`：注册处理的函数
  - `sa_flags`：设置信号处理的行为标志
  - `sa_restorer`：指定了信号处理函数结束后跳转的地址
  - `sa_mask`：设置处理该信号时应该要阻塞哪些信号

`SigAction` 需要符合 linux 的定义。`KSigAction` 包含多一个信息：该 `SigAction` 是否是用户定义的，用于后续判断是否需要信号上下文切换。


==== SigManager

Chronix 的每个进程都会持有一个 `SigManager`。`SigManager` 给进程间提供了简洁的收发信息的调用接口。`SigManager` 几乎包含了一个进程所有信号相关的结构。

```rust
pub struct SigManager {
    /// Pending standard signals
    pub pending_sigs: VecDeque<SigInfo>,
    /// Pending real-time signals
    /// low-numbered signals have highest priority.
    /// Multiple instances of real-time signals can be queued
    pub pending_rt_sigs: BTreeMap<usize, VecDeque<SigInfo>>,
    /// bitmap to avoid dup standard signal
    pub bitmap: SigSet,
    /// Blocked signals
    pub blocked_sigs: SigSet,
    /// Signal handler for every signal
    pub sig_handler: [KSigAction; SIGRTMAX + 1],
    /// Wake up signals
    pub wake_sigs: SigSet,
}

```

- `pending_sigs`：用于记录收到的*标准信号*（Standard Signal）
- `pending_tr_sigs`：用于记录收到的*实时信号*（Real-time Signal）
- `bitmap`：用于避免重复存储相同的*标准信号*
- `blocked_sigs`：该进程需要阻塞的信号
- `sig_handler`：每个信号对应的 *行为*
- `wake_sigs`：唤醒当前进程的指定的信号，当收到指定的信号，当前进程应该被唤醒。


==== 信号上下文

在需要执行用户指定的 *handler* 时，类似中断处理，需要切换上下文。包括了屏蔽当前处理的信号、保存当前用户程序的寄存器信息，并设置新的 sepc sp 等，从而在从内核态返回用户态时，可以到达用户定义的处理函数的位置。这里的上下文，称为信号上下文。

信号上下文，在 Chronix 中用 `UContext` 来存储。对于不同的架构，信号上下文的内容可能会不一样（主要是机器的寄存器信息），所以我们使用 HAL 来抽象出了信号上下文的保存与恢复机制：

```rust
pub trait UContextHal {
    /// save current signal context
    /// include: blocked signals, current user_x
    fn save_current_context(old_blocked_sigs: usize, cx: &TrapContext) -> Self;
    /// restore to old trap context using the ucontext
    fn restore_old_context(&self, cx: &mut TrapContext);
}
```

内核无需知道 `UContext` 的内容。在需要信号上下文切换时，会使用 `save_current_context` 来得到一份 `UContext`，并将其保存在用户栈上，并在 TCB 中记录该位置。恢复时读取用户栈，根据保存的位置获得 `UContext` 并调用 `restore_old_context`来恢复原来的现场。


=== Chronix 信号原理

Chronix 的信号机制实现遵循了 linux 的标准。将信号分为了标准信号和实时信号两种类型。

==== 信号处理方式

信号的处理方式本质上只有3种：采用默认处理、选择忽略、采用用户定义的处理函数。Chronix 为了简化设计，统一将这些方式转换为具体的 handler 函数。具体的，比如在 `sigaction()` 的系统调用处理中，将用户传入的 `SIG_IGN` 的处理方式，转换为`ign_sig_handler`；将用户传入的 `SIG_DFL`，根据转换表，转换为默认处理的其中一个；如果用户传入自定义的函数，则将 handler 设为这个函数的地址。

默认处理一共有 5 种：

```rust
// os/src/signal/handler

/// handlers for Term
/// terminate the process.
pub fn term_sig_handler(signo: usize)

/// handlers for Ign
/// ignore the signal
pub fn ign_sig_handler(signo: usize)

/// handlers for Core
/// Default action is to terminate the process and dump core
pub fn core_sig_handler(signo: usize)

/// handlers for Stop
/// stop the process.
pub fn stop_sig_handler(signo: usize)

/// handlers for Cont
/// continue the process if it is currently stopped.
pub fn cont_sig_handler(signo: usize)
```

==== 发送信号

Chronix 在进程控制块的级别，设计了接收信号的接口。`SigInfo`结构体包含了该信号的编号以及一些额外信息，方便后续的处理。

```rust
/// receive function at TCB level
/// as we may need to wake up a task when wake up signal come
pub fn recv_sigs(&self, signo: SigInfo);

/// Unix has two types of signal: Process level and Thread level
/// in Process-level, all threads in the same process share the same signal mask
pub fn recv_sigs_process_level(&self, sig_info: SigInfo)
```

该过程会调用指定进程的`SigManager`的`receive()`方法，并检查指定进程是否在等待该信号来唤醒自己。如果进程收到了等待的信号，会调用 `wake()` 来唤醒自己。

==== 信号的等待和同步

在用户态，有时希望做到阻塞一个程序的执行，直至收到期待的信号。比如 `sys_rt_sigtimedwait` 等系统调用。只需要给对应的进程设置唤醒的信号，并调用`suspend_now()` `suspend_timeout()` 等 future 就可以简洁实现。

==== 信号的屏蔽与 pending

信号是可以被阻塞的（blocked）。注意阻塞和忽略的处理并非相同，忽略相当于直接丢弃这个信号，而阻塞是让信号“排队”，即变为 pending 状态，直到阻塞解除时再处理。在 Chronix 中，每个`SigManager`都会有一份`blocked_sigs`，用来判断哪些信号应该阻塞处理。因为标准信号和实时信号的排队机制不一样，所以需要我们将其分为了两个队列：`pending_sigs` `pending_rt_sigs`。如果有多个信号编号相同的标准信号到达，我们只会让第一个到达的信号实例进入队列，并设置`bitmap`忽略其他实例，只有在处理完毕之后才会重新允许接收。而对于实时信号，允许统一信号编号的多个实例同时排队，先到的实例先入队（FIFO）。

==== 信号的处理流程

在进程每一次从内核态切换到用户态的时候，都会做一次信号的处理（`check_and_handle()`），具体的流程如下：
+ 调用本进程的`SigManager` 的 `dequeue_one()`，获取要处理的信号。在`dequeue_one`中，会先检查有无可以处理的标准信号，再检查实时信号。
+ 如果该信号处理函数是内核定义的，直接调用即可。如果是用户定义的，则需要进一步处理。
+ 内核保存当前用户的中断上下文于`UContext`并推入用户栈。
+ 修改用户的中断上下文：修改`pc`至用户处理函数处，通过修改上下文的寄存器值来给函数传参数，修改返回地址为信号跳板（Signal Trampoline）。
+ 内核将控制权转移给用户，内核态切换到用户态。
+ 在用户态执行完信号处理函数，返回到信号跳板
+ 信号跳板会发出 `sys_rt_sigreturn()` 系统调用，此时会到内核态。
+ `sys_rt_sigreturn()` 会负责使用`UContext`恢复原来的用户中断上下文。
+ 完成信号的处理













