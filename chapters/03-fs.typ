#import "../template.typ": img

= 文件系统

== 虚拟文件系统

虚拟文件系统（Virtual File System，简称 VFS）是内核中负责与各种字符流（如磁盘文件，IO 设备等等）对接，并对外提供操作接口的子系统。它为用户程序提供了一个统一的文件和文件系统操作接口，屏蔽了不同文件系统之间的差异和操作细节。这意味着，用户程序可以使用标准的系统调用，如 `open()`、`read()`、`write()` 来操作文件，而无需关心文件实际存储在哪种类型的文件系统或存储介质上。

Phoenix OS 的虚拟文件系统以 Linux 为师，并充分结合 Rust 语言的特性，从面向对象的角度出发对虚拟文件系统进行了设计和优化。

目前虚拟文件系统包含 `SuperBlock`, `Inode`, `Dentry`, `File`等数据结构。

=== SuperBlock

超级块对象用于存储特定文件系统的信息，通常对应于存放在磁盘特定扇区中的文件系统超级块。超级块是对文件系统的具象，换句话说，一个超级块对应一个文件系统的实例。对于基于磁盘上的文件系统，当文件系统被挂载内核时，内核需要读取文件系统位于磁盘上的超级块，并在内存中构造超级块对象；当文件系统卸载时，需要将超级块对象释放，并将内存中的被修改的数据写回到磁盘。对于并非基于磁盘上的文件系统（如基于内存的文件系统，比如 sysfs），就只需要在内存构造独立的超级块。

超级块由 `SuperBlock` trait 定义，如下：

```rust
pub trait SuperBlock: Send + Sync {
    /// Get metadata of this super block.
    fn meta(&self) -> &SuperBlockMeta;

    /// Get filesystem statistics.
    fn stat_fs(&self) -> SysResult<StatFs>;

    /// Called when VFS is writing out all dirty data associated with a
    /// superblock.
    fn sync_fs(&self, wait: isize) -> SysResult<()>;
}
```

与传统的面向对象编程语言（如 Java 或 C++）不同，Rust 没有内置的类继承机制，而是鼓励使用组合和 trait 来实现代码复用和抽象。如果要模拟继承特性，就需要设计 Meta 结构体来表示对基类的抽象，为了使用继承来简化设计，减少冗余代码，超级块基类对象的设计由 `SuperBlockMeta` 结构体表示。

```rust
pub struct SuperBlockMeta {
    /// Block device that hold this file system.
    pub device: Option<Arc<dyn BlockDevice>>,
    /// File system type.
    pub fs_type: Weak<dyn FileSystemType>,
    /// Root dentry points to the mount point.
    pub root_dentry: Once<Arc<dyn Dentry>>,
}
```

对于具体的文件系统，只需要实现自己的超级块对象，其中包含 `SuperBlockMeta` 的字段，就能完成继承对超级块基类的继承。比如对 FAT32 文件系统，我们只需要构造这样一个 `FatSuperBlock` 对象就能完成对 VFS `SuperBlockMeta` 的继承，同时，只需要为 `FatSuperBlock` 实现 `SuperBlock` trait 就能实现对接口方法的多态行为。这样就能在 Rust 语言中使用面向对象的设计来大大简化具体文件系统与 VFS 层接口对接的代码量。

```rust
pub struct FatSuperBlock {
    meta: SuperBlockMeta,
    fs: Arc<FatFs>,
}
```

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

=== Dentry

目录项是管理文件在目录树中的信息的结构体，是对文件路径的抽象。在文件系统中，以挂载点，即文件系统的根目录为根节点，按照文件夹与下属文件的父子关系逐级向下，形成一个目录树的结构。目录树的每个节点对应一个目录项，每一个目录项都指向一个文件的索引节点。

Dentry 存在的必要性源于 Unix 将文件本身与文件名解耦合的设计，这使得不同的目录项可以指向相同的索引节点（即硬链接）。虽然竞赛规定使用的 FAT32 文件系统在设计上是将路径与文件本身耦合的，这也导致其不支持硬链接技术，因而往届很多作品并没有 Dentry 这个结构，而是将路径解析的功能保存在 Inode 结构体中，这样的做法是针对竞赛的简化，然而，这并不符合 Unix 哲学，这种 VFS 设计并不能扩展到其他文件系统上。而 Phoenix 认为遵守 Unix 设计哲学能有更好的扩展性，因此，Phoenix 选择遵守 Unix 设计规范，将路径与文件本身相分离，形成了 Dentry 和 Inode 这两者的抽象。

