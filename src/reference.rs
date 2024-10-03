use crate::prelude::*;

use ash::*;

#[derive(Clone)]
#[cfg_attr(feature = "debug", derive(Debug))]
pub struct Engine {
    instance:             Instance,
    #[cfg(feature = "debug")]
    debug_utils_loader:   ext::debug_utils::Instance,
    #[cfg(feature = "debug")]
    debug_messenger:      vk::DebugUtilsMessengerEXT,
    logical_device: Device,
    input_buffer:         vk::Buffer,
    output_buffer:        vk::Buffer,
    input_buffer_memory:  vk::DeviceMemory,
    output_buffer_memory: vk::DeviceMemory,
    command_pool:         vk::CommandPool,
}

impl Engine {
    #[cfg(feature = "debug")]
    unsafe extern "system" fn debug_messenger_callback(
        message_severity:    vk::DebugUtilsMessageSeverityFlagsEXT,
        message_type:        vk::DebugUtilsMessageTypeFlagsEXT,
        callback_data:       *const vk::DebugUtilsMessengerCallbackDataEXT<'_>,
        _user_data:          *mut ffi::c_void,
    ) -> vk::Bool32 {
        eprintln!(
            "\x1B[0;1;30;{}m {message_type:?} {message_severity:?} \x1B[0;1m {}: \x1B[0m{}",
            match message_severity {
                vk::DebugUtilsMessageSeverityFlagsEXT::VERBOSE |
                vk::DebugUtilsMessageSeverityFlagsEXT::INFO
                    => 107,
                vk::DebugUtilsMessageSeverityFlagsEXT::WARNING => 103,
                vk::DebugUtilsMessageSeverityFlagsEXT::ERROR |
                _
                    => 101,
            },
            ffi::CStr::from_ptr((*callback_data).p_message_id_name).to_str().unwrap(),
            ffi::CStr::from_ptr((*callback_data).p_message).to_str().unwrap(),
        );
        vk::FALSE
    }

