#import "../template.typ": img, tbl, equation

= 进程管理

== 概述

进程是操作系统对一个正在运行的程序的一种抽象，是系统资源分配的基本单位源。线程是进程的一个实体，是 CPU 调度和分派的基本单位。Chronix仿照Linux内核，进程线程统一用TaskControlBlock（TCB）表示,通过统一的API操作任务，达到简洁有效的统一管理。Chronix采用无栈协程调度的方式，将每个任务包装成Future进入任务调度，减小任务调度开销。

== 任务控制块（TaskControlBlock）设计

=== 内容结构设计

Chronix基于rcore ch6进行开发，其原始设计明确区分设计了`Process`和`Thread`两个结构分别表示进程与线程。但是Linux内核对task这一单位结构的实现更具启发性：它并未严格区分进程和线程，而是通过统一的 API（如 sys_clone，sys_clone 通过传递不同的 flags 参数来控制新任务与父任务共享哪些资源，包括创建线程还是进程）来管理任务。其次rcore设计中使用了`TaskControlBlockInner`这一结构体来包装内部可变内容，并使用一把大锁来保护内部可变性。但是这样的设计往往降低运行效率，因为大锁的开销很大。这也启示着Chronix细分任务中的字段，以提高运行效率

综上所述Chronix参考Linux采用统一的TaskControlBlock（TCB）表示任务将其作为调度的基本单元，并在此基础上进行扩展，增加了一些新的字段并将字段分类，其具体设计如下：

```rust
/// Task 
pub struct TaskControlBlock {
    // ! immutable
    /// task id
    pub tid: TidHandle,
    /// leader of the thread group
    pub leader: Option<Weak<TaskControlBlock>>,
    /// whether this task is the leader of the thread group
    pub is_leader: bool,
    // ! mutable only in self context , only accessed by current task
    pub trap_context: UPSafeCell<TrapContext>,
    /// waker for waiting on events
    pub waker: UPSafeCell<Option<Waker>>,
    /// address of task's thread ID
    pub tid_address: UPSafeCell<TidAddress>,
    /// time recorder for a task
    pub time_recorder: UPSafeCell<TimeRecorder>,
    /// Futexes used by the task.
    pub robust: UPSafeCell<UserPtrRaw<RobustListHead>>,
    // ! mutable only in self context, can be accessed by other tasks
    /// exit code of the task
    pub exit_code: AtomicUsize,
    /// ELF file the task executes
    pub elf: Shared<Option<Arc<dyn File>>>,
    #[allow(unused)]
    /// base address of the user stack, can be used in thread create
    pub base_size: AtomicUsize,
    /// status of the task
    pub task_status: SpinNoIrqLock<TaskStatus>,
    // ! mutable in self and other tasks
    /// virtual memory space of the task
    pub vm_space: Shared<UserVmSpace>,
    /// parent task
    pub parent: Shared<Option<Weak<TaskControlBlock>>>,
    /// child tasks
    pub children: Shared<BTreeMap<Pid, Arc<TaskControlBlock>>>,
    /// file descriptor table
    pub fd_table: Shared<FdTable>,
    /// thread group which contains this task
    pub thread_group: Shared<ThreadGroup>,
    /// process group id
    pub pgid: Shared<PGid>,
    /// use signal manager to handle all the signal
    pub sig_manager: Shared<SigManager>,
    /// pointer to user context for signal handling.
    pub sig_ucontext_ptr: AtomicUsize, 
    /// current working dentry
    pub cwd: Shared<Arc<dyn Dentry>>,
    /// Interval timers for the task.
    pub itimers: Shared<[ITimer; 3]>,
    #[cfg(feature = "smp")]
    /// sche_entity of the task
    pub sche_entity: Shared<TaskLoadTracker>,
    /// the cpu allowed to run this task
    pub cpu_allowed: AtomicUsize,
    /// the processor id of the task
    pub processor_id: AtomicUsize,
}
```

Chronix将字段分为若干类：

+ #strong[不可变字段]： 这些字段自任务诞生后到任务被回收都不会改变，代表任务的基本标识信息，包括`tid`(任务ID),`leader`(线程组主任务弱引用)，`is_leader`: 是否为主任务的标识

