= 网络模块
<网络模块>

Chronix的网络模块修改并使用使用了smoltcp库作为对TCP/IP 协议栈支持的工具库，借助smoltcp库的轻量，无需依赖标准库，无操作系统以来，支持异步驱动等优秀性质实现了对Chronix资源受限的，高实时性要求的网络支持。

smoltcp库作为Chronix网络模块的基石，是一个面向嵌入式设备的TCP/IP协议栈库。smoltcp以Rust语言编写，旨在提供高效、可扩展且易于集成的网络堆栈，非常适合资源受限的环境，不依赖于标准库，因此可以在无操作系统的`no_std`中运行。

== 设备层
<数据链路层device设备>

Chronix对多种网络设备提出了统一的抽象`NetDevice` trait，统一的设备层接口以支持多种网络设备并方便与上层基于smoltcp的协议栈层进行交互。

```rust
pub trait NetDevice: Send + Sync + Any {
    // ! smoltcp demands that the device must have below trait
    ///Get a description of device capabilities.
    fn capabilities(&self) -> DeviceCapabilities;
    /// Construct a token pair consisting of one receive token and one transmit token.
    fn receive(&mut self) ->  DevResult<Box<dyn NetBufPtrTrait>>;
    /// Transmits a packet in the buffer to the network, without blocking,
    fn transmit(&mut self, tx_buf: Box<dyn NetBufPtrTrait>) -> DevResult; 
    // ! method in implementing a network device concering buffer management
    /// allocate a tx buffer
    fn alloc_tx_buffer(&mut self, size: usize) -> DevResult<Box<dyn NetBufPtrTrait>>;
    /// recycle buf when rx complete
    fn recycle_rx_buffer(&mut self, rx_buf: Box<dyn NetBufPtrTrait>) -> DevResult;
    /// recycle used tx buffer
    fn recycle_tx_buffer(&mut self) -> DevResult;
    /// ethernet address of the NIC
    fn mac_address(&self) -> EthernetAddress;
}
```

以上代码中，`NetBufPtrTrait`是对网络数据包的抽象，用于描述网络数据包,提供获取，修改数据即其长度的方法：

```rust
pub trait NetBufPtrTrait: Any {
    fn packet(&self) -> &[u8];
    fn packet_mut(&mut self) -> &mut [u8];
    fn packet_len(&self) -> usize;
}
```

针对IO密集型应用，Chronix在设备层设计提供了缓冲层管理，用于管理网络数据包的高效分配和回收，缓冲层的设计参考了smoltcp的缓冲区管理，提供了`NetBuf` ，用于描述网络数据包缓冲区：

```rust
/// A raw buffer struct for network device.
pub struct NetBufPtr {
    // The raw pointer of the original object.
    pub raw_ptr: NonNull<u8>,
    // The pointer to the net buffer.
    buf_ptr: NonNull<u8>,
    len: usize,
}

#[repr(C)]
pub struct NetBuf {
    /// the header part bytes length
    pub header_len: usize,
    /// the packet length
    packet_len: usize,
    /// the whole buffer size
    capacity: usize,
    /// the buffer pointer
    buf_ptr: NonNull<u8>,
    /// the offset to the buffer pool
    pool_offset: usize,
    /// the buffer pool pointer
    pool: Arc<NetBufPool>,
}
```

网络的缓冲层被分为若干预留定长的缓冲块，每个缓冲块接受数据包时记录数据包的包头信息以及数据信息

实现设备层后，Chronix定义NetDeviceWrapper结构体，用于包装设备层，并实现smoltcp的设备层接口：

```rust
impl Device for NetDeviceWrapper {
    type RxToken<'a> = NetRxToken<'a> where Self: 'a;
    type TxToken<'a> = NetTxToken<'a> where Self: 'a;

    fn capabilities(&self) -> DeviceCapabilities {
        self.inner.get_ref().capabilities()
    }
    fn receive(&mut self, _: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        let inner = self.inner.exclusive_access();
        if let Err(e) = inner.recycle_tx_buffer(){
            log::warn!("recycle_tx_buffers failed: {:?}", e);
            return None;
        };
        let rx_buf = match inner.receive(){
            Ok(buf) => buf,
            Err(e) => {
                if !matches!(e, DevError::Again){
                    log::warn!("received failed!, Error: {:?}",e);
                }
                return None;
            }
        };
        Some((NetRxToken(&self.inner, rx_buf), NetTxToken(&self.inner)))
    }
    fn transmit(&mut self, _: Instant) -> Option<Self::TxToken<'_>> {
        let inner = self.inner.exclusive_access();
        match inner.recycle_tx_buffer(){
            Err(e) => {
                log::warn!("[transmit] recycle buffer failed: {:?}",e );
                return None;    
            }
            Ok(_) => {
                Some(NetTxToken(&self.inner))
            },
        }
    }
}
```

== 网络层
<网络层ip>

对于Ip,Chronix基于smoltcp库对Ipv4与Ipv6两种地址进行支持：

```rust
#[derive(Clone, Copy)]
#[repr(C)]
/// IPv4 Address
pub struct SockAddrIn4 {
    /// protocal family (AF_INET)
    pub sin_family: u16,
    /// port number
    pub sin_port: u16,
    /// IPv4 address
    pub sin_addr: Ipv4Address,
    /// padding, pd to sizeof(struct sockaddr_in)
    pub sin_zero: [u8; 8],
}
```

