= 支持RISC-V和Loongarch的硬件抽象层

== 概述

硬件抽象层(Hardware Abstraction Layer)，主要任务是为不同平台架构提供统一的接口，具体到本项目，就是为riscv64和loongarch64两个平台提供统一的面向内核使用的接口。这些接口主要和CPU架构相关，提供了硬件配置，内核入口，中断控制，中断处理，页表映射等抽象。

注意，该HAL并不负责外设一类的硬件抽象，那些将由驱动程序等提供。

Chronix 的硬件抽象层命名为 CinpHAL（CinpHAL Is Not Poly HAL） 。该抽象层的设计在一定程度上借鉴了#link("https://github.com/Byte-OS/polyhal")[PolyHal]。

== 启动内核

启动操作系统前，会先进入HAL定义的启动函数，以RISCV平台为例：

```rust
#[naked]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".text.entry")]
unsafe extern "C" fn _start(id: usize) -> ! {
    core::arch::naked_asm!(
        // 1. set boot stack
        // a0 = processor_id
        // sp = boot_stack + (hartid + 1) * 64KB
        "
            .attribute arch, \"rv64gc\"
            mv      tp, a0
            addi    t0, a0, 1
            li      t1, {boot_stack_size}
            mul     t0, t0, t1                // t0 = (hart_id + 1) * boot_stack_size
            la      sp, {boot_stack}
            add     sp, sp, t0                // set boot stack
        ",
        // 2. enable sv39 page table
        // satp = (8 << 60) | PPN(page_table)
        "
            la      t0, {page_table}
            srli    t0, t0, 12
            li      t1, 8 << 60
            or      t0, t0, t1
            csrw    satp, t0
            sfence.vma
        ",
        // 3. enable float register
        "
            li   t0, (0b01 << 13)
            csrs sstatus, t0 
        ",
        // 4. jump to rust_main
        // add virtual address offset to sp and pc
        "
            li      t2, {virt_ram_offset}
            or      sp, sp, t2
            la      a2, {entry}
            or      a2, a2, t2
            jalr    a2                      // call rust_main
        ",
        boot_stack_size = const Constant::KERNEL_STACK_SIZE,
        boot_stack = sym BOOT_STACK,
        page_table = sym BOOT_PAGE_TABLE,
        entry = sym rust_main,
        virt_ram_offset = const VIRT_RAM_OFFSET,
    )
}

pub(crate) fn rust_main(id: usize) {
    Instruction::set_tp(id);
    if RUNNING_PROCESSOR.fetch_add(1, Ordering::AcqRel) == 0 {
        super::clear_bss();
        crate::console::init();
        print_info();
        let _ = unsafe { super::_main_for_arch(id, true) };
    } else {
        let _ = unsafe { super::_main_for_arch(id, false) };
    }
    
    if RUNNING_PROCESSOR.fetch_sub(1, Ordering::AcqRel) == 1 {
        unsafe { Instruction::shutdown(false) }
    }
    
    loop {}
}
```
其中，\_start函数会被链接到.text.entry位置，也就是内核的入口处。\_start会进行启动栈和启动页表的设置
CPU配置，随后跳转到rust_main函数。rust_main函数会通过一个链接在DATA段的RUNNING_PROCESSOR原子变量，来检查是否是第一个进入的
CPU和是否是最后一个退出的CPU，执行相应的操作。例如，第一个启动的CPU需要负责清零BSS段，初始化调式控制台和打印HAL启动信息，最后
一个退出的CPU需要负责关机。

== 页表与页分配器

在操作系统的内存管理子系统中，页表与页分配器是构建虚拟内存机制的核心组件。我们通过精心设计的Rust特征(trait)系统，实现静态约束，保证不同平台的抽象层实现提供相同的接口。实现了跨平台的内存管理抽象层。该设计采用分层架构，将页表操作、页表项管理和物理页分配三个关键功能解耦，同时保持高度的类型安全和性能。

=== 页表项

页表项特征如下：

```rust
pub trait PageTableEntryHal {
    fn new(ppn: PhysPageNum, map_flags: MapFlags) -> Self;
    fn flags(&self) -> MapFlags;
    fn set_flags(&mut self, map_flags: MapFlags);
    fn ppn(&self) -> PhysPageNum;
    fn set_ppn(&mut self, ppn: PhysPageNum);
    fn is_valid(&self) -> bool;
    fn set_valid(&mut self, val: bool);
    fn is_user(&self) -> bool;
    fn set_user(&mut self, val: bool);
    fn is_readable(&self) -> bool;
    fn set_readable(&mut self, val: bool);
    fn is_writable(&self) -> bool;
    fn set_writable(&mut self, val: bool);
    fn is_executable(&self) -> bool;
    fn set_executable(&mut self, val: bool);
    fn is_cow(&self) -> bool;
    fn set_cow(&mut self, val: bool);
    fn is_dirty(&self) -> bool;
    fn set_dirty(&mut self, val: bool);
    fn is_leaf(&self) -> bool;
}
```