+ #strong[任务内可变，不可被其他线程访问的字段]： 这些字段仅在任务内可访问改变，且仅在任务内访问改变。这样的内容可以只需要用`UPSafeCell`(包装的线程安全的UnSafeCell),而非相对低效的自旋锁包装。这样在保证数据安全性的情况下最大化提升了性能。这类字段包括：
    - `trap_context`(任务内陷阱上下文)
    - `waker`(任务内唤醒器)
    - `tid_address`(任务内线程ID地址)
    - `time_recorder`(任务内时间记录器)
    - `robust`(任务内futex列表)

+ #strong[任务内可变，可被其他线程访问&修改的字段]： 这些字段仅在任务内可访问改变，且可被其他任务访问。为了原子安全性这类任务需要用原子变量(*`atomic variable`*)或者*`Share<T>`*包装。 `Shared<T>`也即`Arc<SpinNoIrqLock<T>>`，用于在多线程环境下安全访问共享数据,`Arc`为rust提供的原子引用计数智能指针，维护共享数据的引用计数从而在多个所有者共享统一数据是保证数据安全， `SpinNoIrqLock`为自旋锁，用于在中断禁用情况下短时间锁定保证原子性。

这类字段包括：
    - `exit_code`(任务内退出码)
    - `elf`(任务内ELF文件)
    - `base_size`(任务内用户栈基址)
    - `task_status`(任务状态)
    - `vm_space`(任务内虚拟内存空间)
    - `parent`(任务内父任务弱引用)
    - `children`(任务内子任务映射表)
    - `fd_table`(任务内文件描述符表)
    - `thread_group`(任务内线程组)
    - `pgid`(任务内进程组ID)
    - `sig_manager`(任务内信号管理器)
    - `sig_ucontext_ptr`(任务内信号上下文指针)
    - `cwd`(任务内当前工作目录)
    - `itimers`(任务内间隔定时器)
    - `sche_entity`(任务内调度实体)
    - `cpu_allowed`(任务内允许运行的CPU掩码)
    - `processor_id`(任务内处理器ID)

=== 进程&线程的统一与区分

如上章所言，Chronix将进程和线程统一为“任务”（taskcontrolblock），通过统一的API操作，达到简洁有效的统一管理。Chronix中进程和线程的创建、调度、销毁、状态查询等操作都通过`TaskControlBlock`来实现。区分进程与线程通过以下操作。

进程任务在Chronix中被标记为`leader`,是`thread_group`(线程组)的第一个任务&主任务。进程任务的`tid`(task_id)被设置为线程组的`tgid`(thread_group_id)。当新创建一个进程时,`thread_group` 仅有进程本身这个成员, TaskControlBlock 的 `is_leader` 字段设为 True 。子进程建立对parent的弱引用,父进程在children中添加子进程的引用。注意子进程诞生后作为独立的进程并不继承父进程的thread_group, 而是新建一个目前仅包含自己的thread_group。

线程在当 sys_clone 设置 CLONE_THREAD 标志位时诞生。子线程将复制父线程thread_group并将自己添加进去。`is_leader`字段设为false，表示不是主任务。
同时设置`leader`。 进程相关字段(parent,childern)继承自leader。

Chronix ThreadGroup结构体定义如下：

```rust
pub struct ThreadGroup {
    members: BTreeMap<Tid, Weak<TaskControlBlock>>,
    alive: usize,
    pub group_exiting: bool,
    pub group_exit_code: usize,
}
```

每个ThreadGroup包含一个BTreeMap将线程组任务标识号tid与主任务的弱引用关联起来。alive字段记录当前线程组中存活的任务数量。group_exiting字段表示线程组是否正在退出，group_exit_code字段表示线程组退出时的退出码。后三者保障线程回收过程的正确进行。

=== 任务状态

Chronix中为贴合可能出现的任务状态设计了多类`TaskStatus`枚举，包括：

