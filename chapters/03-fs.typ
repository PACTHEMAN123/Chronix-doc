#import "../template.typ": img

= 文件系统

== 虚拟文件系统

Chronix 的虚拟文件系统总体架构如下图所示：

#img(
    image("../assets/image/fs/fs-overview.svg"),
    caption: "文件系统总览"
)<file_system_overview>

虚拟文件系统（Virtual File System）为内核中的其他模块提供了文件系统的抽象。一个新的文件系统只需要实现 VFS 的方法和对象（见后文），就可以被内核其他模块使用。虚拟文件系统由以下几个抽象层组成：

- #strong[File System Layer]：用 `FSType` 以及 `FS_Manager` 来管理多个文件系统类型。一个文件系统类型可能会有多个文件系统实例。比如可能会有两个 Ext4 文件系统实例（挂载）。这一层会为一个类型的文件系统实现通用的挂载、解除挂载、查找挂载点等操作。
- #strong[Super Block Layer]：用 `SuperBlock` 来管理一个具体的文件系统实例。超级块会为上层提供 `Inode` 以供访问文件系统的具体资源。
- #strong[Inode Layer]：用 `Inode` 来管理一个文件系统里的“资源”。可能是文件、可能是目录、可能是设备 等等。注意 Inode 是资源的*独一无二*的映射。
- #strong[Dentry Layer]：用 `Dentry` 以及 `DCache` 来管理路径到具体`Inode`的映射。一个 `Dentry` 只可能对应一个 `Inode`，而一个`Inode`可以对应多个`Dentry`。
- #strong[File Layer]：可以视作 `Dentry` 在进程上的映射，使用 `File`以及`FdTable` 来管理。一个 `Dentry` 可以被多个 `File` 映射。


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
    fn method3(&self) -> usize {
        self.number + 1
    }
}
```

这些方法中， method 1、2需要新的文件系统（假设新的文件系统同上，是 Ext4）来实现：

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

而 method3 新的文件系统可以选择使用默认操作，或者自行实现以重载函数。

简单来说：可以认为我们的 VFS 层为具体的文件系统提供了各个对象的#underline[模版] ，具体的文件系统需要根据模版实现#underline[具体的对象]。这样，内核或者 VFS 其他的对象，可以通过 `dyn` 的方式使用各个文件系统的具体对象的统一的接口。接下来会介绍各个对象在 VFS 中的作用

=== FSType

在 Linux 内核的虚拟文件系统（VFS）架构中，file_system_type 是 每种文件系统实现的注册入口，是连接内核 VFS 与具体文件系统实现的桥梁。Chronix 参照了该设计，做出了一些简化。

```rust
pub struct FSTypeInner {
    /// name of the file system type
    name: String,
    /// the super blocks
    pub supers: SpinNoIrqLock<BTreeMap<String, Arc<dyn SuperBlock>>>,
}
```

`FSType` 负责了一类文件系统的管理，比如所有的 `Ext4` 文件系统都会用 Ext4FStype 来管理。supers 字段维护了具体的文件系统实例。

```rust
pub trait FSType: Send + Sync {
    /// get the base fs type
    fn inner(&self) -> &FSTypeInner;
    /// mount a new instance of this file system
    fn mount(&'static self, name: &str, parent: Option<Arc<dyn Dentry>>, flags: MountFlags, dev: Option<Arc<dyn BlockDevice>>) -> Option<Arc<dyn Dentry>>;
    /// shutdown a instance of this file system
    fn kill_sb(&self) -> isize;
    /// get the file system name
    fn name(&self) -> &str;
    /// use the mount path to get the super block
    fn get_sb(&self, abs_mount_path: &str) -> Option<Arc<dyn SuperBlock>>;
    /// get the static superblock
    fn get_static_sb(&'static self, abs_mount_path: &str) -> &'static Arc<dyn SuperBlock>;
    /// add a new super block
    fn add_sb(&self, abs_mount_path: &str, super_block: Arc<dyn SuperBlock>);
}
```

通过这些接口，我们可以快速将新的文件系统挂载到已有的文件系统下。

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


=== Dentry

在 Chronix 中，如果将文件系统的路径访问看作是一颗树，那么`Dentry` 可以看成其中的节点。

#img(
    image("../assets/image/fs/dentry.svg"),
    caption: "Dentry 路径前缀树"
)<dentry_path_trie>

当我们试图获取一个具体路径的 `Inode`，会先获取该路径对应的 `Dentry`，再通过 `Dentry` 访问对应的 `Inode` 。 `Dentry` 的设计，使得路径和 `Inode` 解耦。同时，我们会使用 `DCache` 来缓存路径和 `Dentry` 的转换，从而加快查找速度。

Dentry 基类设计如下：

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

使用 `rust` 的 `dyn` 对象的机制，`Dentry` 可以做到自由组合：即一个文件系统下的 `Dentry` 的 `parent` 或者 `children` 可以来自其他的文件系统。得益于这个机制，我们可以在 VFS 层就完成路径的解析、寻找。只需要对应的文件系统实现 Dentry 的方法（trait），我们就可以在 VFS 层实现以下路径查找的方法：

```rust
impl dyn Dentry {
    /// walk and search the dentry using the given related path(ex. a/b/c)
    /// construct the dentry tree along the way
    /// walk start from the current entry, recrusivly
    /// once find the target dentry or reach unexisted path, return
    /// if find, should return a USED dentry
    /// if not find, should return a NEGATIVE dentry
    pub fn walk(self: Arc<Self>, path: &str) -> Result<Arc<dyn Dentry>, SysError>;

    /// follow the link and jump until reach the first NOT link Inode or reach the max depth
    pub fn follow(self: Arc<Self>) -> Result<Arc<dyn Dentry>, SysError>;
}
```

相当于在 VFS 层为所有文件系统实现了路径查找的功能，从而大量减少代码量。

=== DCache

`DCACHE`，即 Dentry Cache，专门用于缓存路径，避免发生多次查找重复路径。

```rust
pub static DCACHE: SpinNoIrqLock<BTreeMap<String, Arc<dyn Dentry>>> = 
    SpinNoIrqLock::new(BTreeMap::new());
```

`DCACHE` 将绝对路径与对应的 Dentry 进行映射。每次当我们试图查询路径时，会先试着在 `DCACHE` 中寻找。这个策略可以大大加速一些经常性事件。


=== Inode

在 Chronix 中，Inode 独一无二地映射了一个文件系统的具体资源。以下为 Inode 的基类。

```rust
/// the base Inode of all file system
pub struct InodeInner {
    /// inode number
    pub ino: usize,
    /// super block that owned it
    pub super_block: Option<Weak<dyn SuperBlock>>,
    /// size of the file in bytes
    pub size: AtomicUsize,
    /// link count
    pub nlink: AtomicUsize,
    /// mode of inode
    pub mode: InodeMode,
    /// last access time
    pub atime: SpinNoIrqLock<TimeSpec>,
    /// last modification time
    pub mtime: SpinNoIrqLock<TimeSpec>,
    /// last state change time
    pub ctime: SpinNoIrqLock<TimeSpec>,
}
```

#strong[`InodeInner`] 记录了一个 Inode 的基础信息：
- `ino`：每个 `Inode` 在 Chronix 中都会有一个独一无二的序号。
- `super_blocks`：指向了这个 `Inode` 来源于的超级块
- `size`：对于不同类型的 `Inode`，`size` 有不同的含义，可能是文件的大小，或者是没有作用。
- `nlink`：指向这个 `Inode` 的硬链接的数量。
- `mode`：这个 `Inode` 的类型、访问权限等
- `atime/mtime/ctime`：最后访问/修改/状态改变的时间

注意 `Inode` 的方法（trait）会较多，原因在于我们希望可以更小粒度地控制 `Inode`，并减少 `Dentry` 等层具体实现的代码量。同时兼容更多的文件系统。对于临时文件系统以及磁盘文件系统，会使用到页缓存。如果让每个 `Dentry` 或者 `File` 持有一个页缓存，我们需要处理不一致性的问题，可能涉及分布式的概念，所以这里采取较为简单的方式：即一个 `Inode` 持有一个页缓存。

=== File

```rust
/// basic File object
pub struct FileInner {
    /// the dentry it points to
    pub dentry: Arc<dyn Dentry>,
    /// the current pos 
    pub offset: AtomicUsize,
    /// file flags
    pub flags: SpinNoIrqLock<OpenFlags>,
}
```

`File` 对象，即文件。每一个 File 对应于一个 file discriptor 。注意这里的 `File` 和文件系统的 *文件* 是完全两个概念。在 Chronix 中，File 都是由 Dentry “打开” 而来。`File` 本质是 `Inode` + `Dentry` 在进程中的表示。

==== Fd Table

```rust
/// the fd table
pub struct FdTable {
    /// the inner table
    pub fd_table: Vec<Option<FdInfo>>,
    /// resource limit: max fds
    pub rlimit: RLimit,
}
```

进程会通过 `FdTable` 来管理打开的文件。

```rust
/// fd info
pub struct FdInfo {
    /// the file it points to
    pub file: Arc<dyn File>,
    /// fd flags
    pub flags: FdFlags,
}
```

基本的表项为 `FdInfo`：记录了打开的文件，以及打开的 `FdFlags`。


== 磁盘文件系统

=== EXT4 文件系统

ext4（Fourth Extended Filesystem） 是 Linux 上广泛使用的日志型文件系统，是 ext3 的继任者，目标是提供更好的性能、可靠性和大容量支持。

我们使用了外部库 `lwext4_rust`。Ext4 文件系统对 VFS 的实现，放在了 `fs/ext4` 的文件夹内。从代码量可见：通过 VFS 的抽象，可以大大降低适配一个新的文件系统的心智负担。

- `Ext4SuperBlock`：“继承”了 VFS SuperBlock 的字段，实现了对应的方法，包裹的是 `Ext4BlockWrapper<Disk>`，Disk 为该文件系统使用的块设备。 
- `Ext4Inode`：“继承”了 VFS Inode 的字段，实现对应方法，包裹了 `Ext4File`（lwext4 向上提供的操作内部的Inode的单位），注意 lwext4_rust 提供的 inode 的方法并未将路径解耦。
- `Ext4Dentry`：本质上通过操作 Ext4Inode 来实现目录的操作。
- `Ext4File`: Ext4 实现的 File 对象，注意和 lwext4_rust 向上提供的 Ext4File 并非同一个东西。

为了支持挂载、链接等，我们对 `lwext4_rust` 做了微小的修改。

== 非磁盘文件系统

在传统计算机系统中，文件系统通常用于管理磁盘等持久化存储设备上的数据，如 Ext4、FAT32、NTFS 等。然而，现代操作系统还广泛使用#strong[非磁盘文件系统（Non-Disk File Systems）]，它们并不依赖物理存储介质，而是由内核动态生成，主要用于系统管理、进程间通信（IPC）、设备抽象和运行时信息访问。

与传统的磁盘文件系统相比，非磁盘文件系统具有以下特点：
- _不占用物理存储_：数据通常存储在内存中，或由内核动态生成。
- _动态内容_：文件内容可能随系统状态实时变化。
- _特殊用途_：主要用于系统管理、调试、设备控制和进程间通信，而非持久化存储。
- _高性能_：由于不涉及磁盘 I/O，访问速度极快（如 tmpfs）。

=== tmpfs

在 Chronix 中，临时文件系统（tmp fs） 和共享内存文件系统（shm fs）的文件都只存在于内存中。由于数据直接存储在内存中，读写操作的速度非常快，没有磁盘 I/O 的开销。`tmpfs` 中的数据在系统重启后会被清除，适合存储临时文件、缓存数据等不需要持久化的内容。`shmfs` 提供了进程间共享内存的机制，使得多个进程可以高效地共享数据，避免了数据复制的开销。内存文件系统可以根据实际使用情况动态调整大小，既不会过度占用内存，也能在需要时自动扩展。内存文件系统作为 VFS 的一个具体实现，完全遵循 VFS 的接口规范，这使得用户程序可以像操作普通文件系统一样操作内存文件系统，保持了良好的一致性和易用性。

利用 Chronix 内核中已有的页缓存机制（后文会介绍），可以完美地实现临时文件的读写。

```rust
pub struct TmpInode {
    inner: InodeInner,
    cache: Arc<PageCache>,
}
```

tmpfs 中的文件，真正持有的资源是一个 `TmpInode`。`TmpInode` 除了包含一些基本信息外（`InodeInner`），还持有一个页缓存的指针。当需要读写时，会调用以下两个函数。这两个方法的操作类似，会通过页缓存的映射，找到文件映射的物理内存，并以页为单位进行读写。

```rust
fn cache_read_at(self: Arc<Self>, offset: usize, buf: &mut [u8]) -> Result<usize, i32>;

fn cache_write_at(self: Arc<Self>, offset: usize, buf: &[u8]) -> Result<usize, i32>
```

`tmpfs` 需要支持文件的创建、删除。由于 `tmpfs` 的 `Inode` 只存在于内存中，且只会被 `Dentry` 持有，所以创建比较简单，只需要新建一个 `Dentry` 以及 `Inode` 即可。删除工作会有一些不一样：在 linux 中，一个 `Inode` 被 unlink 时，如果还有其他东西实际持有该 `Inode`（比如说进程的 `fd table`），那这个 `Inode` 就不能被删除。对于 `tmpfs`，为了实现该机制，在用户调用 unlink 来删除 tmpfs 文件时，会将对应的 `Dentry` 设为 Negative，即用户将无法通过目录查找访问到该文件，但这个文件对应的 `Inode` 依旧会被 `Dentry` 持有，从而让其他持有者依然可以对这个文件读写（比如通过 fd）。

在 linux manual 中，有写到：当 Open flags 为 `O_TMPFILE | O_DIRECTORY` 时，实际的操作是在目标的文件夹下，创建匿名文件。在 Chronix 中，以这种标识打开的文件实际不会放在任何文件夹下，而是唯一地被进程的 `fd table` 持有。

共享内存文件系统（简称为 `shmfs`），目前同等视作 `tmpfs`。


===  procfs

procfs（进程文件系统）是类Unix系统（如Linux）中一种特殊的虚拟文件系统，它不占用磁盘空间，而是由内核动态生成，以文件系统的形式向用户空间提供内核和进程信息的接口。它通常挂载在`/proc`目录下，是系统监控、调试和性能分析的重要工具。

在初赛，我们为每一个系统文件都实现了对应的 `File` `Dentry` `Inode` 对象，这种设计带来了大量代码的重复。通过观察可以发现，这类系统文件拥有类似的特点：内容动态生成、只读不写等。我们完全可以复用 `TmpFile` `TmpDentry` 的代码，并实现一个统一的 `Inode`：

```rust
/// special system file: read only
pub struct TmpSysInode {
    inner: InodeInner,
    content: Arc<dyn InodeContent>,
}

pub trait InodeContent {
    fn serialize(&self) -> String;
}
```
我们可以将系统文件的内容抽象成 `InodeContent`，调用其 `serialize` 方法来得到内容转换为的字符串，文件读入则转为为对该动态生成的字符串的读入。

当前进程文件系统支持的文件如下：
- #strong[`/proc/self/exe`]：指向当前进程正在执行的可执行文件的符号链接
- #strong[`/proc/self/fd`]：包含当前进程打开的所有文件描述符的目录
- #strong[`/proc/self/maps`]：展示当前进程的内存映射情况
- #strong[`/proc/cpuinfo`]：显示 CPU 的详细信息，如型号、核数、频率等
- #strong[`/proc/meminfo`]：提供系统内存使用情况的统计数据
- #strong[`/proc/mounts`]：列出当前系统已挂载的所有文件系统
- #strong[`/proc/interrupt`]：显示系统中断及其被各 CPU 处理的次数
- #strong[`/proc/sys/kernel/pid_max`]：定义系统允许的最大进程 ID 值
- #strong[`/proc/sys/kernel/tainted`]：指示内核是否因加载不安全模块或错误而被“污染”
- #strong[`/proc/sys/fs/pipe-max-size`]：设置或显示单个管道可允许的最大容量（字节数）

=== devfs

devfs（设备文件系统）是类Unix系统（如Linux）中用于管理设备文件（Device Files）的一种虚拟文件系统。它动态地在`/dev`目录下创建设备节点，使得用户空间程序可以通过标准的文件操作（如open、read、write）与硬件设备交互。

- #strong[`/dev/cpu_dma_latency`]：用户态程序直接向内核请求更积极的 CPU 功耗状态管理策略，以减少 DMA 传输的延迟。
- #strong[`/dev/null`]：黑洞设备（丢弃所有写入数据）
- #strong[`/dev/rtc`]：实时时钟设备
- #strong[`/dev/tty`]：串口设备
- #strong[`/dev/zero`]：输入输出都为全 0 的设备
- #strong[`/dev/urandom`]：随机数生成器
- #strong[`/dev/loop0`]：回环设备，把一个普通文件当作块设备（block device）来使用，从而可以像对待硬盘分区一样挂载、格式化或读写这个文件。

== 页缓存

在没有页缓存机制之前，用户读写文件，本质是向文件系统提供了一部份内存，请求文件系统将磁盘上的数据填入这些内存，文件系统会通过与磁盘的直接 IO 来读出/写入数据。这样的话，当一个文件需要大量的读写，将会造成大量的 IO，是不可忽视的开销。于是我们需要引入页缓存机制。

#img(
    image("../assets/image/fs/page-cache.svg", width: 70%),
    caption: "磁盘文件系统页缓存"
)

#strong[页缓存]，即 Page Cache，以页为单位，缓存文件内容。当第一次读入文件的时候，系统将会将其放在 Page Cache 指向的内存中，再将这部分内存复制给用户。这样，在第二次需要读写文件的时候，系统可以直接在内存读写，而无需引发 IO，从而减小开销。同时，在用户使用内存映射的 IO（比如 mmap），可以通过将用户对应的虚拟地址空间映射到缓存的内存空间来实现。

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

`PageCache`本质上提供了文件偏移量到缓存页的映射。磁盘文件系统的每个 Inode 都会持有一个 `PageCache`，通过 `PageCache` 完成 cache read/write，Inode 需要自己负责维护 `PageCache` 的状态。在 Inode 析构时，会将所有脏页写回磁盘。

注意磁盘文件系统与非磁盘文件系统的页缓存的区别：前者需要维护数据的一致性。Chronix 采取以下的策略：

- #strong[读的策略]：
    - 读命中：目标页存在于页缓存中，直接读（需要非常小心地维护好 `end` `size` 等字段，否则可能导致读出超过文件范围的内容）
    - 读缺失：若页索引在文件大小内，从磁盘中读出该页。
- #strong[写的策略]：
    - 写命中：目标页存在于页缓存中，直接写（可能需要更新 `end` `size`等）
    - 写缺失：若页索引小于磁盘上该文件大小，需要先从磁盘中读出该页，再在其上修改；若页索引超过磁盘上文件大小，则可以直接创建新的页，并在页缓存层面写。


== 其他数据结构

=== Pipe

管道（Pipe）是一种进程间通信的机制。其可以支持一个进程将数据流输出到另一个进程，或者从另一个进程读取数据流。管道本身可以看成一个 FIFO 的队列，写者（writer）在队尾添加数据，读者（reader）在队头取出数据。用户使用管道时，会向内核发出相关的系统调用，内核会返回两个 file discriber，一个指向写者文件，一个指向读者文件。写者文件只可以写不可读，读者文件反之。当两个进程拥有相同的 fd table 时，就可以“同时”使用这两个 fd。可能一个进程会向写者文件写入数据流，另一个进程可能会从读者文件读出数据流，从而实现进程间数据流的传递。如下图：

#img(
    image("../assets/image/fs/pipe.svg", width: 70%),
    caption: "管道原理"
)