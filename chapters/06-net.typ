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

Chronix参考smoltcp库以及Arceos的实现，在 smoltcp 基础协议栈之上重构，完成对 UdpSocket ,TcpSocket和 RawSocket 的设计与支持。 Chronix封装提供 send()/recv() 等符合 POSIX 规范的接口，方便依赖传统套接字编程模型的应用，并修改设计若干异步方法，与内核的异步调度器（如 async-executor）无缝集成，使网络 IO 可挂起/唤醒，实现协程化操作。

内核无论协议，均存储`SocketHandle`这一结构实现，提供了一个间接访问实际套接字对象的方式，借助smoltcp库将网络套接字的管理逻辑与具体的套接字操作分离，只  需处理与套接字管理相关的逻辑,而不需关心具体的实现细节。

=== `udp`

内核中Udp结构除了socket handle外还储存了本地地址local_addr和远端地址peer_addr，用于记录发送者和接收者的地址信息， 并用RwLock提供读写保护，nonblock指示是否阻塞
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
```
=== `tcp`

```rust
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
TCP 被封装成 TcpSocket 结构体，包含状态、套接字句柄、本地端点、远端端点、非阻塞标志、关闭标志等信息。对于TCP三次握手的状态， 采用了严格的状态管理与更新方法保证操作原子性。

```rust
pub fn update_state<F, T>(&self, expect_state: SocketState, new_state: SocketState, f: F) -> Result<SockResult<T>, u8>
    where
        F: FnOnce() -> SockResult<T>,
    {
        match self.state
        .compare_exchange(expect_state as u8, SocketState::Busy as u8, Ordering::Acquire, Ordering::Acquire)
        {
            Ok(_) => {
                let res = f();
                if res.is_ok() {
                    self.set_state(new_state as u8);
                }else {
                    self.set_state(expect_state as u8);
                }
                Ok(res)
            }
            Err(actual_state) => {Err(actual_state as u8)}
        }
    }
```

=== `raw`

RawSocket管理只需管理SocketHandle与Protocal即可，但是由于smoltcp库的设计，smoltcp 的 RawSocket 主要设计用于接收特定协议的包。其`send_slice`方法不接受目标地址，这使得直接用它来实现`sendto` 要针对歇息对数据包进行额外的封装：

```rust
    // sendto
    // ep 是目标 IP 地址（Endpoint）
    // 构造 IPv4 头
    let mut ipv4_header = [0u8; 20];
    ipv4_header[0] = (4 << 4) | 5; // 版本(4) + 首部长度(5*4=20字节)
    ipv4_header[1] = 0; // TOS
    let total_len = (ipv4_header.len() + data.len()) as u16;
    ipv4_header[2..4].copy_from_slice(&total_len.to_be_bytes());
    ipv4_header[4..6].copy_from_slice(&0u16.to_be_bytes()); // ID
    ipv4_header[6..8].copy_from_slice(&0u16.to_be_bytes()); // Flags+Frag offset
    ipv4_header[8] = 64; // TTL
    ipv4_header[9] = 1; // Protocol: ICMP
    ipv4_header[12..16].copy_from_slice(&src_ip.octets());
    ipv4_header[16..20].copy_from_slice(&dst_ip.octets());
    // 计算 IPv4 头校验和
    let checksum = ipv4_checksum(&ipv4_header);
    ipv4_header[10..12].copy_from_slice(&checksum.to_be_bytes());
```

=== 套接字API

为了统一不同协议套接字， Chronix再次对其封装，提供统一的套接字接口：

```rs
pub enum Sock {
    TCP(TcpSocket),
    UDP(UdpSocket),
    Unix(UnixSocket),
    SocketPair(SocketPairConnection),
    Raw(RawSocket),
}
```

并进一步提供用户态套接字结构`Socket`,相较于Sock添加了不同的`socket_option`选项基于不同套接字不同的特性， 这些特性将通过setsockopt()设置，并通过getsockopt()获取。

```rust
/// socket for user space,Related to network protocols and communication modes
pub struct Socket {
    /// sockets inner
    pub sk: Sock,
    /// socket type
    pub sk_type: SocketType,
    /// domain
    pub domain: SaFamily,
    /// fd flags
    pub file_inner: FileInner,
    /// some socket options
    /// send_buf_size
    pub send_buf_size: AtomicUsize,
    /// recv_buf_size
    pub recv_buf_size: AtomicUsize,
    /// congestion flag
    pub congestion:  SpinNoIrqLock<String>,
    /// socketopt dout route flag
    pub dont_route: bool,
    /// socketopt version
    pub packet_version: AtomicU32,
    // !member concerning af_alg
    /// whether af_alg or not 
    pub is_af_alg: AtomicBool,
    /// socket_af_alg addr
    pub socket_af_alg: SpinNoIrqLock<Option<SockAddrAlg>>,
    /// raw alg_cipertext
    pub ciphertext: SpinNoIrqLock<Option<Vec<u8>>>,
    /// key context
    pub alg_instance: SpinNoIrqLock<Option<AlgInstance>>
}

```