#align(center)[#table(
  columns: 2,
  align: (col, row) => (auto,auto,).at(col),
  inset: 10pt,
  [状态], [含义],
  [`Ready`],
  [任务已准备就绪，可以被调度。],
  [`Running`],
  [正在运行的任务。此状态下，任务占用 CPU，执行其代码。],
  [`Zombie`],
  [任务已终止，但其进程控制块 (PCB),仍然存在，以便父进程可以读取其退出状态。会最终退出调度循环在`handle_zombie`函数中被释放回收。],
  [`Stopped`],
  [任务已停止运行，通常是由于接收到停止信号（如
  `SIGSTOP`）。可以通过特定信号（如 `SIGCONT`）恢复运行。在调度中会被悬挂直到被唤醒。],
  [`Interruptable`],
  [任务处于可中断的等待状态，等待某个事件（如 I/O
  操作完成或资源释放）。此状态下，任务可以被信号中断并唤醒。],
  [`UnInterruptable`],
  [任务处于不可中断的等待状态，等待某个事件的发生。此状态下，任务不会被信号中断，以确保某些关键操作的完整性和原子性。],
)
]

== 任务调度

=== 异步无栈协程

协程是一种比线程更加轻量级的并发单位，允许在执行过程中挂起并稍后恢复，从而使得单个线程可以处理多个任务。无栈协程和有栈协程的主要区别在于它们的上下文管理方式。Chronix的调度模型采用的是异步无栈协程架构。协程即协作式多任务的子例程，而无栈协程指的是任务没有独立的栈，而是通过在堆中维护一个状态机来管理上下文，每次切换上下文是保存执行的状态，下次恢复时从该位置继续执行。这使得Chronix操作系统中的任务管理调度有如下优势：

- _无需独立堆栈_：无栈协程不需要为每个协程分配独立的堆栈内存，而是通过状态机或闭包管理上下文。这使得单个协程的内存占用极低（通常为几十到几百字节）。非常适用于同时处理大量并发任务的场景，如高并发服务器，实时数据处理等

- _高效切换性能_：任务挂起/恢复时无需切换堆栈或操作系统的线程上下文，仅需保存少量局部变量和程序计数器。切换开销通常比有栈线程低一个数量级，甚至接近普通函数调用。这符合Chronix对性能开销的要求。

- _编译器优化支持_： 无栈协程通常由编译器直接生成状态机，在rust中内置的异步编程模型通过`async` 和`await` 关键字支持无栈协程,这种语法糖使得编写和使用无栈协程变得更加简洁和直观。每个`async` 函数在编译时会被转换为状态 机,自动管理状态的保存和恢复。无栈协程符合Rust所追求的“零成本抽象”,状态机的转  换和上下文切换在编译期确定,运行时开销极小。

=== Chronix基于协程的任务调度

在介绍Chronix调度原理前我们首先来介绍Rust中的异步模型：

+ #strong[`Future Trait`] : 在Rust中将一个函数定义为`async`或者使用`async move`关键字将会创建一个无栈协程,称为一个`Future`。Future trait 作为一个任务的描述,告诉你这个任务将在未来完成,并且可以查询其状态。状态分为两种：`Poll::Pending` 和 `Poll::Ready`，当Future的状态为`Poll::Pending`时，表示任务尚未完成，当Future的状态为`Poll::Ready`时，表示任务已经完成。每个Future都有`poll`方法来推进运算，而Future中的`Context`包含了Futures运行所需的上下文信息，包括当前的运行状态，运行时环境，任务唤醒器Waker等。

如下代码块展示了Chronix中如何将TaskControlBlock包装成Future：

```rust
/// The outermost future for user task
pub struct UserTaskFuture <F: Future + Send + 'static>{
    task: Arc<TaskControlBlock>,
    env: EnvContext,
    future: F,
}

impl <F:Future+Send+'static> Future for UserTaskFuture<F> {
    type Output = F::Output;
    fn poll(self: Pin<&mut Self>, cx: &mut Context) -> Poll<Self::Output> {
        let this = unsafe {self.get_unchecked_mut()};
        switch_to_current_task(current_processor(),&mut this.task,&mut this.env);
        let ret = unsafe{Pin::new_unchecked(&mut this.future).poll(cx)};
        switch_out_current_task(current_processor(),&mut this.env);
        ret
    }
}
```