目录项与索引节点是多对一的映射关系，因此文件系统只需要缓存目录项就能缓存对应的索引节点。而目录项的状态分为两种，一种是被使用的，即正常指向 Inode 的目录项，一种是负状态，即没有对应 Inode 的目录项。负目录项的存在是因为文件系统试图访问不存在的路径，或者文件被删除了。如果没有负目录项，文件系统会到磁盘上遍历目录结构体并检查这个文件的确不存在，这样的失败查找非常浪费资源，为了尽量减少对磁盘的 IO 访问，Phoenix 的文件系统会缓存这些负目录项，以便快速解析这些路径。

目录项的操作由 `Dentry` trait 描述，定义如下：

```rust
pub trait Dentry: Send + Sync {
    /// Get metadata of this Dentry
    fn meta(&self) -> &DentryMeta;

    /// Open a file associated with the inode that this dentry points to.
    fn base_open(self: Arc<Self>) -> SysResult<Arc<dyn File>>;

    /// Look up in a directory inode and find file with `name`.
    ///
    /// If the named inode does not exist, a negative dentry will be created
    /// as a child and returned. Returning an error code from this routine
    /// must only be done on a real error.
    fn base_lookup(
        self: Arc<Self>,
        name: &str,
    ) -> SysResult<Arc<dyn Dentry>>;

    /// Called by the open(2) and creat(2) system calls. Create an inode for
    /// a dentry in the directory inode.
    ///
    /// If the dentry itself has a negative child with `name`, it will
    /// create an inode for the negative child and return the child.
    fn base_create(
        self: Arc<Self>,
        name: &str,
        mode: InodeMode,
    ) -> SysResult<Arc<dyn Dentry>>;

    /// Called by the unlink(2) system call. Delete a file inode in a
    /// directory inode.
    fn base_unlink(self: Arc<Self>, name: &str) -> SyscallResult;

    /// Called by the rmdir(2) system call. Delete a dir inode in a
    /// directory inode.
    fn base_rmdir(self: Arc<Self>, name: &str) -> SyscallResult;
}
```

目录项对象由 `DentryMeta` 结构体表示：

```rust
pub struct DentryMeta {
    /// Name of this file or directory.
    pub name: String,
    /// Super block this dentry belongs to
    pub super_block: Weak<dyn SuperBlock>,
    /// Parent dentry. `None` if root dentry.
    pub parent: Option<Weak<dyn Dentry>>,
    /// Inode it points to. May be `None`, which is called negative dentry.
    pub inode: Mutex<Option<Arc<dyn Inode>>>,
    /// Children dentries. Key value pair is <name, dentry>.
    pub children: Mutex<BTreeMap<String, Arc<dyn Dentry>>>,
}
```

=== File

文件对象是进程已打开的文件在内存中的表示。文件对象由系统调用 `open()` 创建，由系统调用 `close()` 撤销，所有文件相关的系统调用实际上都是文件对象定义的操作。文件对象与文件系统中的文件并不是一一对应的关系，因为多个进程可能会同时打开同一个文件，也就会创建多个文件对象，但这些文件对象指向的索引节点都是同一个索引节点，即同一个文件。

文件对象的操作由 `File` 描述，其形式如下：

```rust
pub trait File: Send + Sync {
    /// Get metadata of this file
    fn meta(&self) -> &FileMeta;

    /// Called by read(2) and related system calls.
    ///
    /// On success, the number of bytes read is returned (zero indicates 
    /// end of file), and the file position is advanced by this number.
    async fn read(&self, offset: usize, buf: &mut [u8]) -> SyscallResult;

    /// Called by write(2) and related system calls.
    ///
    /// On success, the number of bytes written is returned, and the file
    /// offset is incremented by the number of bytes actually written.
    async fn write(&self, offset: usize, buf: &[u8]) -> SyscallResult;

    /// Read directory entries. This is called by the getdents(2) system 
    /// call.
    ///
    /// For every call, this function will return an valid entry, or an 
    /// error. If it read to the end of directory, it will return an empty
    /// entry.
    fn base_read_dir(&self) -> SysResult<Option<DirEntry>>;

    /// Called by the close(2) system call to flush a file
    fn flush(&self) -> SysResult<usize>;

    /// Called by the ioctl(2) system call.
    fn ioctl(&self, cmd: usize, arg: usize) -> SyscallResult;

    /// Called when a process wants to check if there is activity on this 
    /// file and (optionally) go to sleep until there is activity.
    async fn poll(&self, events: PollEvents) -> SysResult<PollEvents>;

    /// Called when the VFS needs to move the file position index.
    ///
    /// Return the result offset.
    fn seek(&self, pos: SeekFrom) -> SysResult<usize>;
}
```

