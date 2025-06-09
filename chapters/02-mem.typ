#import "../template.typ": img

= 内存管理

== 内存分配器

=== 页帧分配器

使用了`BitmapAllocator`分配页帧。

=== Slab缓存分配器

自制Slab缓存，高效实现小对象分配和回收。

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

=== 地址空间管理

Chronix 使用 RAII 机制和多层抽象机制管理地址空间。

== 缺页异常处理

Chronix 目前能够利用缺页异常处理来实现写时复制（Copy on write）、懒分配（Lazy page allocation）以及用户地址检查机制和零拷贝技术。

=== CoW 写时复制技术

在 `fork` Chronix 会将原`MemorySpace`中的除共享内存外每一个已分配页的PTE都删除写标志位，然后重新映射到页表中，并将。用户向COW页写入时会触发缺页异常陷入内核，在`VmArea::handle_page_fault`函数中，内核会根据COW标志位转发给COW缺页异常处理函数，缺页异常处理函数会根据`StrongArc<FrameTracker>`的原子持有计数判断是否为最后一个持有者，如果不是最后一个持有者，会新分配一个页并复制原始页的数据并恢复写标志位重新映射，如果是最后一个持有者，直接恢复写标志位。


=== 懒分配技术

懒分配技术主要用于堆栈分配以及mmap匿名映射或文件映射。在传统的内存分配方法中，操作系统在进程请求内存时会立即为其分配实际的物理内存。然而，这种方法在某些情况下可能导致资源的浪费，因为进程可能并不会立即使用全部分配的内存。

懒分配技术的核心思想是推迟实际物理内存的分配，直到进程真正访问到该内存区域。这样可以优化内存使用，提高系统性能。

对于内存的懒分配，比如堆栈分配，mmap匿名内存分配，Chronix将许可分配的范围记录下来，但并不进行实际分配操作，当用户访问到许诺分配但未分配的页面时会触发缺页异常，缺页异常处理函数会进行实际的分配操作。


对于mmap文件的懒分配，Chronix将其与页缓存机制深度融合，Chronix 同样执行懒分配操作，当缺页异常时再从页缓存中获取页面。


=== 用户地址检查

内核的一些功能需要操作用户空间地址，比如sys_read就需要将文件内容写到位于用户空间的缓冲区中。

然而直接使用用户空间地址是不安全的，而内核为了节省空间和降低延迟，在用户空间使用了延迟分配和写时复制等技术，这意味着直接读写用户空间地址可能会引发缺页异常。

最大的风险就是死锁。内核在持有锁时常常会关闭外部中断，正是为了防止处理外部中断时重复加锁而导致死锁。然而，缺页中断属于不可屏蔽中断，不能像外部中断那样避免死锁，而延迟分配和写时复制等技术非常依赖缺页中断，就算使用某种方式屏蔽了缺页中断，对用户空间地址的读写依然不能正常进行。

一种解决方法就是模拟MMU对用户空间地址进行检查，并在发现缺页时调用缺页异常处理程序尝试处理，确保内核访问用户空间地址时不会引发缺页。这也就是我们的用户指针的主要功能。

==== 实现原理

使用了“快速用户指针检查”技术。

目前提供了UserPtr和UserSlice两种抽象。这里只解释UserPtr，UserSlice使用方法类似。

==== 原始用户指针

原始用户指针是对原始指针的直接包装，它实现了Clone，Copy和Send特征，但是不能直接读写，需要通过ensure_read或ensure_write转换成相应的可读/可读写用户指针。对用户空间地址的检查和缺页处理就发生在这些函数中。
UserPtrRaw<u8>有一个特殊的方法cstr_slice，用来将用户提供的C字符串转换为u8数组。

==== 可读写用户指针

可读写用户指针会锁定其使用的页面，防止页面换出。析构时会自动取消锁定。

=== 使用方法

读用户指针
```rust
let task = current_task().unwrap();
let user_ptr = 
    UserPtrRaw::new(uaddr as *const TimeSpec)
        .ensure_read(&mut task.vm_space.lock())
        .unwarp();
let time_val = *user_ptr.to_ref();
```

写用户指针
```rust
let task = current_task().unwrap();
let user_ptr = UserPtrRaw::new(uaddr as *mut Tms)
    .ensure_write(&mut task.vm_space.lock())
    .unwarp();
let current_task = current_task().unwrap();
let tms_val = Tms::from_time_recorder(current_task.time_recorder());
user_ptr.write(tms_val);
```

读用户缓冲区
```rust
let task = current_task().unwrap();
let user_buf = 
    UserSliceRaw::new(buf as *mut u8, len)
        .ensure_write(&mut task.vm_space.lock())
        .unwarp();
let ret = file.read(user_buf.to_mut()).await?;
```

写用户缓冲区
```rust
let task = current_task().unwrap();
let user_buf = 
    UserSliceRaw::new(buf as *mut u8, len)
        .ensure_read(&mut task.vm_space.lock())
        .unwarp();
let ret = file.write(user_buf.to_mut()).await?;
```

将用户提供的c式字符串转为String
```rust
let task = current_task().unwrap();
user_cstr // UserPtrRaw<u8>
    .cstr_slice(&mut task.vm_space.lock()) // Option<UserSlice<u8, ReadMark>>
    .unwarp() // UserSlice<u8, ReadMark>
    .to_str() // Result<&str, str::Utf8Error>
    .unwarp() // &str
    .to_string() // String
```

