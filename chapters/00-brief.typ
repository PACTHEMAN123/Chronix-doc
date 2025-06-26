#import "../template.typ": img

= 概述

== Chronix 介绍

Chronix 是一款现代化的高性能操作系统，专注于异步并发、高效资源管理和跨平台支持。它采用创新的设计理念，结合了异步无栈协程、多核调度和负载均衡技术，实现了高效的进程管理，同时统一了进程与线程模型，简化了开发者的编程体验。  

在#strong[内存管理]方面，Chronix 采用按需加载、写时复制（Copy-on-Write）、懒分配（Lazy Allocation）等优化策略，并全局使用 SLAB 内存分配器，支持零页分配，以最小化内存开销并提升性能。  

#strong[文件系统]方面，Chronix 提供类 Linux 的虚拟文件系统（VFS）架构，支持路径查找缓存（Path Lookup Cache）和页缓存加速文件读写。同时，它兼容多种文件系统，包括 Ext4、Fat32 等磁盘文件系统，以及内存文件系统（tmpfs）、进程文件系统（procfs）和设备文件系统（devfs），并支持灵活的挂载机制。  

Chronix 提供完整的#strong[信号机制]，支持标准信号和实时信号，允许用户自定义信号处理逻辑，满足不同应用场景的需求。  

在#strong[设备驱动方面]，Chronix 支持硬件中断、MMIO（内存映射 I/O）、PCI 设备驱动以及串口通信，并内置设备树（Device Tree）解析功能，便于硬件资源的动态管理。  

#strong[网络模块]上，Chronix 实现了 TCP/UDP 套接字通信，支持本地回环设备（Loopback），并兼容 IPv4 和 IPv6 协议栈，为现代网络应用提供稳定高效的通信能力。  

此外，Chronix 采用自研#strong[硬件抽象层（HAL）]，使其能够灵活支持多种处理器架构，目前已经适配 RISC-V 和 LoongArch，未来可以扩展到更多平台。  

== Chronix 整体架构

项目结构：

```
.
├── docs                      # 文档相关
├── hal                       # 硬件抽象层
│   └── src                   
│       ├── board             # 硬件信息
│       ├── component
│       │   ├── addr          # 地址抽象
│       │   ├── console       # 调试台
│       │   ├── constant      # 架构相关常量
│       │   ├── entry         # 内核入口函数
│       │   ├── instruction   # 指令抽象
│       │   ├── irq           # 中断抽象
│       │   ├── pagetable     # 页表抽象
│       │   ├── signal        # 信号抽象
│       │   ├── timer         # 时钟抽象
│       │   └── trap          # 陷阱抽象
│       ├── interface
│       └── util
├── mk                        # 构建脚本
├── os
│   ├── cargo
│   └── src
│       ├── devices           # 设备管理
│       ├── drivers           # 驱动管理
│       ├── executor          # 任务执行器
│       ├── fs                # 文件系统
│       ├── ipc               # 进程通信
│       ├── mm                # 内存管理
│       ├── net               # 网络模块
│       ├── processor         # 处理器管理
│       ├── signal            # 信号模块
│       ├── sync              # 同步原语
│       ├── syscall           # 系统调用
│       ├── task              # 任务控制
│       ├── timer             # 计时器模块
│       ├── trap              # 陷阱处理
│       └── utils             # 工具函数
├── scripts                   # 快捷脚本
├── user                      # 用户程序
└── utils                     # 工具 crates
```

#img(
  image("../assets/image/total-arch.svg"),
  caption: "总体架构"
)<Chronix_total_arch>
