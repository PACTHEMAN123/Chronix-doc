#import "../template.typ": img

= 内存管理

== 内存分配器

=== 页帧分配器

使用了`BitmapAllocator`分配页帧。`BitmapAllocator`不同于伙伴分配器基于空闲链表实现，而是使用了线段树和位图。查找、分配和回收页帧时，这个分配器的空间局部性更好，性能更高。

=== Slab缓存分配器

Chronix自制了Slab缓存，高效实现小对象分配和回收。

Slab缓存专门用来分配固定大小的小对象，这类对象大小通常在200字节内，可以连续存储在一页内存上。Slab分配器管理了一系列Slab缓存，每个Slab缓存只负责分配和回收同一大小的内存块。

SlabCache有三个链表实现的栈，分别是Empty块链表，Free块链表, Full块链表。SlabBlock管理一系列连续的空间内存块，每个链表保存一系列剩余空间情况不同的SlabBlock，分别是空，半满，全满。

SlabBlock占据多张物理页，这与其保存的元素大小有关，一个SlabBlock的容量至少为8，如果保存的对象大小为1024字节，SlabBlock会占用4张物理页。

SlabBlock使用FreeNode链表来管理空闲的内存块，每次分配或回收都是操作链表头，相当于链表实现的栈，压入和弹出的时间复杂度为O(1)。

分配内存时，SlabCache会优先从free块链表头部的SlabBlock分配，其次是empty，最后才是创建新的SlabBlock。

== 地址空间

=== 地址空间布局

Chronix 地址空间的设计如下图所示：

#img(
    image("../assets/image/mm/address-space.svg"),
    caption: "地址空间"
)<address_layout>

Chronix 内核态页表保存在全局内核地址空间 `KVMSPACE` 中，用户地址空间共享内核二级页表。

对于内核地址空间，为了方便管理所有物理地址，采用偏移映射的方式将物理地址以加上偏移量的方式映射为虚拟地址，即每一个虚拟地址都为对应物理地址加上`VIRT_RAM_OFFSET`。

对于用户地址空间，为了利用分页机制的灵活性，消除外部碎片，采用随机映射的方式将虚拟页随机映射到空闲物理内存中任意一页。

用户地址空间和内核地址空间互不重叠，意味着它们可以共用同一张页表。这种设计使得在内核可以方便地同时访问内核和用户的地址，而不用切换页表和刷新tlb，减少了系统调用的开销。

=== Boot 阶段高位映射

在RISCV平台，使用OpenSBI引导内核启动时，内核会被放置在一个固定的地址（Qemu中是0x8020_0000)，计算机开始执行内核代码时，pc也会指向这个地址。由于采用了地址空间偏移映射，而且目前的内核代码不是位置无关的，这会导致一些问题，例如在建立页表映射之前，内核使用了绝对地址寻址，而这个绝对地址还未被映射，就会导致致命错误。

为了解决这一问题，需要尽可能在使用绝对地址之前建立页表映射。因此，我们在内核中硬编码了一个页表，它只有几页巨页，负责在启动阶段实现临时的地址空间偏移映射。这个页表的定义如下：

```rust
#[repr(C, align(4096))]
pub struct BootPageTable([u64; Constant::PTES_PER_PAGE]);

pub static mut BOOT_PAGE_TABLE: BootPageTable = {
    let mut arr: [u64; Constant::PTES_PER_PAGE] = [0; Constant::PTES_PER_PAGE];
    arr[2] = (0x80000 << 10) | 0xcf;
    arr[256] = (0x00000 << 10) | 0xcf;
    arr[258] = (0x80000 << 10) | 0xcf;
    BootPageTable(arr)
};
```

arr[2]的页表项建立了一个从0x8000_0000到0x8000_0000大小为1GiB的全等映射，这是为了防止在启用页表到跳转之间pc失效。

arr[256]的页表项建立了从0xffff_ffc0_0000_0000到0x0的大小为1GiB的偏移映射，这是为一些外设设置的。

arr[258]的页表项建立了从0xffff_ffc0_8000_0000到0x8000_0000的大小为1GiB的偏移映射，这是映射了全部内核代码和数据。

内核会在随后的启动流程中切换到一个更细致的页表代替这个临时页表。

在龙芯平台，因为使用直接映射窗口代替页表映射，所有没有这样的麻烦。

=== VmArea 虚拟内存区域

在Linux中，一个VMA管理一系列连续且拥有相同访问权限的虚拟页面，即一个VMA的prot属性和真实的PTE的属性是完全一致的。这样做的好处是只需获取VMA就能知道这一区域内所有PTE的权限，而不用查页表，加快了权限检查等对页表的只读操作，而且逻辑清晰，易于维护。但是这也有代价，那就是采用写时复制或者其他需要修改PTE权限的优化技术时，需要频繁地分裂和合并VMA。

Chronix为了实现的简便，采用了不同的实践。虽然VmArea和Linux一样有类似的prot字段表示VMA的权限，但是并没有那么严格，允许（且仅允许）PTE的写入权限缺失。这样一来避免了分裂和合并VmArea的需求，而对于权限检查需要查页表这一问题，下文的“快速用户空间地址检查”会给出解决方案。

除了权限管理，Chronix使用了RAII控制物理内存页的回收，每个VmArea维护一个保存着物理页的容器，在析构时自动归还所有物理页。

== 缺页异常处理

Chronix 目前能够利用缺页异常处理来实现写时复制（Copy on write）、懒分配（Lazy page allocation）、零页（Zero page）以及用户地址检查机制和零拷贝技术。