针对POSIX 规范中地址参数的端口为网络字节序,即大端序,而 RISCV 指令集为小端序的冲突，借助smoltcp库的IpEndpoint结构体实现地址的转化:为结构体实现了`From` trait便于这些结构体进行转换。

Ip协议是网络层的核心协议，负责在不同网络之间传输数据包。数据包的接受、处理、发送以及路由处理的逻辑已经由`smoltcp`模块封装好了。

== 传输层
<传输层udp与tcp>

Chronix参考smoltcp库以及Arceos的实现，在 smoltcp 基础协议栈之上重构 UdpSocket 和 TcpSocket 的设计。 Chronix封装提供 send()/recv() 等符合 POSIX 规范的接口，方便依赖传统套接字编程模型的应用，并修改设计若干异步方法，与内核的异步调度器（如 async-executor）无缝集成，使网络 IO 可挂起/唤醒，实现协程化操作。

内核无论协议，均存储`SocketHandle`这一结构实现，借助smoltcp库将网络套接字的管理逻辑与具体的套接字操作分离

```rust
pub struct UdpSocket {
    /// socket handle
    handle: SocketHandle,
    /// local endpoint
    local_endpoint: RwLock<Option<IpListenEndpoint>>,
    /// remote endpoint
    peer_endpoint: RwLock<Option<IpEndpoint>>,
    /// nonblock flag
    nonblock_flag: AtomicBool,
}

/// TCP Socket
pub struct TcpSocket {
    /// socket state
    state: AtomicU8,
    /// socket handle
    handle: UPSafeCell<Option<SocketHandle>>,
    /// local endpoint
    local_endpoint: UPSafeCell<Option<IpEndpoint>>,
    /// remote endpoint
    remote_endpoint: UPSafeCell<Option<IpEndpoint>>,
    /// whether in non=blokcing mode
    nonblock_flag: AtomicBool,
    /// shutdown flag
    shutdown_flag: UPSafeCell<u8>,
}

```

内核中的 UDP Socket 被封装成 UdpSocket 结构体，包含本地端点、远端端点、非阻塞标志等信息。TCP Socket 被封装成 TcpSocket 结构体，包含状态、套接字句柄、本地端点、远端端点、非阻塞标志、关闭标志等信息。

针对以上套接字结构体，Chronix再次包装以上套接字结构体为`Sock`以方便统一管理,并进一步提供用户态套接字结构并实现Chronix的File trait 以支持异步读写操作以及异步轮询等操作：

```rust
/// socket for user space,Related to network protocols and communication modes
pub struct Socket {
    /// sockets inner
    pub sk: Sock,
    /// socket type
    pub sk_type: SocketType,
    /// fd flags
    pub file_inner: FileInner,
}

#[async_trait]
impl File for Socket {
    #[doc ="get basic File object"]
    fn file_inner(&self) ->  &FileInner {
        &self.file_inner
    }

    #[doc = " If readable"]
    fn readable(&self) -> bool {
        true
    }

    #[doc = " If writable"]
    fn writable(&self) -> bool {
        true
    }

    #[doc ="Read file to `UserBuffer`"]
    #[must_use]
    async fn read(&self, buf: &mut [u8]) -> Result<usize, SysError> {
        log::info!("[Socket::read] buf len:{}", buf.len());
        if buf.len() == 0 {
            return Ok(0);
        }
        let bytes = self.sk.recv(buf).await.map(|e|e.0).unwrap();
        Ok(bytes)
    }

    #[doc = " Write `UserBuffer` to file"]
    #[must_use]
    async fn write(& self, buf: &[u8]) -> Result<usize, SysError> {
        if buf.len() == 0 {
            return Ok(0);
        }
        let bytes = self.sk.send(buf, None).await.unwrap();
        Ok(bytes)
    }

    async fn base_poll(&self, events:PollEvents) -> PollEvents {
        let mut res = PollEvents::empty();
        poll_interfaces();
        let netstate = self.sk.poll().await;
        if events.contains(PollEvents::IN) && netstate.readable {
            res |= PollEvents::IN;
        }
        if events.contains(PollEvents::OUT) && netstate.writable {
            res |= PollEvents::OUT;
        }
        if netstate.hangup {
            log::warn!("[Socket::bask_poll] PollEvents is hangup");
            res |= PollEvents::HUP;
        }
        // log::info!("[Socket::base_poll] ret events:{res:?} {netstate:?}");
        res
    }
}
```

Chronix借助smoltcp 在基于轮询的网络支持方面，通过主动轮询（poll） 作为核心工作模式，而非依赖中断或线程调度。用户层通过系统调用主动调用 smoltcp 的轮询函数（如 poll），驱动协议栈处理以下任务：

- 检查网络接口：遍历接收缓冲区，解析传入的 Ethernet/IP 帧
- 处理协议状态机：更新 TCP 连接状态（握手、数据传输、挥手）、处理 ARP/ICMP 请求等
- 触发事件回调：如收到新数据时调用用户注册的 recv 回调函数，

借助这种设计，Chronix避免了复杂的中断管理和上下文切换，符合实时系统对确定性响应时间的要求。