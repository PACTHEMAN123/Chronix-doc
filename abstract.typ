#import "template.typ": img, tbl

#strong[Chronix] 是一个使用 Rust 实现、支持 RISCV-64 和 Loongarch-64 硬件平台的*多核宏内核操作系统*。“Chron” 源自希腊语 “χρόνος”（chronos），意为 “时间”。代表了我们的 OS 具有优异的实时性、强悍的性能。后缀“-ix”致敬类 Unix 系统，代表了我们的 OS 具有兼容性以及开源属性。

截至6月29日23点，Chronix 已经通过初赛的大部分测试点，并在实时排行榜上位于前列：

#img(
    image("assets/leader-board-6-30.png", width: 90%),
    caption: "6-30 排行榜情况"
)

#img(
    image("assets/leader-board-rank-6-30.png", width: 90%),
    caption: "6-30 排行榜分数"
)

Chronix 各个模块完成情况如下表：

#tbl(
    table(
        columns: (20%, auto),
        inset: 12pt,
        align: horizon,
        [模块], [完成情况],
        [进程管理], [异步无栈协程、多核调度、负载均衡。统一进程/线程模型、更小粒度的任务设置],
        [内存管理], [内核空间动态映射、应用加载按需读取、写时复制、懒分配、全局使用 SLAB 内存分配器、支持零页分配、用户指针检查、动态链接、共享内存映射],
        [文件系统], [类 Linux 的虚拟文件系统、路径查找缓存、文件读写使用页缓存加速、支持挂载、支持 Ext4、Fat32 磁盘文件系统，内存文件系统、进程文件系统、设备文件系统],
        [信号机制], [支持标准信号与实时信号的不同等待机制、支持用户自定义信号处理、进程间信号],
        [设备驱动], [支持硬件中断、MMIO 驱动、PCI 驱动、串口驱动。支持设备树解析],
        [网络模块], [支持 TCP UDP 套接字、支持本地回环设备、支持 IPv4、IPv6 协议],
        [架构管理], [自研硬件抽象层、支持 Risc-V、Loongarch 双架构]
    ),
    caption: "模块完成情况"
)