Socket将实现Chronix的File trait 以支持异步读写操作以及异步轮询等操作,以统一的方式进行读写和管理：

```rust
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


=== ipc相关

在 Linux 中，网络与进程通信（IPC）的结合是构建分布式系统和微服务架构的关键。通过将进程间通信机制与网络协议相融合，我们可以让原本在同一台机器上的进程，像通过网络连接一样进行通信，甚至可以无缝地扩展到不同的机器上。这种结合让系统设计更加灵活，带来了许多独特的优势。

Chronix实现了`SocketPair`用于进程间通信，Socketpair是一种半双工通信方式，允许两个进程之间双向通信，就像双向管道一样。Chronix的Socketpair实现了POSIX标准的接口，包括`socketpair()`，`send()`、`recv()`等。


==== socketpair 相关数据结构

1. #strong[BufferEndpoint]: 此结构体表示一个单向通信通道。它包含一个用于数据存储的 RingBuffer 和两个 Waker 队列（`read_wakers` 和`write_wakers`）。Waker 是异步逻辑的核心。当一个进程尝试从空缓冲区读取数据或向满缓冲区写入数据时，其 Waker 会被注册到相应的队列中。当对等进程写入数据或读取数据时，它会通过调用 waker.wake() 来“唤醒”等待的进程，使其恢复操作。

2. #strong[SocketPairMeta]: 此结构体将两个`BufferEndpoint` 组合起来，创建一个双向通道。`end1` 是用于从第一个套接字流向第二个套接字的数据的缓冲区，`end2` 是用于反向传输的缓冲区。`end1_closed` 和 `end2_closed` 标志对于处理连接状态至关重要，尤其是在一端或两端都关闭的情况下。

3.#strong[SocketPairConnection]: 此结构体表示套接字对的单端（或“句柄”）。它保存对共享 `SocketPairInternal`(对SocketPair的包装) 的引用 (Arc) 和一个布尔标志 (is_first_end)，用于区分自身与对端。它负责提供用户级应用程序将调用的面向公众的 send、recv 和 poll 方法。

==== `socketpair` 收发逻辑

`SocketPairWriteFuture` 和 `SocketPairReadFuture`这两个结构体是Chronix异步读写通信中的核心，它们代表了 “等待数据可读” 和 “等待数据可写” 的状态，并与底层的环形缓冲区和 Waker 机制紧密配合，实现了非阻塞、高效的进程间通信。

1. `SocketPairReadFuture`：异步等待可读数据,当调用 recv 方法时，如果缓冲区里没有数据，就让当前任务（Task）进入睡眠，直到有数据可读为止。当对端（即 `SocketPairWriteFuture`）成功写入数据后，它会调用 read_wakers.pop_front().wake()唤醒之前注册的 Waker，重新调度这个任务。任务被唤醒后，poll 方法会再次被调用，此时缓冲区中已经有了数据，poll 就会返回 Poll::Ready(PollEvents::IN)，recv 协程就能继续执行，从缓冲区中把数据读走。

```rust
fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut meta = self.internal.meta.lock();
        let (read_endpoint, other_end_closed_mutex) = if self.is_first_end {
            (&meta.end2, &meta.end2_closed)
        } else {
            (&meta.end1, &meta.end1_closed)
        };
        let mut read_buffer = read_endpoint.buffer.lock();

        if !read_buffer.is_empty() {
            return Poll::Ready(PollEvents::IN);
        }
        if *other_end_closed_mutex {
            // The peer is closed and the buffer is empty, triggering HUP
            return Poll::Ready(PollEvents::HUP);
        }
        
        // The buffer is empty and the peer is not closed, register waker and wait
        read_endpoint.read_wakers.lock().push_back(cx.waker().clone());
        Poll::Pending
    }
```

2. `SocketPairWriteFuture`：异步等待可写空间.这个 Future 的任务与之相反：当调用 send 方法时，如果缓冲区已满，就让当前任务进入睡眠，直到有可写空间为止。当对端（即`SocketPairReadFuture`）成功从缓冲区中读取了数据后，它会调用 writer_waker.pop_front().wake()。任务被唤醒后，poll 方法会再次被调用。此时缓冲区中已经有了空间，poll 就会返回 Poll::Ready(PollEvents::OUT)，send 协程就能继续执行，将数据写入缓冲区。

```rust
fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        let mut meta = self.internal.meta.lock();
        let (write_endpoint, peer_closed) = if self.is_first_end {
            (&meta.end1, meta.end2_closed)
        } else {
            (&meta.end2, meta.end1_closed)
        };

        if peer_closed {
            // 写端对端已关闭 => 写将失败（EPIPE），poll 语义为 ERR
            return Poll::Ready(PollEvents::ERR);
        }

        let mut write_buf = write_endpoint.buffer.lock();
        if !write_buf.is_full() {
            return Poll::Ready(PollEvents::OUT);
        }

        // 缓冲区已满且对端未关，登记写 waker
        write_endpoint.write_wakers.lock().push_back(cx.waker().clone());
        Poll::Pending
    }
```