文件对象的设计由 `FileMeta` 结构体表示，下面给出它的结构和描述：

```rust
pub struct FileMeta {
    /// Dentry which points to this file.
    pub dentry: Arc<dyn Dentry>,
    /// Inode which points to this file
    pub inode: Arc<dyn Inode>,
    /// Offset position of this file.
    pub pos: AtomicUsize,
    /// File mode
    pub flags: Mutex<OpenFlags>,
}
```

=== FileSystemType

`FileSystemType` 用来描述各种特定文件系统类型的功能和行为，并负责管理每种文件系统下的所有文件系统实例以及对应的超级块。

`FileSystemType` trait 的定义如下：

```rust
pub trait FileSystemType: Send + Sync {
    fn meta(&self) -> &FileSystemTypeMeta;

    /// Call when a new instance of this filesystem should be mounted.
    fn base_mount(
        self: Arc<Self>,
        name: &str,
        parent: Option<Arc<dyn Dentry>>,
        flags: MountFlags,
        dev: Option<Arc<dyn BlockDevice>>,
    ) -> SysResult<Arc<dyn Dentry>>;

    /// Call when an instance of this filesystem should be shut down.
    fn kill_sb(&self, sb: Arc<dyn SuperBlock>) -> SysResult<()>;
}
```

`FileSystemType`的设计由 `FileSystemTypeMeta` 结构体表示，下面给出它的结构和描述：

```rust
pub struct FileSystemTypeMeta {
    /// Name of this file system type.
    name: String,
    /// Super blocks.
    supers: Mutex<BTreeMap<String, Arc<dyn SuperBlock>>>,
}
```

=== Path

`Path` 结构体的主要用来实现路径解析，由于我们在 `DentryMeta` 中使用 `BTreeMap` 来对缓存一个文件夹下的所有子目录项，因此我们能够在内存中快速进行路径解析，而无需重复访问磁盘进行耗时的 IO 操作。

```rust
pub struct Path {
    /// The root of the file system
    root: Arc<dyn Dentry>,
    /// The directory to start searching from
    start: Arc<dyn Dentry>,
    /// The path to search for
    path: String,
}
```

由于我们已经通过 Dentry 实现了对目录树的抽象，路径解析的实现非常简单，只需要判断传入路径为绝对路径或相对路径，然后逐级对目录进行查找即可。

```rust
impl Path {
    /// Walk until path has been resolved.
    pub fn walk(&self) -> SysResult<Arc<dyn Dentry>> {
        let path = self.path.as_str();
        let mut dentry = if is_absolute_path(path) {
            self.root.clone()
        } else {
            self.start.clone()
        };
        for p in split_path(path) {
            match p {
                ".." => {
                    dentry = dentry.parent().ok_or(SysError::ENOENT)?;
                }
                name => match dentry.lookup(name) {
                    Ok(sub_dentry) => {
                        dentry = sub_dentry
                    }
                    Err(e) => {
                        return Err(e);
                    }
                },
            }
        }
        Ok(dentry)
    }
}
```

== 磁盘文件系统

=== FAT32 文件系统

FAT32，全称为 File Allocation Table 32，是一种文件系统格式，用于在各种存储设备上存储和管理文件和目录。它是 FAT 文件系统的一个版本，最初由微软在 1996 年引入，主要是为了解决 FAT16 在处理大容量存储设备时的限制问题。FAT32 文件系统在 Windows 操作系统以及许多其他设备和媒体中得到了广泛应用。

作为为 Windows 设计的文件系统，FAT32 并没有采取 UNIX 系列文件系统的设计范式。相比于 UNIX 系列的文件系统，FAT32 缺少 UNIX 规定的 `rwx` 权限管理，也没有提供硬链接功能或可以实现硬链接功能的模块。虽然要使内核支持 FAT32，只需实现对应的 VFS 接口，但是具体实现仍需要采取一些特殊机制。

