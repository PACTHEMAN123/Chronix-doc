= 时钟模块
<时钟模块>

== 时钟中断
<时钟中断>

在操作系统中实现精确计时依赖于硬件提供的时钟和计数器机制。`RISC-V` 架构提供了核心的 `mtime` (64 位计数器，记录自启动以来的时钟周期数) 和 `mtimecmp` (比较寄存器，用于触发时钟中断)。由于这些寄存器属于 M 特权级，运行在 S 特权级的内核无法直接访问。因此，`Chronix` 内核通过调用运行在 M 级的 SEE（如 OpenSBI）提供的 SBI 接口来间接设置 mtimecmp 和接收定时器中断。

`Chronix`在 RISC-V 上利用 `riscv::register::time::read()` 函数读取 mtime 计数器的值，获取系统启动后的时钟周期数作为基础时间度量。为了提升代码的清晰度、安全性和可维护性， `Chronix` 将获取到的原始计数值转换为 Rust 核心库 (core) 中的 Duration 结构体。Duration 提供了对时间间隔的统一、类型安全的抽象，避免了直接操作裸计数值容易导致的错误和概念混淆。更重要的是，它提供了丰富的时间操作方法（如加减、比较、单位转换等），极大地简化了内核中与时间相关的计算逻辑。

`LoongArch`架构采用不同的机制实现计时。其核心是一个高精度、恒定频率的计数器（通常称为 RDCNT 或类似名称），可通过专用指令（如 rdcnt.d/rdcntvl.d）直接读取当前计数值。计时器中断的控制则通过一组特定的控制状态寄存器 (CSR) 实现，主要包括：

1. #strong[`RDCNT`] 值读取： 内核使用 rdcnt.d (读取 64 位值) 或 `rdcntvl.d` (读取低 32 位值) 等指令直接读取计数器的当前值。该值同样代表自启动（或计数器复位）以来经过的时钟周期数。

2. #strong[计时器中断配置]： LoongArch 使用 `TICLR` (定时器中断清除寄存器)、`TINTVAL` (定时器初始值寄存器) 和 `TCFG` (定时器配置寄存器) 等 CSR 来设置和触发定时器中断。

    + TINTVAL 寄存器写入一个初始计数值（相对于某个基准点）。

    + 计数器持续累加。

    + 当计数器值达到或超过 TINTVAL 中设定的值时，会触发定时器中断。

    + 内核在中断处理程序中通常需要清除中断标志（通过 TICLR）并重新设置 TINTVAL 以安排下一次中断。

3. #strong[特权级访问]： 与 RISC-V 的 M/S 级隔离不同，LoongArch 内核（运行在 PLV0 特权级）通常可以直接访问这些计时相关的 CSR 进行配置和读取，无需类似 SBI 的固件中介层（除非特定硬件实现或安全启动有特殊要求）。这简化了内核计时器驱动的实现。

== 定时器机制
<定时器机制>

在操作系统中，定时器通常用来管理一段时间后需要触发的事件。这些定时器需要记录触发时间和要执行的回调函数。

事件抽象层 (TimerEvent trait)


```rust
/// 定义定时器到期时执行操作的通用接口
pub trait TimerEvent: Send + Sync {
    /// 定时器到期时的回调执行方法
    /// 
    /// 通过`Box<Self>`实现所有权转移，确保：
    /// 1. 动态分发能力：支持多态事件处理
    /// 2. 内存安全性：自动回收事件资源
    /// 
    /// 返回值设计支持定时器链式触发，特别适用于
    /// 周期性定时场景（如`sys_setitimer`）
    fn callback(self: Box<Self>) -> Option<Timer>;
}
```

`callback`方法的参数`self: Box<Self>`通过将 `self` 移动到 `Box`内，保证了 trait 对象的动态分发能力（即运行时多态），并且确保调用`callback`
时定时器的数据所有权被安全转移。返回值为`Option<Timer>`，表示在当前定时器触发后，可以选择性地创建一个新的定时器，这种设计使得定时器能够链式触发，以便支持需要重复触发定时器的`sys_setitimer`系统调用。通过`Send` 和 `Sync` trait bounds，确保定时器事件在多线程环境中是安全的。可以在线程间传递和共享
`Timer` 实例，而无需担心数据竞争问题。

`Timer`结构体用来表示一个具体的定时器实例，包含到期时间和需要执行的回调函数。具体设计如下：

```rust
/// 表示具有特定触发时间和关联事件的定时器实体
pub struct Timer {
    /// 绝对过期时间（基于单调时钟）
    pub expire: Duration,
    
    /// 动态事件处理器（实现TimerEvent trait）
    pub data: Box<dyn TimerEvent>,
}
```

核心特质：

+ 时间精度：采用Duration类型确保纳秒级时间精度

+ 事件解耦：泛化事件处理器与定时机制，增强扩展性

+ 零成本抽象：编译期静态分发与运行时动态分发结合优化性能

== 定时器队列
<定时器队列>

Chronix使用`TimerManager`结构体实现了一个高效、安全且易于管理的定时器管理机制。使用`BinaryHeap`二叉堆数据结构按到期时间排序管理所有的定时器,提供高效可靠的定时任务调度，其架构设计如下：

```rust
/// 全局定时器管理系统
pub struct TimerManager {
    /// 基于最小堆的优先级队列，按过期时间排序
    timers: SpinNoIrqLock<BinaryHeap<Reverse<Timer>>>,
}
```
当前实现特点：

+ 高效：采用二叉堆实现，插入删除操作时间复杂度为O(log n)，定时器调度时间复杂度为O(1)

+ 安全：采用SpinNoIrqLock`<BinaryHeap<Reverse<Timer>>> `确保定时器调度过程不被中断，保证定时器调度的可靠性

