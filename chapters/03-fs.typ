#import "../template.typ": img

= 文件系统

== Virtual File System

Chronix 的虚拟文件系统总体架构如下图所示：

(add photos here)

虚拟文件系统（Virtual File System）为内核中的其他模块提供了文件系统的抽象。一个新的文件系统只需要实现 VFS 的方法和对象（见后文），就可以被内核其他模块使用。


=== 对象设计

Chronix 的 VFS 借鉴了 linux 的 VFS 的对象设计，但重构了接口的设计。同时，根据 rust 的语言特性做了一些适配，这部分参考了 Phoenix 的设计。一个对象（假设为 T） 一般由以下部分组成：


```rust
pub struct TInner {
    field1: usize,
    field2: i64
}
```

`TInner` 是对象 T 的基类。因为 rust 中没有原生的继承机制，所以我们需要用它来表示基类的抽象，以此降低代码重复率。新的文件系统只需要实现自己的 T 对象，并将 TInner 作为一个字段，就实现了继承。比如说我们需要实现 Ext4 文件系统的 T 对象：

```rust
pub struct Ext4T {
    inner: TInner,
}
```

同时，在 linux 的 VFS 中，每个对象都有对应 `operation` 的结构体，存放着指向这个对象的各个方法的指针。在 rust 中，我们可以这样表示：

```rust
pub trait T {
    fn method1() -> usize;
    fn method2() -> u64;
}
```

这些方法，需要新的文件系统（假设新的文件系统同上，是 Ext4）来实现：

```rust
impl T for Ext4T {
    fn method1() -> usize {
        // do something
        0
    }

    fn method2() -> u64 {
        // do something
        0
    }
}
```

简单来说：可以认为我们的 VFS 层为具体的文件系统提供了各个对象的#underline[模版] ，具体的文件系统需要根据模版实现#underline[具体的对象]。这样，内核或者 VFS 其他的对象，可以通过 `dyn` 的方式使用各个文件系统的具体对象的统一的接口。接下来会介绍各个对象在 VFS 中的作用

=== FSType

(todo)

=== SuperBlock

在 Chronix 内核的虚拟文件系统（VFS）中，`superblock`是一个核心的数据结构，它代表了一个已挂载文件系统的整体元信息。

```rust
/// the base of super block of all file system
pub struct SuperBlockInner {
    /// the block device fs using
    pub device: Option<Arc<dyn BlockDevice>>,
    /// file system type
    pub fs_type: Weak<dyn FSType>,
    /// the root dentry to the mount point
    pub root: Once<Arc<dyn Dentry>>,
}
```

- `device`：表示该文件系统所依赖的底层块设备。使用 `Option`，是为了支持如 `tmpfs` 等无设备文件系统。
- `fs_type`：表示该超级块所对应的文件系统类型。
- `root`：代表该文件系统的根目录项。使用 `Once` 是为了延迟初始化，确保挂载成功后根目录才能设置，防止重复或未定义的赋值。

当前结构专注于 VFS 必需信息，但未来可以扩展如 `mount_flags`、`super_operations` 等字段。它描述了一个文件系统的全局状态和基本接口。它屏蔽了底层实现差异，统一了对挂载点、块设备、根目录等的访问方式，是构建模块化、可扩展 VFS 的基础。


=== Dentry

在 Chronix 中，如果将文件系统的路径访问看作是一颗树，那么`Dentry` 可以看成其中的节点。

(Add photos here)

当我们试图获取一个具体路径的 `Inode`，会先获取该路径对应的 `Dentry`，再通过 `Dentry` 访问对应的 `Inode` 。 `Dentry` 的设计，使得路径和 `Inode` 解耦。同时，我们会使用 `DCache` 来缓存路径和 `Dentry` 的转换，从而加快查找速度。

基类设计如下：