    pub fn new() -> Self {
        let entry = Entry::linked();
        let app_create_info = vk::ApplicationInfo::default()
            .application_name(c"speedo")
            .application_version(vk::make_api_version(0, 0, 1, 0))
            .engine_name(c"speedo")
            .engine_version(vk::make_api_version(0, 0, 1, 0))
            .api_version(
                unsafe { entry.try_enumerate_instance_version() }
                    .unwrap()
                    .unwrap_or(vk::make_api_version(0, 1, 0, 0)), // vk::make_api_version(0, 1, 0, 0) or vk::API_VERSION_1_0
            );
        let required_instance_layer_names = [
            #[cfg(feature = "debug")]
            c"VK_LAYER_KHRONOS_validation".as_ptr(),
        ];
        let required_instance_extension_names = [
            #[cfg(feature = "debug")]
            ext::debug_utils::NAME.as_ptr(),
        ];
        /*let _supported_instance_layer_names = unsafe { entry.enumerate_instance_layer_properties() }
            .unwrap()
            .into_iter()
            .map(|instance_layer_properties| instance_layer_properties.layer_name.as_ptr());
        let _supported_instance_extension_names = unsafe { entry.enumerate_instance_extension_properties(None) }
            .unwrap()
            .into_iter()
            .map(|instance_extension_properties| instance_extension_properties.extension_name.as_ptr());*/
        let instance_create_info = vk::InstanceCreateInfo::default()
            .application_info(&app_create_info)
            .enabled_layer_names(&required_instance_layer_names)
            .enabled_extension_names(&required_instance_extension_names);
        let instance = unsafe { entry.create_instance(&instance_create_info, None) }.unwrap();
        #[cfg(feature = "debug")]
        let debug_messenger_create_info = vk::DebugUtilsMessengerCreateInfoEXT::default()
            .flags(vk::DebugUtilsMessengerCreateFlagsEXT::default())
            .message_severity(
                vk::DebugUtilsMessageSeverityFlagsEXT::VERBOSE |
                vk::DebugUtilsMessageSeverityFlagsEXT::INFO    |
                vk::DebugUtilsMessageSeverityFlagsEXT::WARNING |
                vk::DebugUtilsMessageSeverityFlagsEXT::ERROR
            )
            .message_type(
                vk::DebugUtilsMessageTypeFlagsEXT::GENERAL    |
                vk::DebugUtilsMessageTypeFlagsEXT::VALIDATION |
                vk::DebugUtilsMessageTypeFlagsEXT::PERFORMANCE
            )
            .pfn_user_callback(Some(Self::debug_messenger_callback));
        #[cfg(feature = "debug")]
        let debug_utils_loader = ext::debug_utils::Instance::new(&entry, &instance);
        #[cfg(feature = "debug")]
        let debug_messenger = unsafe { debug_utils_loader.create_debug_utils_messenger(&debug_messenger_create_info, None) }.unwrap();
        let (physical_device, _physical_device_properties, _supported_physical_device_features) = unsafe { instance.enumerate_physical_devices() }
            .unwrap()
            .iter()
            .map(|&physical_device| (
                physical_device,
                unsafe { instance.get_physical_device_properties(physical_device) },
                unsafe { instance.get_physical_device_features(physical_device)   },
            ))
            .max_by_key(|&(_physical_device, physical_device_properties, _physical_device_features)|
                // TODO: Better selector, https://docs.rs/ash/latest/ash/vk/struct.PhysicalDeviceLimits.html
                // https://github.com/adrien-ben/vulkan-tutorial-rs/blob/master/src/main.rs#L432
                match physical_device_properties.device_type {
                    vk::PhysicalDeviceType::INTEGRATED_GPU => 100,
                    vk::PhysicalDeviceType::DISCRETE_GPU   => 10_000,
                    vk::PhysicalDeviceType::VIRTUAL_GPU    => 1_000,
                    vk::PhysicalDeviceType::CPU   |
                    vk::PhysicalDeviceType::OTHER |
                    _
                        => 0,
                } +
                physical_device_properties.limits.max_memory_allocation_count    / 100_000 +
                physical_device_properties.limits.max_compute_shared_memory_size / 1_000
                // physical_device_properties.limits.max_compute_work_group_count
                // physical_device_properties.limits.max_compute_work_group_invocations
                // physical_device_properties.limits.max_compute_work_group_size
            )
            .unwrap();
        let queue_family_index = unsafe { instance.get_physical_device_queue_family_properties(physical_device) }
            .iter()
            .position(|&queue_family_properties|
                queue_family_properties.queue_flags.contains(vk::QueueFlags::COMPUTE)
                // && queue_family_properties.queue_flags.contains(vk::QueueFlags::TRANSFER)
            )
            .unwrap() as u32;
        let queue_create_infos = [
            vk::DeviceQueueCreateInfo::default()
                .queue_family_index(queue_family_index)
                .queue_priorities(&[ 1.0 ]),
        ];
        let required_logical_device_extension_names = [];
        // let _supported_logical_device_extension_names = unsafe { instance.enumerate_device_extension_properties(phyiscal_device) }.unwrap();
        let required_physical_device_features = vk::PhysicalDeviceFeatures::default()
            .logic_op(true)
            .shader_float64(true)
            .shader_int64(true)
            .shader_int16(true);
        let logical_device_create_info = vk::DeviceCreateInfo::default()
            .queue_create_infos(&queue_create_infos)
            .enabled_extension_names(&required_logical_device_extension_names)
            .enabled_features(&required_physical_device_features);
        let logical_device = unsafe { instance.create_device(physical_device, &logical_device_create_info, None) }.unwrap();
        let queue_family_indices = [ queue_family_index ];
        let buffer_create_info = vk::BufferCreateInfo::default()
            .size(16 * mem::size_of::<u32>() as u64)
            .usage(vk::BufferUsageFlags::STORAGE_BUFFER)
            .sharing_mode(vk::SharingMode::EXCLUSIVE)
            .queue_family_indices(&queue_family_indices);
        let input_buffer                      = unsafe { logical_device.create_buffer(&buffer_create_info, None)         }.unwrap();
        let output_buffer                     = unsafe { logical_device.create_buffer(&buffer_create_info, None)         }.unwrap();
        let input_buffer_memory_requirements  = unsafe { logical_device.get_buffer_memory_requirements(input_buffer)     };
        let output_buffer_memory_requirements = unsafe { logical_device.get_buffer_memory_requirements(output_buffer)    };
        let physical_device_memory_properties = unsafe { instance.get_physical_device_memory_properties(physical_device) };
        let physical_device_memory_type_index = physical_device_memory_properties.memory_types
            .iter()
            .position(|&physical_device_memory_type|
                physical_device_memory_type.property_flags.contains(vk::MemoryPropertyFlags::HOST_VISIBLE) &&
                physical_device_memory_type.property_flags.contains(vk::MemoryPropertyFlags::HOST_COHERENT)
            )
            .unwrap() as u32;
        // Assertion not needed because if physical_device_memory_type_index exceeds physical_device_memory_properties.memory_type_count
        // physical_device_memory_type.property_flags will equal vk::MemoryPropertyFlags::empty() and therfore not satisfying the selector condition.
        // assert!(physical_device_memory_properties.memory_type_count >= physical_device_memory_type_index);
        let input_buffer_memory_allocate_info = vk::MemoryAllocateInfo::default()
            .allocation_size(input_buffer_memory_requirements.size)
            .memory_type_index(physical_device_memory_type_index);
        let output_buffer_memory_allocate_info = vk::MemoryAllocateInfo::default()
            .allocation_size(output_buffer_memory_requirements.size)
            .memory_type_index(physical_device_memory_type_index);
        let input_buffer_memory  = unsafe { logical_device.allocate_memory(&input_buffer_memory_allocate_info,  None) }.unwrap();
        let output_buffer_memory = unsafe { logical_device.allocate_memory(&output_buffer_memory_allocate_info, None) }.unwrap();
        unsafe { logical_device.bind_buffer_memory(input_buffer,  input_buffer_memory,  0) }.unwrap();
        unsafe { logical_device.bind_buffer_memory(output_buffer, output_buffer_memory, 0) }.unwrap();
        let compute_shader_module_create_info = vk::ShaderModuleCreateInfo::default().code(&[]);
        let compute_shader_module = unsafe { logical_device.create_shader_module(&compute_shader_module_create_info, None) }.unwrap();
        let descriptor_set_layout_bindings = [
            vk::DescriptorSetLayoutBinding::default()
                .binding(0)
                .descriptor_type(vk::DescriptorType::STORAGE_BUFFER)
                .descriptor_count(1)
                .stage_flags(vk::ShaderStageFlags::COMPUTE),
            vk::DescriptorSetLayoutBinding::default()
                .binding(1)
                .descriptor_type(vk::DescriptorType::STORAGE_BUFFER)
                .descriptor_count(1)
                .stage_flags(vk::ShaderStageFlags::COMPUTE),
        ];
        let descriptor_set_layout_create_info = vk::DescriptorSetLayoutCreateInfo::default().bindings(&descriptor_set_layout_bindings);
        let descriptor_set_layouts            = [ unsafe { logical_device.create_descriptor_set_layout(&descriptor_set_layout_create_info, None) }.unwrap() ];
        let pipeline_layout_create_info       = vk::PipelineLayoutCreateInfo::default().set_layouts(&descriptor_set_layouts);
        let pipeline_layout                   = unsafe { logical_device.create_pipeline_layout(&pipeline_layout_create_info, None) }.unwrap();
        let pipeline_cache_create_info        = vk::PipelineCacheCreateInfo::default();
        let pipeline_cache                    = unsafe { logical_device.create_pipeline_cache(&pipeline_cache_create_info, None) }.unwrap();
        let pipeline_shader_stage_create_info = vk::PipelineShaderStageCreateInfo::default()
            .stage(vk::ShaderStageFlags::COMPUTE)
            .module(compute_shader_module)
            .name(c"main");
        let compute_shader_pipeline_create_infos = [
                vk::ComputePipelineCreateInfo::default()
                    .stage(pipeline_shader_stage_create_info)
                    .layout(pipeline_layout),
        ];
        let _compute_shader_pipeline = unsafe { logical_device.create_compute_pipelines(pipeline_cache, &compute_shader_pipeline_create_infos, None) }
            .unwrap()
            .first()
            .unwrap();

        let command_pool_create_info = vk::CommandPoolCreateInfo::default()
            .flags(vk::CommandPoolCreateFlags::RESET_COMMAND_BUFFER)
            .queue_family_index(queue_family_index);
        let command_pool = unsafe { logical_device.create_command_pool(&command_pool_create_info, None) }.unwrap();
        let command_buffer_allocate_info = vk::CommandBufferAllocateInfo::default()
            .command_pool(command_pool)
            .level(vk::CommandBufferLevel::PRIMARY)
            .command_buffer_count(1);
        let _command_buffers = unsafe { logical_device.allocate_command_buffers(&command_buffer_allocate_info) }.unwrap();

        Self {
            instance,
            #[cfg(feature = "debug")]
            debug_utils_loader,
            #[cfg(feature = "debug")]
            debug_messenger,
            logical_device,
            input_buffer,
            output_buffer,
            input_buffer_memory,
            output_buffer_memory,
            command_pool,
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        unsafe {
            self.logical_device.destroy_command_pool(self.command_pool, None);
            self.logical_device.free_memory(self.output_buffer_memory,  None);
            self.logical_device.free_memory(self.input_buffer_memory,   None);
            self.logical_device.destroy_buffer(self.output_buffer,      None);
            self.logical_device.destroy_buffer(self.input_buffer,       None);
            self.logical_device.destroy_device(None);
            #[cfg(feature = "debug")]
            self.debug_utils_loader.destroy_debug_utils_messenger(self.debug_messenger, None);
            self.instance.destroy_instance(None);
        }
    }
}