+ #strong[`Executor`] : Rust异步模型中并不内置Executor与Reactor，而是需要编程人员自己完善其逻辑，Chronix中Executor作用包括：
- 运行Futures:调用Futures的poll方法，推进任务运行
- 任务队列：单核环境下由Executor维护一个任务队列，存放准备执行的任务
- 循环调度： 轮询任务队列，逐个执行任务。

借助Rust的异步模型，Chronix调度模型如下图2-1所示.

图2-1展现了Chronix调度将进行如下操作：

1. _任务创建_：用户创建任务时，将任务包装成Future推向任务调度器TaskQueue。Chronix中`spawn`函数负责创建并启动一个新的异步任务
    ```rust
   pub fn spawn<F>(future: F) -> (Runnable, Task<F::Output>)
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
    let schedule= move |runnable:Runnable, _info: ScheduleInfo | {
        #[cfg(not(feature = "smp"))]
        TASK_QUEUE.push(runnable);
        #[cfg(feature = "smp")]
        unsafe{PROCESSORS[crate::processor::schedule::select_run_queue_index()]
        .unwrap_with_mut_task_queue(|task_queue|task_queue.push_back(runnable))};
    };
    async_task::spawn(future, WithInfo(schedule))
   }
   ```
#img(
    image("../assets/image/task/Scheduling-process.png"),
    caption: "Chronix基于协程的任务调度模型",
)

2. _任务调度_： 当有任务进入任务队列时，调度器从队列中取出一个任务，并调用Future的poll方法，推进任务运行,此时分两种情况：

- _任务完成_：Future的poll方法返回`Poll::Ready`，表示任务进入运行，调度器将任务从队列中移除，开始任务运行，直到触发时钟中断后调用任务内置wake函数，再次进入TaskQueue,开启新一轮调度周期

- _任务挂起_：Future的poll方法返回`Poll::Pending`，Future直到下次遇见.awaits时或者自己的`waker`显式被调用唤醒，调度器将任务重新放回队列，等待下次调度。

== 中断异常管理

中断与异常是计算机系统中极为重要的控制机制，它们使处理器能够灵活地应对各种内部或外部事件，从而保证系统的可靠性、响应性与多任务处理能力。

- *中断（Interrupt）*通常由外部设备产生，用于异步通知处理器某些事件的发生，如键盘输入、定时器到时或网络数据到达。当中断发生时，处理器会暂时中止当前程序的执行，转而运行对应的中断服务程序（ISR），完成事件处理后再恢复原程序的执行。这种机制使得计算机能及时响应外部世界的变化，是实现外设驱动和操作系统调度的基础。

- *异常（Exception）*则是由处理器在执行指令过程中检测到的错误或特殊情况，如除以零、非法内存访问或系统调用请求。异常通常发生在程序内部，处理器会根据异常类型跳转到对应的异常处理例程，执行必要的修复、终止或内核服务操作。异常处理是系统稳定运行和程序安全的重要保障。

中断与异常虽然来源不同，但都通过打断当前控制流、进入内核或特权模式来完成对系统资源的控制与协调，是操作系统与硬件协作的核心机制之一。

在Chronix的内核用户态切换过程中，中断上下文保存在`TrapContext`数据结构中，保证用户态和内核态的正确切换。其中TrapContext以及TrapContextHal将在ChronixHal中详细介绍。

Chronix中，任务的生命周周期就是在如下代码所示，唤醒后由内核态到用户态又到内核态（中断处理）的循环，直到task被设置为zombie状态退出循环，check_and_handle执行信号处理函数,任务最终在waitpid中被回收。