Phoenix 使用了开源的 `rust-fatfs` 库，并在其基础上添加了多核的支持。通过实现 FAT32 的 VFS 层接口完成了 FAT32 的对接。

=== EXT4 文件系统

Ext4（第四代扩展文件系统）是Ext3文件系统的继承者，主要用于Linux操作系统。与前代文件系统相比，Ext4在性能、可靠性和容量方面都有显著改进。相比于初赛要求的 FAT32 文件系统，Ext4 文件系统对 Unix 操作系统适配性更好，支持硬链接等操作。

Phoenix 使用了开源的 `lwext4-rust` 库，并修改其代码以支持链接功能，以及根据文件偏移获取对应磁盘块号的功能，通过实现 EXT4 的 VFS 层接口完成对接。

== 非磁盘文件系统

在 Phoenix 中，非磁盘文件系统用于指代所有不需要从磁盘上读取数据的文件系统，
包括 procfs, devfs, tmpfs 等。这些文件系统的数据从不落盘，按需从内核中查询。
由于其无需与磁盘交互，因此它们不需要经过常见的为了提高磁盘访问效率而使用的缓存机
制，可以直接实现 VFS 顶层的文件接口，从而减少不必要的性能开销。

===  procfs

procfs 是一种特殊的文件系统，它不是从磁盘上的文件系统中读取数据，而是从内核中
读取数据。Phoenix 的 procfs 包括：
- `/proc/mounts` : 显示当前挂载的文件系统
- `/proc/meminfo` :  提供关于系统内存使用情况的信息，包括总内存、可用内存、缓存和缓冲区等详细数据

=== devfs

devfs 中的文件代表一些具体的设备，比如终端、硬盘等。Phoenix 的 devfs 内包含：
- `/dev/zero` : 一个无限长的全 0 文件
- `/dev/null` : 用于丢弃所有写入的数据，并且读取时会立即返回 EOF（文件结束）
- `/dev/urandom` : 一个伪随机数生成器，提供随机数据流
- `/dev/cpu_dma_latency` : 控制 CPU 的 DMA 延迟设置，用于调整系统性能
- `/dev/rtc` : 实时时钟设备，提供日期和时间
- `/dev/tty` : 终端设备，能支持 ioctl 中的特定命令

=== tmpfs

tmpfs 文件系统中的所有文件和文件夹仅存在于内存中，并在系统重启时被清空。在 Phoenix 系统中，tmpfs 中的文件内容存储在页缓存中，这使得它们与 mmap (内存映射) 无缝集成，提供了高效的文件操作性能。 

== 页缓存与块缓存

为了减少读写磁盘的次数，最大化磁盘IO性能，Phoenix 在 Page 模块中实现了页缓存与块缓存，以及二者的统一。

如@page-buffer-cache 所示，用户程序通过read/write系统调用或mmap对文件进行读写或内存映射操作，由于内存映射操作以页为单位，因此内核总是按页来存储文件内容，也被称为页缓存。Phoenix通过调用外部文件系统库来获取文件内容，外部文件系统库通过调用Phoenix提供的磁盘驱动获取磁盘块的内容。Phoenix在磁盘驱动层实现了块缓存，如@buffer-head，Phoenix 为每个磁盘块维护一个`BufferHead`结构体，每个`BufferHead`结构体不存储实际内容，只存储一些元数据和指向存储实际内容的页的指针。


#img(
  image("../assets/page-buffer-cache.png", width: 60%),
  caption: "Phoenix页缓存与块缓存架构设计"
)<page-buffer-cache>

#img(
  image("../assets/buffer-head.png", width: 90%),
  caption: "Phoenix缓冲头设计"
)<buffer-head>

=== 页缓存

页缓存（Page Cache）以页为单位缓存文件内容。被缓存在页缓存中的文件数据能够更快速地被用户读取。对于带有缓冲的写入操作，数据在写入到页缓存中后即可立即返回，而不需等待数据被实际持久化到磁盘，从而提高了上层应用读写文件的整体性能。

页缓存是连接内存模块与文件系统模块桥梁，以页为单位对文件内容的缓存能够与mmap等页分配加载机制深度融合，使得文件内容在内存中的映射和缓存更加高效。

