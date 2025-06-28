= 设备驱动
<设备驱动>

外设管理模块主要负责外设的识别、配置、驱动和中断分发等功能，对操作系统至关重要。

Chronix目前支持MMIO和PCI-E总线的块设备(Block Device)、网络设备(Network
Device)，串口(Char Device)和平台级中断控制器(PLIC/Platic)，参考了去年二等奖参赛作品MankorOs的`DeviceManger`设计。

```rust
/// Chronix's device manager
/// responsible for:
/// Creates device instance from device tree,
/// Maintains device instances lifetimes
/// Mapping interrupt No to device
pub struct DeviceManager {    
    /// Optional interrupt controller
    pub irq_ctrl: Option<IrqCtrl>,
    /// Optional PCI
    pub pci: Option<PciManager>,
    /// Optional MMIO
    pub mmio: Option<MmioManager>,
    /// mapping from device id to device instance
    pub devices: BTreeMap<DevId, Arc<dyn Device>>,
    /// mapping from irq no to device instance
    pub irq_map: BTreeMap<IrqNo, Arc<dyn Device>>
}
```

`irq_ctrl`字段维护了一个中断控制器，它由HAL提供，在RISC-V上是PLIC，在龙芯上就是Platic。

以下是两个平台的中断控制器，通过设备树进行初始化代码：
```rust
/// Loongarch: find and init Platic
fn from_dt(root: &Fdt, mmio: impl MmioMapperHal) -> Option<Self> {
    let platic = root.find_compatible(&["loongson,pch-pic-1.0"])?;
    let cpu_cnt = root.find_all_nodes("/cpus/cpu").count();
    log::info!("[IrqCtrl::from_dt] cpu count: {cpu_cnt}");
    Eiointc::init(cpu_cnt);
    let platic_region = platic.reg()?.next()?;
    let start = platic_region.starting_address as usize;
    let size = platic_region.size?;
    let vregion = mmio.map_mmio_area(start..start+size);
    let platic = Platic::new(vregion.start);
    platic.write_w(Platic::INT_POLARITY, 0x0);
    platic.write_w(Platic::INT_POLARITY + 4, 0x0);
    platic.write_w(Platic::INTEDGE, 0x0);
    platic.write_w(Platic::INTEDGE + 4, 0x0);
    Some(Self { platic })
}

/// Riscv: find and init PLIC
fn from_dt(device_tree: &fdt::Fdt, mmio: impl MmioMapperHal) -> Option<Self> {
    let plic_node = device_tree.find_compatible(&["riscv,plic0", "sifive,plic-1.0.0"])?;
    let plic_reg = plic_node.reg().unwrap().next().unwrap();
    let mmio_base = plic_reg.starting_address as usize;
    let mmio_size = plic_reg.size.unwrap();
    log::info!("plic base_address:{mmio_base:#x}, size:{mmio_size:#x}");
    let mmio_vbase = mmio.map_mmio_area(mmio_base..mmio_base+mmio_size).start;
    Some(Self { plic: PLIC::new(mmio_base, mmio_size, mmio_vbase) })
}
```


`pci`字段和`mmio`字段分别维护了PCI-E总线和MMIO总线的总线管理器，它实现了各自总线的设备遍历和配置的逻辑。
以下是遍历两条总线的代码：
```rust
for mut device in pci.enumerate_devices() {
    let dev_class: PciDeviceClass = device.func_info.class.into();
    let dev = match dev_class {
        PciDeviceClass::MassStorageContorller => {
            pci.init_device(&mut device).unwrap();
            Arc::new(VirtIOPCIBlock::new(device))
        }
        _ => continue
    };
    // todo: map irq number and add device
}

for deivce in mmio.enumerate_devices() {
    if let Ok(mmio_transport) = deivce.transport() {
        let dev = match mmio_transport.device_type() {
            virtio_drivers::transport::DeviceType::Block => {
                Arc::new(VirtIOMMIOBlock::new(deivce.clone(), mmio_transport))
            }
            _ => continue
        };
        // todo: map irq number and add device
    }
}
```

`devices`字段维护一个设备 ID (`DevId`)
到设备对象 (`Arc<dyn Device>`)
的映射，提供一个高效的设备管理结构，支持设备的动态添加和查找。

== 设备树
<设备树-1>

HAL封装了获取设备树地址的功能。例如RISC-V平台上，由SBI在启动阶段时在a2传入设备树地址，在龙芯平台上，则是由固件提供。除了这些方法，
还可以将编译好的设备树文件打包到内核的二进制镜像中。HAL隐藏了这些细节，操作系统内核直接通过HAL提供的函数获取到设备树的地址。

以下是通过设备树初始化外设的代码示例：
```rust
pub fn init() {
    let device_tree_addr = hal::get_device_tree_addr();
    log::info!("get device tree addr: {:#x}", device_tree_addr);
    
    let device_tree = unsafe {
        fdt::Fdt::from_ptr(device_tree_addr as _).expect("parse DTB failed!")
    };

    if let Some(bootargs) = device_tree.chosen().bootargs() {
        println!("Bootargs: {:?}", bootargs);
    }

    // find all devices
    DEVICE_MANAGER.lock().map_devices(&device_tree);

    // map the mmap area
    DEVICE_MANAGER.lock().map_mmio_area();

    // init devices
    DEVICE_MANAGER.lock().init_devices();

    // enable irq
    DEVICE_MANAGER.lock().enable_irq();
    log::info!("External interrupts enabled");
}
```
