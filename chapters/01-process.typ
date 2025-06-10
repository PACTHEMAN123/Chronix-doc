#import "../template.typ": img, tbl

= 进程管理

== 概述

进程是操作系统对一个正在运行的程序的一种抽象，是系统资源分配的基本单位源。线程是进程的一个实体，是 CPU 调度和分派的基本单位。Chronix仿照Linux内核，进程线程统一用TaskControlBlock（TCB）表示,通过统一的API操作任务，达到简洁有效的统一管理。Chronix采用无栈协程调度的方式，将每个任务包装成Future进入任务调度，减小任务调度开销。

== 任务控制块（TaskControlBlock）设计

== 任务调度

=== 异步无栈协程

协程是一种比线程更加轻量级的并发单位，允许在执行过程中挂起并稍后恢复，从而使得单个线程可以处理多个任务。无栈协程和有栈协程的主要区别在于它们的上下文管理方式。Chronix的调度模型采用的是异步无栈协程架构。协程即协作式多任务的子例程，而无栈协程指的是任务没有独立的栈，而是通过在堆中维护一个状态机来管理上下文，每次切换上下文是保存执行的状态，下次恢复时从该位置继续执行。这使得Chronix操作系统中的任务管理调度有如下优势：

- *无需独立堆栈*：无栈协程不需要为每个协程分配独立的堆栈内存，而是通过状态机或闭包管理上下文。这使得单个协程的内存占用极低（通常为几十到几百字节）。非常适用于同时处理大量并发任务的场景，如高并发服务器，实时数据处理等

- *高效切换性能*：任务挂起/恢复时无需切换堆栈或操作系统的线程上下文，仅需保存少量局部变量和程序计数器。切换开销通常比有栈线程低一个数量级，甚至接近普通函数调用。这符合Chronix对性能开销的要求。

- *编译器优化支持*： 无栈协程通常由编译器直接生成状态机，在rust中内置的异步编程模型通过`async` 和`await` 关键字支持无栈协程,这种语法糖使得编写和使用无栈协程变得更加简洁和直观。每个`async` 函数在编译时会被转换为状态 机,自动管理状态的保存和恢复。无栈协程符合Rust所追求的“零成本抽象”,状态机的转  换和上下文切换在编译期确定,运行时开销极小。

=== Chronix基于协程的任务调度

在介绍Chronix调度原理前我们首先来介绍Rust中的异步模型：

1. *Future Trait*: 在Rust中将一个函数定义为`async`或者使用`async move`关键字将会创建一个无栈协程,称为一个`Future`。Future trait 作为一个任务的描述,告诉你这个任务将在未来完成,并且可以查询其状态。状态分为两种：`Poll::Pending` 和 `Poll::Ready`，当Future的状态为`Poll::Pending`时，表示任务尚未完成，当Future的状态为`Poll::Ready`时，表示任务已经完成。每个Future都有`poll`方法来推进运算，而Future中的`Context`包含了Futures运行所需的上下文信息，包括当前的运行状态，运行时环境，任务唤醒器Waker等。

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

2. *Executor*: Rust异步模型中并不内置Executor与Reactor，而是需要编程人员自己完善其逻辑，Chronix中Executor作用包括：
   - 运行Futures:调用Futures的poll方法，推进任务运行
   - 任务队列：单核环境下由Executor维护一个任务队列，存放准备执行的任务
   - 循环调度： 轮询任务队列，逐个执行任务。
借助Rust的异步模型，Chronix调度模型如下图所示：
#img(
    image("../assets/image/task/Scheduling-process.png"),
    caption: "Chronix基于协程的任务调度模型",
)

上图展现了Chronix调度将进行如下操作：

1. *任务创建*：用户创建任务时，将任务包装成Future推向任务调度器TaskQueue。Chronix中`spawn`函数负责创建并启动一个新的异步任务
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
2. *任务调度*： 当有任务进入任务队列时，调度器从队列中取出一个任务，并调用Future的poll方法，推进任务运行,此时分两种情况：
    - 任务完成：Future的poll方法返回`Poll::Ready`，表示任务进入运行，调度器将任务从队列中移除，开始任务运行，直到触发时钟中断后调用任务内置wake函数，再次进入TaskQueue,开启新一轮调度周期
    - 任务挂起：Future的poll方法返回`Poll::Pending`，Future直到下次遇见.awaits时或者自己的`waker`显式被调用唤醒，调度器将任务重新放回队列，等待下次调度。

== 多核心管理

无论是RISV-C 架构还是LoongArch 架构，每个核心有自己独立的一套寄存器,因此从总体上看,只需要给每个核心划分好，便可以开始进行并行调度运行。 

而针对多核的调度，往届优秀内核作品如Titanix，Phoenix在多核环境下仍然采用维护一个静态任务队列，有一个任务需要执行时就选择一个空闲的CPU来承接任务，这种方式虽然简单，但却与现代CPU内存架构相违背：现代CPU架构采用多级缓存，任务运行时会涉及到多个缓存层，倘若只采用一个任务队列，如下图情况所示：任务一会在这个CPU运行，一会在另一个CPU上运行，每到新的一处，cache miss会带来巨大的性能效率折扣。
#img(
    image("../assets/image/task/bad_for_one_queue.png"),
    caption: "单队列调度模型不利于多核环境"
)

针对这个问题，多核情况下Chronix为每一个CPU各自维护一个任务队列，每个CPU只会运行自己的任务队列，这样可以减少cache miss，提高性能。而任务的分配则采用`Round-Robin`的方式进行分配，初步达到负载平衡的效果。

#img(
    image("../assets/image/task/multi_queue.svg"),
    caption: "多队列调度模型"
)

=== 负载的追踪

CPU负载(cpu load)指的是某个时间点进程对系统的压力,计算CPU负载可以让调度器更好的进行负载均衡处理，以便提高系统运行效率。尽管直觉的认为，任务多的CPU承载的压力会更大，但这种估计比较粗略。设想下列情形：CPU A和 CPU B都有一个任务在运行，但A上的是CPU密集型任务，B上的是IO密集型任务，那么仅用TaskQueue深度判断负载就无法区分.Chronix参考Linux 3.8版本， 引入了简化的PELT算法来每一个sched entity对负载的贡献.

*PELT （Per-Entity Load Tracking）*是一种用于动态跟踪任务（进程/线程）和 CPU 负载的算法，旨在为调度器提供更精细的负载信息。它通过*指数衰减历史负载*的方式，综合考虑任务的当前和历史运行状态，从而更精确地反映系统的实际负载情况。PELT 将任务的负载视为一个随时间衰减的累加值。每个时间窗口（默认为 *1024 微秒*）内的负载会被赋予一个权重，并根据时间推移按指数衰减。这意味着：
   - 最近的负载对当前值影响更大。
   - 历史负载的影响逐渐减弱，但不会完全消失.

  任务的负载计算公式为：
     $ "Load" = sum_(i=0)^n "load"_i y^i $

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
- *任务级*：每个任务的 `load_avg` 。
- *CPU 级*：汇总所有运行队列（`runqueue`）中任务的负载，计算 CPU 的总负载。
- *系统级*：通过所有 CPU 的负载信息，全局调度决策，负载均衡。
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