```rust
/// basic dentry object
pub struct DentryInner {
    /// name of the inode it points to
    pub name: String,
    /// inode it points to
    pub inode: SpinNoIrqLock<Option<Arc<dyn Inode>>>,
    /// parent
    pub parent: Option<Weak<dyn Dentry>>,
    /// children
    pub children: SpinNoIrqLock<BTreeMap<String, Arc<dyn Dentry>>>,
    /// state
    pub state: SpinNoIrqLock<DentryState>,
}
```

- `name`：当前 `Dentry` 节点的名字
- `inode`：记录当前 `Dentry` 映射的 `Inode`。
- `parent`：记录了当前的节点的父节点。当我们需要得到当前 `Dentry` 的完整路径，会组合父节点的完整路径与当前节点的名字。
- `children`：记录当前的 `Dentry` 的子节点，这个设计，是为了支持在一个文件系统下挂载不同的文件系统，以及不同类型的 `Dentry` 自由组合。
- `state`：我们仿照 linux 的设计：Dentry 会有3种状态：`USED` `UNUSED` `NEGATIVE` 。在 Dentry 初始化时，状态为 `UNUSED`。在 Dentry 指向一个有效的 `Inode` 时，其状态为 `USED`。在 Dentry 的路径指向了一个无效的 `Inode` 时（Inode已经不存在了，或者不在该路径了），其状态为 `NEGATIVE`。`NEGATIVE` 状态的设计，使得我们在查询路径时，当遇到非法路径时可以尽早返回，避免重复查询文件系统。



=== Inode

索引节点是对文件系统中文件信息的抽象。对于文件系统中的文件来说，文件名可以随时更改，但是索引节点对文件一定是唯一的，并且随文件的存在而存在。

索引节点由 `Inode` trait 表示，如下：

```rust
pub trait Inode: Send + Sync + DowncastSync {
    /// Get metadata of this Inode
    fn meta(&self) -> &InodeMeta;

    /// Get attributes of this file
    fn get_attr(&self) -> SysResult<Stat>;
}
```

索引节点对象由 `InodeMeta` 结构体表示，下面给出它的结构和描述：

```rust
pub struct InodeMeta {
    /// Inode number.
    pub ino: usize,
    /// Mode of inode.
    pub mode: InodeMode,
    /// Device id for device inodes, e.g. tty device inode.
    pub dev_id: Option<DevId>,
    /// Super block this inode belongs to.
    pub super_block: Weak<dyn SuperBlock>,
    /// File page cache.
    pub page_cache: Option<PageCache>,
    /// Mutable date with mutex protection.
    pub inner: Mutex<InodeMetaInner>,
}

pub struct InodeMetaInner {
    /// Size of a file in bytes.
    pub size: usize,
    /// Last access time.
    pub atime: TimeSpec,
    /// Last modification time.
    pub mtime: TimeSpec,
    /// Last status change time.
    pub ctime: TimeSpec,
    /// State of the underlying file.
    pub state: InodeState,
}
```


=== File

(todo)

`File` 对象，即文件。每一个 File 对应于一个 file discriptor 。注意这里的 File 和文件系统的 *文件* 是完全两个概念，File 是进程打开的 *文件* 在内存中的表示。


== 磁盘文件系统

=== EXT4 文件系统

ext4（Fourth Extended Filesystem） 是 Linux 上广泛使用的日志型文件系统，是 ext3 的继任者，目标是提供更好的性能、可靠性和大容量支持。

我们使用了外部库 `lwext4_rust`。Ext4 文件系统对 VFS 的实现，放在了 `fs/ext4` 的文件夹内。从代码量可见：通过 VFS 的抽象，可以大大降低适配一个新的文件系统的心智负担。