=== 写时复制

为了支持写时复制，VmArea中实际上保存的是物理页的共享指针，`StrongArc<FrameTracker>`，这个`StrongArc`就是`Arc`的没有弱引用计数的版本。

在 `fork`时， Chronix 会将原`MemorySpace`中的除共享内存外每一个已分配页的PTE都删除写标志位，然后重新映射到页表中，并将一分配物理的共享指针浅复制一份存入新的VmArea。用户向COW页写入时会触发缺页异常陷入内核，在`handle_page_fault`函数中，内核会根据COW标志位转发给COW缺页异常处理函数，缺页异常处理函数会根据`StrongArc<FrameTracker>`的原子持有计数判断是否为最后一个持有者，如果不是最后一个持有者，会新分配一个页并复制原始页的数据并恢复写标志位重新映射，如果是最后一个持有者，直接恢复写标志位。

=== 懒分配

懒分配技术主要用于堆栈分配以及mmap匿名映射或文件映射。在传统的内存分配方法中，操作系统在进程请求内存时会立即为其分配实际的物理内存。然而，这种方法在某些情况下可能导致资源的浪费，因为进程可能并不会立即使用全部分配的内存。

懒分配技术的核心思想是推迟实际物理内存的分配，直到进程真正访问到该内存区域。这样可以优化内存使用，提高系统性能。

对于内存的懒分配，比如堆栈分配，mmap匿名内存分配，Chronix将许可分配的范围记录下来，但并不进行实际分配操作，当用户访问到许诺分配但未分配的页面时会触发缺页异常，缺页异常处理函数会进行实际的分配操作。

对于mmap文件的懒分配，Chronix将其与页缓存机制深度融合，Chronix 同样执行懒分配操作，当缺页异常时再从页缓存中获取页面。

=== 零页

零页是一种利用写时复制来实现懒分配的功能。当在处理读操作引发的懒分配缺页时，不会申请新页，而是按写时复制的方法将缺页地址映射到一页预分配的零页上，等到发生写入时再进入写时复制逻辑，申请新页。

=== 用户地址检查

内核的一些功能需要操作用户空间地址，比如sys_read就需要将文件内容写到位于用户空间的缓冲区中。

然而直接使用用户空间地址是不安全的，而内核为了节省空间和降低延迟，在用户空间使用了延迟分配和写时复制等技术，这意味着直接读写用户空间地址可能会引发缺页异常。

最大的风险就是死锁。内核在持有锁时常常会关闭外部中断，正是为了防止处理外部中断时重复加锁而导致死锁。然而，缺页中断属于不可屏蔽中断，不能像外部中断那样避免死锁，而延迟分配和写时复制等技术非常依赖缺页中断，就算使用某种方式屏蔽了缺页中断，对用户空间地址的读写依然不能正常进行。

一种解决方法就是模拟MMU对用户空间地址进行检查，并在发现缺页时调用缺页异常处理程序尝试处理，确保内核访问用户空间地址时不会引发缺页。这也就是我们的用户指针的主要功能。

==== 实现原理

使用了“快速用户地址检查”技术。这一技术简而言之就是在检查时将中断向量表中的缺页异常入口设置为一个特殊的入口，尝试访问用户地址空间，根据是否产生缺页中断来检查用户地址是否需要处理缺页。这一功能集成在HAL中，在此不过多介绍。

目前提供了`UserPtr`和`UserSlice`两种抽象。这里只解释`UserPtr`，`UserSlice`使用方法类似。

==== 原始用户指针

原始用户指针是对原始指针的直接包装，它实现了Clone，Copy和Send特征，但是不能直接读写，需要通过`ensure_read`或`ensure_write`转换成相应的可读/可读写用户指针。对用户空间地址的检查和缺页处理就发生在这些函数中。
`UserPtrRaw<u8>`有一个特殊的方法`cstr_slice`，用来将用户提供的C字符串转换为u8数组。

==== 可读写用户指针

可读写用户指针除了能保证创建时的读写不会引发缺页异常，还会在其生命周期内锁定其使用的页面，防止页面换出。

== 内核空间动态映射

Chronix 支持了内核空间的动态映射，允许灵活地将物理页映射到内核空间中。

=== 实现原理

内核空间动态映射的主要难点在于如何同步不同进程的内核页表。

在RISCV平台，进程页表的高半空间复制了内核页表的高半空间，这是通过复制一级页表项实现的，如果要同步更改内核的一级页表项，就需要去修改所有进程页表的页表项，在进程很多的情况下，这会带来较大的开销。目前Chronix的解决办法是，分配8个一级页表项(对应8GiB的空间)用于内核空间的动态映射，而这8个页表项指向的二级页表在初始化内核页表时就已分配好。这样在使用内核空间的动态映射时，不会修改到一级页表项，也就没有这些同步问题了。

龙芯平台没有这种同步问题，因为龙芯有PGDL和PGDH两个页表寄存器，可以对低半虚拟地址空间和高半虚拟地址空间分别使用不同的页表。

=== 用途

内核加载程序时，一般需要把可执行文件从硬盘读到内存中，解析各种信息以正确加载程序。如果内核不支持动态映射内存，只能申请一大块足以容纳整个文件的连续物理页。当可执行文件很大时，申请这么多连续物理页不仅容易失败，而且还不能利用上文件的页缓存。如果支持动态映射，就可以把可执行文件页缓存中的物理页映射到连续的地址空间中，并且是懒映射，不仅提高了程序加载的健壮性，还加快了速度。