`PageTableEntryHal`特征定义了页表项的标准行为接口，它完整封装了现代处理器架构中页表项的所有关键属性。该特征包含基本的有效性(`is_valid`)、用户态访问权限(`is_user`)等标志位操作，支持读写执行权限的细粒度控制，实现了写时复制(COW)机制所需的状态位(is_cow)。该特征还通过`is_leaf`方法支持多级页表结构，为不同架构的页表实现提供了统一的抽象接口。

=== 页帧分配器

页分配器特征如下：

```rust
pub trait FrameAllocatorHal: Sync {
    fn alloc(&self, cnt: usize) -> Option<Range<PhysPageNum>> {
        self.alloc_with_align(cnt, 0)
    }
    fn alloc_with_align(&self, cnt: usize, align_log2: usize) -> Option<Range<PhysPageNum>>;
    fn dealloc(&self, range_ppn: Range<PhysPageNum>);
}

pub trait FrameAllocatorTrackerExt: FrameAllocatorHal + Clone {
    fn alloc_tracker(&self, cnt: usize) -> Option<FrameTracker<Self>> {
        self.alloc_with_align(cnt, 0).map(
            |range_ppn| FrameTracker::new_in(range_ppn, self.clone())
        )
    }
}
```

物理页分配由`FrameAllocatorHal`特征抽象，它提供了分配(`alloc`)和释放(`dealloc`)物理页的核心操作。通过FrameAllocatorTrackerExt扩展特征，我们实现了RAII风格的FrameTracker包装器，确保物理页在生命周期结束时自动回收，有效防止内存泄漏。

=== 页表

页表特征
```rust
pub trait PageTableHal<PTE: PageTableEntryHal, A: FrameAllocatorHal> {
    fn from_token(token: usize, alloc: A) -> Self;
    fn get_token(&self) -> usize;
    fn translate_va(&self, va: VirtAddr) -> Option<PhysAddr>;
    fn translate_vpn(&self, vpn: VirtPageNum) -> Option<PhysPageNum>;
    fn new_in(asid: usize, alloc: A) -> Self;
    fn find_pte(&self, vpn: VirtPageNum) -> Option<(&mut PTE, usize)>;
    fn map(&mut self, vpn: VirtPageNum, ppn: PhysPageNum, perm: MapFlags, level: PageLevel) -> Result<&mut PTE, ()>;
    fn unmap(&mut self, vpn: VirtPageNum) -> Result<PTE, ()>;
    unsafe fn enable_high(&self);
    unsafe fn enable_low(&self);
}
```

页表的核心操作由PageTableHal特征定义，它采用泛型设计，同时约束页表项类型(PTE)和分配器类型(A)。该特征提供了从页表令牌(`token`)初始化的能力(`from_token`)，支持虚拟地址到物理地址的转换(`translate_va`/`translate_vpn`)，以及页表项的查找与修改(find_pte)等关键操作。特别地，`map`和`unmap`方法实现了多级页表的映射管理，而`enable_high`/`enable_low`方法则支持高低地址空间的特权级切换。

== 陷入上下文和中断处理

TrapContext保存了进程陷入内核态和从内核态恢复时需要保存的全部上下文，分为上半部分和下半部分，上半部分为用户通用和浮点寄存器，下半部分为内核的调用者保存寄存器。

当进程从用户态陷入内核态时，中断处理程序会保存此时的所有寄存器内容到陷入上下文的上半部分，并从下半部分恢复内核寄存器。在内核处理完用户请求后，会调用restore函数，该函数会保存被调用者保存的寄存器到下半部分（调用者保存寄存器在调用restore前已被保存），从上半部分恢复被调用者寄存器，再返回到用户态。

抽象层为TrapContext封装了保存和恢复的操作，提供一致的接口。

== 快速用户指针检查

快速用户指针检查是一种利用缺页异常来判断是否需要进行缺页处理的方法。

在进行快速用户指针检查前，会首先将缺页异常的中断向量指向一个特殊的异常处理函数，它会直接跳过缺页的指令，并设置某个寄存器为特定值，表示缺页异常发生过。检查后检测这个寄存器，就能知道访问该地址是否会缺页，进一步地调用VmSpace的缺页处理函数。这样无需软件遍历页表就能知道地址是否能直接访问，实现快速用户指针检查。

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

== 其他硬件抽象

=== 处理器指令抽象

在操作系统内核开发中，处理器指令的抽象是连接硬件与软件的关键桥梁。我们设计的 InstructionHal trait 对处理器核心指令进行了系统性的抽象和封装。

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

=== 定时器抽象

定时器是操作系统实现时间管理和任务调度的核心硬件组件。TimerHal 特征提供了简洁而完备的定时器抽象：

```rust
pub trait TimerHal {
    /// get current time
    fn read() -> usize;
    /// set next time interrupt
    fn set_timer(timer: usize);
    /// get timer freq
    fn get_timer_freq() -> usize;
}
```