Phoenix 使用哈希表将文件以页为单位的偏移与缓存页对应起来。`PageCache` 被`InodeMeta` 持有，在文件初次读写时将文件内容从磁盘加载到内存中，并使用`PageCache`结构体统一管理。

```rust
pub struct PageCache {
    /// Map from aligned file offset to page cache.
    pages: SpinNoIrqLock<HashMap<usize, Arc<Page>>>,
}
```

=== 块缓存

磁盘的最小数据单位是扇区（sector），每次读写磁盘都是以扇区为单位进行操作。扇区大小取决于具体的磁盘类型，有的为512字节，有的为4K字节。无论用户希望读取1个字节，还是10个字节，最终访问磁盘时，都必须以扇区为单位读取。如果直接访问裸磁盘，那数据读取的效率会非常低。

同样，如果用户希望向磁盘某个位置写入（更新）1个字节的数据，他也必须刷新整个扇区。言下之意，就是在写入这1个字节之前，我们需要先将该1字节所在的磁盘扇区数据全部读出来，在内存中修改对应的这个字节数据，然后再将整个修改后的扇区数据一口气写入磁盘。

为了降低这种低效访问，尽可能提升磁盘访问性能，Phoenix 实现了块缓存，将频繁访问的磁盘块缓存到内存中，当有数据读取请求时，能够直接从内存中将对应数据读出。当有数据写入时，它可以直接在内存中更新指定部分的数据，然后再通过异步方式，把更新后的数据写回到对应磁盘的扇区中。

QEMU中virtio磁盘块大小为512B，为一页的八分之一。虽然磁盘块的大小通常不等于页大小，但其缓存内容同样存储在页上。Phoenix 使用`BufferCache`结构体对块缓存进行统一管理，并使用LRU算法淘汰最近未访问的块以及存储其内容的页，避免占用过大的内存空间。`BufferHead` 结构体负责存储磁盘块的元信息，包括块偏移、访问次数、块状态，并包括指向实际存储块内容的`Page`结构体指针以及其在页面上的偏移。

```rust
pub struct BufferCache {
    /// Underlying block device.
    device: Option<Weak<dyn BlockDevice>>,
    /// Block page id to `Page`.
    pub pages: LruCache<usize, Arc<Page>>,
    /// Block idx to `BufferHead`.
    pub buffer_heads: LruCache<usize, Arc<BufferHead>>,
}

pub struct BufferHead {
    /// Block index on the device.
    block_id: usize,
    page_link: LinkedListAtomicLink,
    inner: SpinNoIrqLock<BufferHeadInner>,
}

pub struct BufferHeadInner {
    /// Count of access before cached.
    acc_cnt: usize,
    /// Buffer state.
    bstate: BufferState,
    /// Page cache which holds the actual buffer data.
    page: Weak<Page>,
    /// Offset in page, aligned with `BLOCK_SIZE`.
    offset: usize,
}
```

=== 页缓存与块缓存的统一


往届作品中，对于页缓存与块缓存的处理，要么像 Alien 那样不考虑页缓存与块缓存的统一，只是简单粗暴的在驱动层面实现块缓存，在 inode 层面实现页缓存，而这种策略会使得一个文件，可能同时存在页缓存和块缓存，不仅导致数据冗余浪费内存空间，并且无法保证页缓存与块缓存数据的同步性；要么像 Titanix 那样不考虑块缓存，只有文件页缓存，对于磁盘上的非文件的频繁访问的块，比如 FAT32 的 FAT 表所在磁盘块，单独做缓存处理，这种策略的缺点在与要求内核自己实现文件系统，因此不能使用外部库提供的高级抽象。
而 Phoenix 在不自己实现文件系统的情况下将页缓存与块缓存统一了起来，页缓存和块缓存是一个事物的两种表现：对于一个缓存页而言，对上，它是某个文件的一个页缓存，而对下，它同样是一个块设备上的一组块缓存。

页缓存与块缓存统一的难点在于，块设备上的文件是以块为单位存储的，而内核希望按页为单位缓存文件。并且块缓存可以分为两类：基于文件的块缓存和不基于文件的块缓存。基于文件的块缓存以页为粒度进行访问和映射，仅在写回时以块为粒度进行操作； 而不基于文件的块缓存，例如 EXT4 文件系统中的 inode bitmap，我们希望以块为粒度进行访问，但内容仍然需要存储在页上。Phoenix 使用外部文件系统库提供的对文件的高级抽象，导致 Phoenix 无法在第一时间准确分辨一个磁盘块到底是基于文件还是不基于文件的，因此我们没有办法预先根据磁盘块号区域划分这两种块缓存，相反我们实现了对磁盘块的访问计数，并根据计数动态判断磁盘块缓存的种类。

