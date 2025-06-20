#import "../template.typ": img, tbl

= 总结与展望

== 工作总结

+ 实现进程管理和内存管理，以无栈协程的方式高效调度任务。

+ 实现虚拟文件系统，将具体文件系统与内核解耦合。

+ 支持多核调度运行。

+ 实现初赛要求的所有系统调用，通过了决赛第一阶段除部分ltp测试外的所有测试点。

+ 提出了基于无栈协程架构的内核态抢占式调度的方法。

+ 实现了页缓存与块缓存的统一。

+ 实现不同等级的调试日志，实现 backtrace 机制，在内核崩溃时能够打印函数调用栈。


== 经验总结

+ 系统调用的实现多参考 System Calls Manual 手册，支持 Linux raw syscall 规范。

+ 多核调试很困难，尽量依靠完善的日志，运行时查看相关信息。

+ 用户态程序调试需要紧密结合libc，对于没有调试符号的用户程序，内核需要根据系统调用顺序猜测用户态执行的位置。

+ 多重构代码，简洁的代码更方便后期修改与维护。

+ 多使用断言，在尽可能早的时候崩溃打印出相关信息，不然可能导致各种难以追踪的问题。


== 未来计划

+ 修改异步任务调度器，将全局队列拆分到各个核心，并增加优先级调度机制。

+ 适配星光二代板，完善相关驱动。

+ 支持更多ltp测例，修复更多内核不稳定的bug。

+ 提升网络的性能，并且支持sshd

+ 支持图形界面