- `Ext4SuperBlock`：“继承”了 VFS SuperBlock 的字段，实现了对应的方法，包裹的是 `Ext4BlockWrapper<Disk>`，Disk 为该文件系统使用的块设备。 
- `Ext4Inode`：“继承”了 VFS Inode 的字段，实现对应方法，包裹了 `Ext4File`（lwext4 向上提供的操作内部的Inode的单位），注意 lwext4_rust 提供的 inode 的方法并未将路径解耦。
- `Ext4Dentry`：本质上通过操作 Ext4Inode 来实现目录的操作。
- `Ext4File`: Ext4 实现的 File 对象，注意和 lwext4_rust 向上提供的 Ext4File 并非同一个东西。

(todo: how we change lwext4_rust)

== 非磁盘文件系统

add overview here

===  procfs

todo

=== devfs

todo

=== tmpfs

在 Chronix 中，临时文件系统（tmp fs） 和共享内存文件系统（shm fs）的文件都只存在于内存中。由于数据直接存储在内存中，读写操作的速度非常快，没有磁盘 I/O 的开销。tmpfs 中的数据在系统重启后会被清除，适合存储临时文件、缓存数据等不需要持久化的内容。shmfs 提供了进程间共享内存的机制，使得多个进程可以高效地共享数据，避免了数据复制的开销。内存文件系统可以根据实际使用情况动态调整大小，既不会过度占用内存，也能在需要时自动扩展。内存文件系统作为 VFS 的一个具体实现，完全遵循 VFS 的接口规范，这使得用户程序可以像操作普通文件系统一样操作内存文件系统，保持了良好的一致性和易用性。

利用 Chronix 内核中已有的页缓存机制（后文会介绍），可以完美地实现临时文件的读写。

```rust
pub struct TmpInode {
    inner: InodeInner,
    cache: Arc<PageCache>,
}
```

tmpfs 中的文件，真正持有的资源是一个 TmpInode。TmpInode 除了包含一些基本信息外（InodeInner），还持有一个页缓存的指针。当需要读写时，会调用以下两个函数。这两个方法的操作类似，会通过页缓存的映射，找到文件映射的物理内存，并以页为单位进行读写。

```rust
fn cache_read_at(self: Arc<Self>, offset: usize, buf: &mut [u8]) -> Result<usize, i32>;

fn cache_write_at(self: Arc<Self>, offset: usize, buf: &[u8]) -> Result<usize, i32>
```

`tmpfs` 需要支持文件的创建、删除。由于 `tmpfs` 的 `Inode` 只存在于内存中，且只会被 `Dentry` 持有，所以创建比较简单，只需要新建一个 `Dentry` 以及 `Inode` 即可。删除工作会有一些不一样：在 linux 中，一个 `Inode` 被 unlink 时，如果还有其他东西实际持有该 `Inode`（比如说进程的 `fd table`），那这个 `Inode` 就不能被删除。对于 `tmpfs`，为了实现该机制，在用户调用 unlink 来删除 tmpfs 文件时，会将对应的 `Dentry` 设为 Negative，即用户将无法通过目录查找访问到该文件，但这个文件对应的 `Inode` 依旧会被 `Dentry` 持有，从而让其他持有者依然可以对这个文件读写（比如通过 fd）。

在 linux manual 中，有写到：当 Open flags 为 `O_TMPFILE | O_DIRECTORY` 时，实际的操作是在目标的文件夹下，创建匿名文件。在 Chronix 中，以这种标识打开的文件实际不会放在任何文件夹下，而是唯一地被进程的 `fd table` 持有。

共享内存文件系统（简称为 `shmfs`），目前同等视作 `tmpfs`。

== 页缓存

在没有页缓存机制之前，用户读写文件，本质是向文件系统提供了一部份内存，请求文件系统将磁盘上的数据填入这些内存，文件系统会通过与磁盘的直接 IO 来读出/写入数据。这样的话，当一个文件需要大量的读写，将会造成大量的 IO，是不可忽视的开销。于是我们需要引入页缓存机制。

（add photos)

