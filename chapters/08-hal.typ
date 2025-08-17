= 支持RISC-V和Loongarch的硬件抽象层

== 概述

硬件抽象层(Hardware Abstraction Layer)，主要任务是为不同平台架构提供统一的接口，具体到本项目，就是为riscv64和loongarch64两个平台提供统一的面向内核使用的接口。这些接口主要和CPU架构相关，提供了硬件配置，内核入口，中断控制，中断处理，页表映射等抽象。

注意，该HAL并不负责外设一类的硬件抽象，那些将由驱动程序等提供。

Chronix 的硬件抽象层命名为 CinpHAL（CinpHAL Is Not Poly HAL） 。该抽象层的设计在一定程度上借鉴了#link("https://github.com/Byte-OS/polyhal")[PolyHal]。

== LA64 与 RV64 的架构差异

=== 地址翻译

LA64 提供了直接地址翻译模式和可配置的页表翻译模式，和 RV64 只提供了预定义的几种模式不同。HAL 提供了地址兼容层，实现了可配置的地址宽度，页表级数，页大小等，自动处理地址计算。

=== 页表映射

LA64 和 RV64 在页表映射上的差异主要在于页表项格式的差异。HAL 对页表项进行了封装，并提供统一接口，实现一致的页表映射和权限控制。

=== 中断处理

首先 LA64 和 RV64 的中断机制差异较大，例外号等会不相同，所以 HAL 提供了统一的 TrapType 类型，操作系统通过调用 getTrapType 函数来获取当前上下文的统一中断类型。

两个架构还会有一些中断类型也不相同，例如LA64 在处理 TLB 未命中时会触发 TLB 重填例外，通知软件进行 TLB 的重填操作，而 RV64 则采用硬件重填的方式，而不需要软件处理。对于这类可有可无且操作系统不需要处理的 trap ，会在 getTrapType 里自动处理，返回一个 TrapType::Processed 值告知操作系统该中断已经被处理过了。

=== 其他差异

LA64和RV64还存在寄存器功能差异，控制指令差异等等， HAL 通过引入抽象的方法的进行了隔离，例如提供统一的 TLB 刷新函数，中断开关函数和多核启动函数等，在 HAL 内部调用平台相关指令实现这些功能。

```rust
pub trait InstructionHal {
    unsafe fn tlb_flush_addr(vaddr: usize);
    unsafe fn tlb_flush_all();
    unsafe fn enable_interrupt();
    unsafe fn disable_interrupt();
    unsafe fn is_interrupt_enabled() -> bool;
    unsafe fn enable_timer_interrupt();
    unsafe fn enable_external_interrupt();
    unsafe fn clear_sum();
    unsafe fn set_sum();
    /// shutdown is unsafe, because it will not trigger drop
    unsafe fn shutdown(failure: bool) -> !;
    fn hart_start(hartid: usize, opaque: usize);
    fn set_tp(hartid: usize);
    fn get_tp() -> usize;
    fn set_float_status_clean();
}
```

== HAL 的特殊实现细节

=== 快速用户地址检查

快速用户地址检查，是一种利用缺页中断来检查用户地址是否能被内核直接使用的技术，用于避免内核态下处理缺页中断时潜在的死锁问题，并降低性能开销。

它的核心思想是，在需要检查用户地址可用性时，为缺页中断设置专用的入口，再尝试读写用户地址，若触发缺页中断，中断处理函数不会直接处理缺页，而是跳过这一指令并设置一个标志寄存器，内核在尝试读写用户地址后，检查标志寄存器即可知道地址是否需要进行缺页处理。

例如这是测试写入用户地址的代码
```rust
pub unsafe fn try_write_user(uaddr: *const u8) -> Result<(), TrapType> {
    const LOAD_PAGE_FAULT: usize = 13;
    const WRITE_PAGE_FAULT: usize = 15;
    let mut is_ok: usize = uaddr as usize;
    let mut scause: usize;
    let old_entry = stvec::read();
    let old_sstatus: usize;
    set_user_rw_trap_entry();
    asm!(
        "
        csrr {0}, sstatus
        lbu a1, 0(a0)
        sb  a1, 0(a0)
        ",
        out(reg) old_sstatus,
        inlateout("a0") is_ok,
        out("a1") scause,
        options(nostack, preserves_flags)
    );
    asm!(
        "
        csrw sstatus, {0}
        ",
        in(reg) old_sstatus,
        options(nostack, preserves_flags)
    );
    unsafe {
        stvec::write(old_entry.address(), old_entry.trap_mode().unwrap());
    }

    if is_ok == 0 {
        if scause == LOAD_PAGE_FAULT {
            return Err(TrapType::LoadPageFault(uaddr as usize));
        } else if scause == WRITE_PAGE_FAULT {
            return Err(TrapType::StorePageFault(uaddr as usize));
        } else {
            return Err(TrapType::Other);
        }
    }
    
    Ok(())
}
```