Phoenix 实现块缓存分类的算法是，为磁盘访问计数设置一个阈值，当访问计数超过阈值时，将其视作不基于文件的磁盘块并将其缓存在驱动层。对于基于文件的磁盘块，Phoenix 调用外部库进行处理，而外部库会调用 Phoenix 提供的磁盘驱动对磁盘进行访问，最后外部库返回文件的高级抽象，这时 Phoenix 获取到这个文件后就会立刻将其内容放入页缓存，并调用获取文件偏移对应磁盘块的方法，将对应块号的`BufferHead`链接到页缓存上。由于 Phoenix
在获取文件内容后就立即将对应块识别为基于文件的块，并将其内容存储在页缓存中，因此对该块的访问会通过`BufferHead`直接指向页缓存中，不会访问底层磁盘块。 如@buffer-head 所示。

页缓存与块缓存统一不仅可以减少冗余数据的存在，节省内存空间，也能简化管理逻辑，减少开发和维护的难度。在页缓存存在的情况下，对块的访问可以直接获取对应页上的具体内容，无需对磁盘进行读写操作，在页缓存析构时，再将块内容直接写回磁盘，省去了调用外部文件系统写文件接口的时间。


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

管道 Pipe 是一种基本的进程间通信机制。它允许一个进程将数据流输出到另一个进程。文件系统来实现管道通信，实现方式就是创建一个 FIFO 类型的管道文件，文件内容就是一个缓冲区，同时创建两个文件对象和对应的两个文件描述符。两个文件对象都指向这个管道文件，一个文件负责向管道的缓冲区中写入内容，一个负责从管道的缓冲区中读出内容。

管道文件的数据结构由 `PipeInode` 描述：

```rust
pub struct PipeInode {
    meta: InodeMeta,
    inner: Mutex<PipeInodeInner>,
}

pub struct PipeInodeInner {
    is_write_closed: bool,
    is_read_closed: bool,
    ring_buffer: RingBuffer,
    read_waker: VecDeque<Waker>,
    write_waker: VecDeque<Waker>,
}
```

`PipeInode` 是对 VFS 中 `Inode` 数据结构的一个实现，包含元数据、缓冲区、管道是否关闭等信息。

Phoenix 实现了高效的异步管道，在管道空时读者陷入睡眠，直到被信号打断或被写者唤醒，在管道满时写者陷入睡眠，直到被信号打断或被读者唤醒。

```rust
struct PipeReadPollFuture {
    events: PollEvents,
    pipe: Arc<PipeInode>,
}

impl PipeReadPollFuture {
    fn new(pipe: Arc<PipeInode>, events: PollEvents) -> Self {
        Self { pipe, events }
    }
}

impl Future for PipeReadPollFuture {
    type Output = PollEvents;

    fn poll(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Self::Output> {
        let mut inner = self.pipe.inner.lock();
        let mut res = PollEvents::empty();
        if self.events.contains(PollEvents::IN)
            && !inner.ring_buffer.is_empty()
        {
            res |= PollEvents::IN;
            Poll::Ready(res)
        } else {
            if inner.is_write_closed {
                res |= PollEvents::HUP;
                return Poll::Ready(res);
            }
            inner.read_waker.push_back(cx.waker().clone());
            Poll::Pending
        }
    }
}

#[async_trait]
impl File for PipeReadFile {
    async fn base_read_at(
        &self,
        _offset: usize,
        buf: &mut [u8],
    ) -> SysResult<usize> {
        let pipe = self.inode();
        let events = PollEvents::IN;
        let revents = PipeReadPollFuture::new(pipe.clone(), events).await;
        if revents.contains(PollEvents::HUP) {
            return Ok(0);
        }
        assert!(revents.contains(PollEvents::IN));
        let mut inner = pipe.inner.lock();
        let len = inner.ring_buffer.read(buf);
        if let Some(waker) = inner.write_waker.pop_front() {
            waker.wake();
        }
        return Ok(len);
    }
}
```