页缓存，即 Page Cache，以页为单位，缓存文件内容。当第一次读入文件的时候，系统将会将其放在 Page Cache 指向的内存中，再将这部分内存复制给用户。这样，在第二次需要读写文件的时候，系统可以直接在内存读写，而无需引发 IO，从而减小开销。同时，在用户使用内存映射的 IO（比如 mmap），可以通过将用户对应的虚拟地址空间映射到缓存的内存空间来实现。

(add photos)

=== Page

```rust
pub struct Page {
    /// page frame state or attribute
    pub is_dirty: AtomicBool,
    /// offset in a file (if is owned by file)
    pub index: usize, 
    /// the physical frame it owns
    pub frame: StrongArc<FrameTracker>,
}
```
`Page` 用于描述缓存的物理页。

`Page` 对象包含了：
- 脏位：用于判断释放缓存时是否需要写回。当发生 cache write 时会改变其状态。
- 偏移量：该页对应的文件内的偏移量
- 物理页帧：此处存放一个指向 RAII 对象`FrameTracker`的强引用指针，本质相当于记录该页对应的物理内存的位置

=== PageCache

```rust
pub struct PageCache {
    /// from file offset(should be page aligned)
    /// to the cached page
    pages: SpinNoIrqLock<HashMap<usize, Arc<Page>>>,
    /// the postion of EOF
    /// save it to prevent endless read
    /// notice that it may need to update when 
    /// cache write, as it may lead to expand the file
    end: AtomicUsize,
}
```

`PageCache`本质上提供了文件偏移量到缓存页的映射。磁盘文件系统的每个 Inode 都会持有一个 `PageCache`，通过 `PageCache` 完成 cache read/write，Inode 需要自己负责维护 `PageCache` 的状态。在 Inode 析构时，在 Drop 中会使用 `PageCache` 的 `flush` 方法，将所有脏页写回磁盘。


== 其他数据结构

=== FdTable

Unix 设计哲学将文件本身抽象成 Inode，其保存了文件的元数据；将内核打开的文件抽象成 File，其保存了当前读写文件的偏移量以及文件打开的标志；进程只能看见文件描述符，文件描述符由进程结构体中的文件描述符表进行处理。

当一个进程调用 `open()` 系统调用，内核会创建一个文件对象来维护被进程打开的文件的信息，但是内核并不会将这个文件对象返回给进程，而是将一个非负整数返回，即 `open()` 系统调用的返回值是一个非负整数，这个整数称作文件描述符。文件描述符和文件对象一一对应，而维护二者对应关系的数据结构，就是文件描述符表。在实现细节中，文件描述符表本质是一个数组，数组中每一个元素就是文件对象，而元素下标就是文件对象对应的文件描述符。

Phoenix 将 FdTable 定义成一个 `Vec<Option<FdInfo>>`，支持动态增长长度，在 fork 复制 `FdTable` 时比固定大小的数组时间开销更小，并且可以满足 Linux 系统中 RLimit 的限制。

```rust
#[derive(Clone)]
pub struct FdTable {
    table: Vec<Option<FdInfo>>,
    rlimit: RLimit,
}

#[derive(Clone)]
pub struct FdInfo {
    /// File.
    file: Arc<dyn File>,
    /// File descriptor flags.
    flags: FdFlags,
}
```

=== Pipe

管道（Pipe）是一种进程间通信的机制。其可以支持一个进程将数据流输出到另一个进程，或者从另一个进程读取数据流。管道本身可以看成一个 FIFO 的队列，写者（writer）在队尾添加数据，读者（reader）在队头取出数据。用户使用管道时，会向内核发出相关的系统调用，内核会返回两个 file discriber，一个指向写者文件，一个指向读者文件。写者文件只可以写不可读，读者文件反之。当两个进程拥有相同的 fd table 时，就可以“同时”使用这两个 fd。可能一个进程会向写者文件写入数据流，另一个进程可能会从读者文件读出数据流，从而实现进程间数据流的传递。如下图：

add pictures

todo