= 设备驱动
<设备驱动>

外设管理模块在操作系统中具有至关重要的作用。其主要目的是管理和协调系统中的各种外设（外部设备），确保它们能够高效、稳定地运行。外设管理模块包括设备的发现、初始化、驱动程序加载以及中断处理等功能。这些功能的实现直接影响到整个系统的性能和稳定性。

Phoenix目前支持块设备(Block Device)、网络设备(Network
Device)，串口(Char Device)和平台级中断控制器(PLIC)，参考了去年二等奖参赛作品MankorOs的`DeviceManger`设计。

```rust
/// The DeviceManager struct is responsible for managing the devices within
/// the system. It handles the initialization, probing, and interrupt
/// management for various devices.
pub struct DeviceManager {
    /// PLIC (Platform-Level Interrupt Controller) to manage external
    /// interrupts.
    pub plic: Option<PLIC>,
    /// Vector containing CPU instances.
    pub cpus: Vec<CPU>,
    /// A BTreeMap that maps device IDs (DevId) to device instances.
    pub devices: BTreeMap<DevId, Arc<dyn Device>>,
    /// A BTreeMap that maps interrupt numbers to device instances
    pub irq_map: BTreeMap<usize, Arc<dyn Device>>,
}
```

使用 `Option<PLIC>` 是为了在设备树中检测到 `PLIC`
后再进行初始化。如果设备树中没有 `PLIC` 的相关信息，这个字段可以保持为
`None`，避免不必要的初始化。`devices`字段维护一个设备 ID (`DevId`)
到设备对象 (`Arc<dyn Device>`)
的映射，提供一个高效的设备管理结构，支持设备的动态添加和查找。

== 设备树
<设备树-1>

操作系统内核获取到设备树的地址的流程如下：

+ OpenSBI启动：当系统启动时，OpenSBI
  固件首先运行。它完成基础的硬件初始化，如内存控制器设置、I/O 初始化等。

+ 传递控制权到内核：OpenSBI
  初始化完成后，将控制权传递给内核的入口点，并传递必要的参数。这些参数包括：

  - `hart_id`：当前硬件线程的 ID。
  - `dtb_addr`：设备树地址，该地址指向设备树描述符（DTB），描述了系统的硬件布局和配置信息。

  在Phoenix中，内核的入口点是`_start`函数，其定义如下：

  ```rust
#[naked]
#[no_mangle]
#[link_section = ".text.entry"]
unsafe extern "C" fn _start(hart_id: usize, dtb_addr: usize) -> ! {
    core::arch::asm!(
        // 1. set boot stack
        ...
        // 2. enable sv39 page table
        ...
        // 3. jump to rust_main
        "
           ...
           la      a2, rust_main
           or      a2, a2, t2
           jalr    a2                      // call rust_main
        "
        ...
    )
}
  ```

  这里的 `jalr a2` 指令将跳转到 `rust_main` 并传递参数。由于 `hart_id`
  和 `dtb_addr` 保持在寄存器 `a0` 和 `a1` 中，这些参数在跳转到
  `rust_main` 时依然有效。

+ 传入`rust_main`内核主函数：

  ```rust
  #[no_mangle]
  fn rust_main(hart_id: usize, dtb_addr: usize) {
      if FIRST_HART
          .compare_exchange(true, false, 
              Ordering::SeqCst, Ordering::SeqCst)
          .is_ok()
      {
          ...
          hart::init(hart_id);
          config::mm::set_dtb_addr(dtb_addr);
          ...
      } else {
          ...
      }
      ...
  }
  ```

  内核中就的其他代码可以得到`dtb_addr`的值了

`DeviceManager`实现了`probe`方法，利用`fdt` crate解析设备树

```rust
pub fn probe(&mut self) {
    let device_tree = unsafe {
        fdt::Fdt::from_ptr(K_SEG_DTB_BEG as _).expect("Parse DTB failed")
    };
    self.probe_plic(&device_tree);
    self.probe_char_device(&device_tree);
    self.probe_cpu(&device_tree);
    self.probe_virtio_device(&device_tree);
    // Add to interrupt map if have interrupts
    for dev in self.devices.values() {
        if let Some(irq) = dev.irq_no() {
            self.irq_map.insert(irq, dev.clone());
        }
    }
}
```

通过设备树解析，Phoenix 可以实现同一份内核二进制在不同的硬件上启动。
