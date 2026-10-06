# frozen_string_literal: true

class Prog::LearnGpuPartitions < Prog::Base
  subject_is :sshable, :vm_host

  # Hosts whose GPUs are connected by NVSwitches give VMs groups of GPUs
  # connected by NVLink as partitions, managed by NVIDIA's Fabric Manager
  # with its fmpm client. Record the partitions it offers, with their GPUs,
  # so that the allocator assigns a partition to VMs with GPUs on the host.
  label def start
    if sshable.cmd("test -x /usr/bin/fmpm && echo present || echo absent").strip == "present"
      gpus_by_slot = vm_host.pci_devices_dataset.where(device_class: ["0300", "0302"]).to_hash(:slot)
      gpus_by_module_id = gpu_slots_by_module_id.transform_values { gpus_by_slot[it] }

      DB.transaction do
        sshable.cmd_json("/usr/bin/fmpm -l").fetch("partitionInfo").each do |partition|
          partition_id = partition.fetch("partitionId")

          # Fabric Manager identifies the GPUs of a partition by their
          # physical ID, which is their module ID. It gives no PCI bus IDs.
          gpus = partition.fetch("gpuInfo").map do |gpu|
            physical_id = gpu.fetch("physicalId")
            gpus_by_module_id[physical_id] || fail("BUG: no GPU with module ID #{physical_id} for GPU partition #{partition_id}")
          end
          fail "BUG: GPU partition #{partition_id} has #{gpus.size} GPUs, expected #{partition.fetch("numGpus")}" unless gpus.size == partition.fetch("numGpus")

          gpu_partition_id = GpuPartition.dataset
            .insert_conflict(target: [:vm_host_id, :partition_id], update: {gpu_count: Sequel[:excluded][:gpu_count]})
            .returning(:id)
            .insert(vm_host_id: vm_host.id, partition_id:, gpu_count: gpus.size)
            .first[:id]
          DB[:gpu_partitions_pci_devices].insert_conflict.import([:gpu_partition_id, :pci_device_id], gpus.map { [gpu_partition_id, it.id] })
        end
      end
    end

    pop "learned GPU partitions"
  end

  # Maps the module ID of each GPU bound to the NVIDIA driver to its PCI slot.
  # nvidia-smi gives the PCI bus ID with its domain, such as
  # "00000000:12:00.0", but PciDevice#slot has none, as in "12:00.0".
  def gpu_slots_by_module_id
    sshable.cmd("nvidia-smi -q").split(/^GPU /).drop(1).to_h do |gpu|
      slot = gpu[/^\s*Bus Id\s*:\s*\h+:(\h{2}:\h{2}\.\h)\s*$/, 1]&.downcase
      module_id = gpu[/^\s*Module Id\s*:\s*(\d+)\s*$/, 1]
      fail "BUG: no PCI bus ID and module ID in nvidia-smi output for GPU #{gpu.lines.first.strip}" unless slot && module_id

      [Integer(module_id), slot]
    end
  end
end