```rust
///The main part of process execution and scheduling
///Loop `fetch_task` to get the process that needs to run, and switch the process 
pub async fn run_tasks(task: Arc<TaskControlBlock>) {  
    //info!("into run_tasks");
    task.set_waker(get_waker().await);
    /*info!(
        "into task loop, sepc {:#x}, trap cx addr {:#x}",
        current_task().unwrap().inner_exclusive_access().get_trap_cx().sepc,
        current_task().unwrap().inner_exclusive_access().get_trap_cx() as *const TrapContext as usize,
    );*/
    let mut is_interrupted = false;
    loop {
        // check current task status before return
        match task.get_status() {
            TaskStatus::Zombie => break,
            TaskStatus::Stopped => suspend_now().await,
            _ => {}
        }

        // return to user space and return back from user space
        trap_return(&task, is_interrupted);

        // task status might be change by other task
        match task.get_status() {
            TaskStatus::Zombie => break,
            TaskStatus::Stopped => suspend_now().await,
            _ => {}
        }

        let cx = task.get_trap_cx();
        let old_a0 = cx.ret_nth(0);
        // back from user space
        is_interrupted = user_trap_handler().await;

        // check current task status after return
        // task status maybe already change
        match task.get_status() {
            TaskStatus::Zombie => break,
            TaskStatus::Stopped => suspend_now().await,
            _ => {}
        }

        task.check_and_handle(is_interrupted, old_a0);
    }
}
```

=== 用户态 => 内核态

用户态切换到内核态发生在以下几种情况：

- 系统调用：当用户态进程发起系统调用时，会触发系统调用指令，陷入内核态，执行系统调用的内核函数。

- 异常：当发生除零错误、非法内存访问或其他异常时，处理器会产生异常，陷入内核态，执行相应的异常处理程序。

- 中断：当外部设备产生中断时，处理器会向CPU发出中断信号，CPU响应中断，将控制权转移到内核态，执行相应的中断处理程序。

Chronix中以上情况由user_trap_handler函数处理,当从用户态陷入内核态时,会进入`set_kernel_trap_entry()`保存用户态的上下文,并准备好内核态的环境。接着进入 trap_handler 函数根据不同的陷阱类型进行处理:
    - 系统调用：设置spec， 调用内核中的系统调用处理函数，倘若系统调用返回`EINTR`则会提示内核check_and_handle函数处理信号。
    - 页面错误：调用 handle_page_fault 函数
    - 非法指令&断点：分别向当前任务发送信号`SIGILL`和`SIGTRAP`，由check_and_handle函数处理。
    - 定时中断：让出处理器等待下次调度。
    - 外部中断：调用中断处理器处理

=== 内核态 => 用户态

Chronix内核态到用户态由trap_return函数完成。

```rust
#[no_mangle]
/// set the new addr of __restore asm function in TRAMPOLINE page,
/// set the reg a0 = trap_cx_ptr, reg a1 = phy addr of usr page table,
/// finally, jump to new addr of __restore asm function
pub fn trap_return(task: &Arc<TaskControlBlock>, _is_intr: bool) {
    unsafe {
        Instruction::disable_interrupt();  
    }
    set_user_trap_entry();
    
    task.time_recorder().record_trap_return();

    let trap_cx = task.get_trap_cx();

    // handler the signal before return
    // task.check_and_handle(is_intr);

    // restore float pointer and set status
    trap_cx.fx_restore();
    
    Instruction::set_float_status_clean();
    // restore
    hal::trap::restore(trap_cx);
    
    trap_cx.mark_fx_save();

    // set up time recorder for trap
    task.time_recorder().record_trap();
    // info!("[in record trap] task id: {}kernel_time:{:?}",task.tid(),task.time_recorder().kernel_time());
}
```

首先禁用中断保证上下文切换的原子性，调用 set_user_trap_entry() 函数设置陷阱处理函数,以确保下一次从用户态陷入内核态时能够正确处理。返回用户台前TrapContext 的地址存储在 sscratch 寄存器中, a0 寄存器指向TrapContext。再保存内核态的寄存器,切换栈指针并恢复状态寄存器、通用寄存器、用户态指针,与浮点指针。最后使用 sret 指令返回用户态。

=== 内核态 => 内核态

// todo: 扩充此部分
Chronix内核态允许嵌套中断，内核态发生中断后将保存调用者保存的寄存器，调用陷阱处理函数，恢复调用者保存寄存器最终返回。

== 多核心管理

无论是RISV-C 架构还是LoongArch 架构，每个核心有自己独立的一套寄存器,因此从总体上看,只需要给每个核心划分好，便可以开始进行并行调度运行。 