+ 触发机制： 同时处理用户态和内核态时间中断，中断触发时自动扫描到期定时器

== 用户态定时器
<用户态定时器>

基于以上内核定时器机制，Chronix提供多种用户态定时器类型，包括：`ITimer`, `PosixTimer`以及`TimerFd`。

1. #strong[ITimer]（间隔定时器）能够周期性地发送信号给进程，从而实现循环任务的定时执行。则只需对内核计时器进行简单包装即可，其callback实现如下：
```rust
fn callback(self: Box<Self>) -> Option<Timer> {
        self.task.upgrade().and_then(|task| {
            task.with_mut_itimers(|itimers| {
                let real_timer = &mut itimers[0];
                if real_timer.id != self.id {
                    return None;
                }
                /// send signal to task
                task.recv_sigs_process_level(SigInfo {
                    si_signo: SIGALRM,
                    si_code: SigInfo::KERNEL,
                    si_pid: None,
                });

                let real_timer_interval = real_timer.interval;
                if real_timer_interval == Duration::ZERO {
                    return None;
                }
                let next_expire = get_current_time_duration() + real_timer_interval;
                real_timer.next_expire = next_expire;
                Some(Timer {
                    expire: next_expire,
                    data: self,
                })
            })
        })
    }
```

2. #strong[PosixTimer]（Posix标准定时器）是基于timer类型系统调用实现的定时器
```rust
pub struct PosixTimer {
    /// tcb in PosixTimer
    pub task: Weak<TaskControlBlock>,
    pub sigevent: Sigevent,
    pub interval: Duration,
    pub next_expire: Duration,
    /// check if has been replace
    pub interval_id: TimerId,
    /// last 'sent' signo orverun count
    pub last_overrun: usize,
}

```
相较于ITimer,Posix 定时器提供多种通知方式:

- 信号（Signal）：sigevent中可以选择发送任何实时信号而不仅仅是固定的 SIGALRM。实时信号支持排队，因此即使短时间内多次触发，也不会丢失。

- 线程回调（Thread Callback）：sigevent中可以直接指定一个回调函数，让内核在一个指定的线程中执行它。这种方式更加现代化和安全，尤其是在多线程程序中，避免了信号处理函数的复杂性。

其callback核心逻辑如下：

```rust
// 仅当当前确实到期（或已过期）才投递信号
        if now >= self.next_expire {
            // 计算错过了多少个周期（k-1）
            if self.interval > Duration::ZERO {
                let late = now.saturating_sub(self.next_expire);
                // k = floor(late/interval) + 1   （至少为 1）
                let k = (late.as_nanos() / self.interval.as_nanos() as u128) as usize + 1;
                overrun = k.saturating_sub(1);
                // 刷新下一次到期（跳过多个周期）
                self.next_expire = self.next_expire + self.interval * (k as u32);
            } else {
                // one-shot：下一次到期清零（不再重启）
                self.next_expire = Duration::ZERO;
            }
            // 记录 overrun 到 map，符合 “最近一次已投递信号的 overrun”
            timer_entry.last_overrun = overrun;
            // 同步 map 中的 next_expire
            timer_entry.next_expire = self.next_expire;
            // 发送信号（仅支持 SIGEV_SIGNAL）
            match self.sigevent.sigev_notify {
                SIGEV_SIGNAL => {
                    let sig_info = SigInfo {
                        si_signo: self.sigevent.sigev_signo as usize,
                        si_code: SigInfo::KERNEL,
                        si_pid: None,
                    };
                    task.recv_sigs_process_level(sig_info);
                }
                _ => {
                    log::warn!(
                        "Unsupported sigev_notify value: {}",
                        self.sigevent.sigev_notify
                    );
                }
            }
            // 若为周期定时器，则把“下一次”重新入队；否则结束
            if self.interval > Duration::ZERO && self.next_expire > Duration::ZERO {
                // 递归沿用同一 interval_id，直到下一次 settime/disarm 才会递增
                let next = Timer {
                    expire: self.next_expire,
                    data: self,
                };
                return Some(next);
            } else {
                return None;
            }
        }
        // 未到期则不应被调用（正常不会进入这里；守稳返回 None）。
        None
    }

```

3. #strong[TimerFd]（文件描述符定时器）是基于文件描述符实现的定时器，其主要特点是精度高、可靠性高、可移植性好。其功能与`PosixTimer`类似，通过实现`File` trait可以与其他文件系统接口兼容方便管理，并且由于这个特性可以实现异步管理提高性能效率：
```rust
fn poll(mut self: Pin<&mut Self>, cx: &mut Context) -> Poll<Self::Output> {
        let inner = self.timer.lock();
        // 检查是否有到期事件
        if inner.expirations > 0 {
            // 如果有，就绪
            Poll::Ready(())
        } else {
            // 没有到期事件，并且定时器未设置，则立即就绪
            // 这对应于 timerfd_settime 设置 it_value 为 0 的情况。
            if inner.next_expire.is_zero() {
                Poll::Ready(())
            } else {
                // 定时器已设置但未到期，我们需要等待
                // 更新 Waker
                if self.waker.as_ref().map(|w| !w.will_wake(cx.waker())).unwrap_or(true) {
                    drop(inner);
                    self.waker = Some(cx.waker().clone());
                }
                // 将 Waker 注册到全局定时器管理器
                // 确保在到期时会唤醒当前任务
                // 避免每次 poll 都添加新的定时器。。
                TIMER_MANAGER.add_timer(Timer::new_waker_timer(
                    self.timer.lock().next_expire,
                    cx.waker().clone(),
                ));

                Poll::Pending
            }
        }
    }
```