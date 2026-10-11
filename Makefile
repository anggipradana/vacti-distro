# vacti-distro build orchestration (STUB - Phase-1 targets not yet implemented)
#
# One source tree (distro/) feeds all forms:
#   - cloud / vmware-ova / vbox-ova : golden-image + convert fan-out (distro/golden-image)
#   - iso                           : Debian live-build + Calamares   (distro/live-build-config)
#
# All packaging uses open-source tools (libguestfs/virt-customize, qemu-img,
# genisoimage, tar). ovftool / VBoxManage are dev-box-only.

.PHONY: all iso cloud vmware-ova vbox-ova golden seed clean help

help:
	@echo "vacti-distro targets:"
	@echo "  make golden      - build the golden Debian genericcloud qcow2 (virt-customize)"
	@echo "  make cloud       - golden -> cloud qcow2 + raw.gz"
	@echo "  make vmware-ova  - golden -> streamOptimized VMDK -> OVF(vmx-13) -> .ova"
	@echo "  make vbox-ova    - golden -> VMDK -> OVF(virtualbox-2.2) -> .ova"
	@echo "  make iso         - live-build + Calamares hybrid ISO (GUI + headless SKUs)"
	@echo "  make seed        - build a NoCloud cidata.iso from a filled template"
	@echo "  make all         - golden + cloud + both OVAs + iso"
	@echo "  make clean       - remove build working trees and artifacts"

golden:
	@echo "TODO Phase-1: fetch+verify Debian 13 genericcloud qcow2, virt-customize the golden disk"

cloud: golden
	@echo "TODO Phase-1: qemu-img convert golden -> cloud qcow2 + raw.gz"

vmware-ova: golden
	@echo "TODO Phase-1: qemu-img -O vmdk streamOptimized -> OVF(vmx-13) + .mf + tar -> .ova"

vbox-ova: golden
	@echo "TODO Phase-1: qemu-img -O vmdk -> OVF(virtualbox-2.2) + .mf + tar -> .ova"

iso:
	@echo "TODO Phase-1: lb config + lb build (GUI + headless SKUs)"

seed:
	@echo "TODO Phase-1: genisoimage NoCloud cidata.iso from a filled user-data template"

all: golden cloud vmware-ova vbox-ova iso
	@echo "TODO Phase-1: build all distribution forms + reproducibility manifest"

clean:
	@echo "TODO Phase-1: rm -rf chroot/ .build/ out/ cache/ and image artifacts"