而针对多核的调度，往届优秀内核作品如Titanix，Phoenix在多核环境下仍然采用维护一个静态任务队列，有一个任务需要执行时就选择一个空闲的CPU来承接任务，这种方式虽然简单，但却与现代CPU内存架构相违背：现代CPU架构采用多级缓存，任务运行时会涉及到多个缓存层，倘若只采用一个任务队列，如下图情况所示：任务一会在这个CPU运行，一会在另一个CPU上运行，每到新的一处，cache miss会带来巨大的性能效率折扣。

针对这个问题，多核情况下Chronix为每一个CPU各自维护一个任务队列，每个CPU只会运行自己的任务队列，这样可以减少cache miss，提高性能。而任务的分配则采用`Round-Robin`的方式进行分配，初步达到负载平衡的效果。

#img(
    image("../assets/image/task/bad_for_one_queue.png"),
    caption: "单队列调度模型不利于多核环境"
)

#img(
    image("../assets/image/task/multi_queue.svg"),
    caption: "多队列调度模型"
)

=== 负载的追踪

CPU负载(cpu load)指的是某个时间点进程对系统的压力,计算CPU负载可以让调度器更好的进行负载均衡处理，以便提高系统运行效率。尽管直觉的认为，任务多的CPU承载的压力会更大，但这种估计比较粗略。设想下列情形：CPU A和 CPU B都有一个任务在运行，但A上的是CPU密集型任务，B上的是IO密集型任务，那么仅用TaskQueue深度判断负载就无法区分.Chronix参考Linux 3.8版本， 引入了简化的PELT算法来每一个sched entity对负载的贡献.

#strong[`PELT` （Per-Entity Load Tracking）]是一种用于动态跟踪任务（进程/线程）和 CPU 负载的算法，旨在为调度器提供更精细的负载信息。它通过#strong[指数衰减历史负载]的方式，综合考虑任务的当前和历史运行状态，从而更精确地反映系统的实际负载情况。PELT 将任务的负载视为一个随时间衰减的累加值。每个时间窗口（默认为 #strong[1024 微秒]）内的负载会被赋予一个权重，并根据时间推移按指数衰减。这意味着：
   - 最近的负载对当前值影响更大。
   - 历史负载的影响逐渐减弱，但不会完全消失.

  任务的负载计算公式为：
  #equation(
    [$ "Load" = sum_(i=0)^n "load"_i y^i $],
    caption: "任务负载计算公式"
  )

   其中：
   - $"load"_i$ 表示第 i 个时间窗口内的负载贡献。
   - $y = 0.5^(1/1024)$， 即指数衰减因子。

PELT的实现主要通过以下步骤完成：
1. 每个调度实体（如进程或线程）维护一个 `TaskLoadTracker` 结构体，包含以下关键字段：
- `load_avg`：综合历史负载的指数衰减平均值。
- `last_update_time`：上次更新时间戳。
- `load_sum`：历史负载的累加值。
- `period_contribute`：当前时间窗口内的负载贡献。

2. 负载更新时机：
   - 任务唤醒：当任务被唤醒时，更新其负载。
   - 时钟中断：当时钟中断发生时，更新所有任务的负载。

3. 分层次聚合：
- _任务级_：每个任务的 `load_avg` 。
- _CPU 级_：汇总所有运行队列（`runqueue`）中任务的负载，计算 CPU 的总负载。
- _系统级_：通过所有 CPU 的负载信息，全局调度决策，负载均衡。
```rust
/// system load balance
pub fn load_balance() -> bool {
    use core::sync::atomic::Ordering;
    use log::info;
    let mut loads = Vec::new();
    for i in 0..MAX_PROCESSORS {
        loads.push((i,unsafe { PROCESSORS[i].unwrap_with_sche_entity(|se| se.load_avg) }));
    }
    let (busiest_core, busiest_load) = loads.iter().max_by_key(|(_, l)| l).unwrap();
    let (idlest_core, idlest_load) = loads.iter().min_by_key(|(_, l)| l).unwrap();
    info!("busiest core: {}, busiest load: {}, idlest core: {}, idlest load: {}", busiest_core, busiest_load, idlest_core, idlest_load);
    if *busiest_load - *idlest_load > LOAD_THRESHOLD {
        info!("over threshold,migrate tasks");
        migrate_tasks(*busiest_core, *idlest_core);
        return false;
    }
    else {
        return true;
    }
}
```