这样，缺页处理并没有在中断上下文中进行，内核处理时更为灵活，更容易避免对地址空间重复加锁的问题。这些操作都由 HAL 进行封装，确保安全，提高可用性。

=== 浮点寄存器相关

RV64 架构有一个方便的设计，它的 CSR 寄存器中会记录浮点寄存器的使用情况，在内核切换进程时，只需要查看一下这个CSR寄存器就可以知道进程是否使用过浮点寄存器，从而确定是否需要保护该进程的浮点上下文。

然而 LA64 并没有这一设计，但是它拥有一个特殊的浮点指令未使能例外(简称 FPD )，可以达成类似的效果。HAL 为每个核心分配了一个FS Dirty标志，并确保进入用户态时，浮点拓展总是关闭。这样，当用户进程第一次使用浮点寄存器时，就会触发一次 FPD 例外，HAL 会自动设置相应核心的 FS Dirty 标志，并打开浮点拓展。进程需要切换时，会检查当前核心的 FS Dirty 标志，确定是否需要保护浮点上下文。

当然，也可以直接根据浮点拓展的使能情况来代替 FS Dirty 标志，但是实践中发现这违反了单一职责原则，很容易写出问题，因此设计了专用的 FS Dirty 标志位。

=== 地址未对齐例外的处理

HAL 还会负责处理一些地址未对齐的例外。例如 LA64 规范没有要求硬件一定支持普通访存指令的非对齐访问。为了提高兼容性，HAL 会通过用对齐访问指令模拟非对齐访问指令，处理非对齐访存。

然而这并不是那么容易，处理非对齐访问不仅需要对出错指令进行软件译码，还要直接操作寄存器上下文。

对于用户态的非对齐访问还比较好处理，因为进程的所有寄存器都会被保存和恢复到TCB 的 TrapContext 中，操作 TrapContext 就相当于操作用户进程的寄存器。而内核中断处理程序并不会保存和恢复所有寄存器，而是只有调用者负责保存寄存器，也不会有 TrapContext 这种东西。如果修改内核中断处理，使其想用户中断处理那样保存完整的寄存器，会导致一定的性能损失。因此 HAL 选择为地址未对齐例外单开了一个独立的中断处理程序，这个处理程序会保存完整的寄存器上下文，中断处理程序可以直接操作它，实现模拟的访问操作。

该入口的汇编代码如下，它将全部寄存器保存到了栈上，并将指向这一寄存器上下文的指针作为参数传入rust编写的处理函数。

```asm
__kernel_ale_handler:
    addi.d $sp, $sp, -34*8
    st.d $r0, $sp, 0*8
    st.d $r1, $sp, 1*8
    st.d $r2, $sp, 2*8
    # skip sp(r3), save it later
    .set n, 4
    .rept 28
        SAVE_GP %n
        .set n, n+1
    .endr
    csrrd $t0, PRMD
    csrrd $t1, ERA
    st.d $t0, $sp, 32*8
    st.d $t1, $sp, 33*8
    addi.d $t0, $sp, 34*8
    st.d $t0, $sp, 3*8
    move $a0, $sp
    bl kernel_ale_handler
    ld.d $t0, $sp, 32*8
    ld.d $t1, $sp, 33*8
    csrwr $t0, PRMD
    csrwr $t1, ERA
    ld.d $r0, $sp, 0*8
    ld.d $r1, $sp, 1*8
    ld.d $r2, $sp, 2*8
    # skip sp(r3), load it later
    .set n, 4
    .rept 28
        LOAD_GP %n
        .set n, n+1
    .endr
    ld.d $sp, $sp, 3*8
    ertn
```
在 rust 处理函数中，直接操作这一上下文，就相当于操作中断发生处的上下文。