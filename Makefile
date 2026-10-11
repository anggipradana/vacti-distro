# vacti-distro build orchestration (Phase-1 implemented).
#
# One source tree (distro/) feeds all forms:
#   - golden / cloud / vmware-ova / vbox-ova : golden-image + convert fan-out
#   - iso                                    : Debian live-build + Calamares
#
# All packaging uses open-source tools (libguestfs/virt-customize, qemu-img,
# genisoimage/xorriso, tar). ovftool / VBoxManage are dev-box-only (never CI).
#
# HEAVY BUILDS RUN IN CI (GitHub Actions), NOT on the prod control plane. These
# targets invoke libguestfs/live-build and are intended for an off-prod runner.
#
# Config: distro/vacti-appliance.env (base pin, engine ver, capabilities, Kali
# on/off). Build-time secret (NOT baked): export VACTI_APT_PRODUCER_TOKEN.

SHELL := /usr/bin/env bash
DISTRO := distro
GI := $(DISTRO)/golden-image
LBC := $(DISTRO)/live-build-config
PKG := $(DISTRO)/packages

.PHONY: all golden cloud vmware-ova vbox-ova iso iso-gui seed scan lint clean help

help:
	@echo "vacti-distro targets:"
	@echo "  make golden       - fetch+verify Debian 13 genericcloud qcow2, virt-customize the golden disk"
	@echo "  make cloud        - golden -> cloud qcow2 + raw.gz"
	@echo "  make vmware-ova   - golden -> streamOptimized VMDK -> OVF(vmx-13) -> .ova"
	@echo "  make vbox-ova     - golden -> VMDK -> OVF(virtualbox-2.2) -> .ova"
	@echo "  make iso          - live-build headless hybrid ISO (preseed install-to-disk)"
	@echo "  make iso-gui      - live-build GUI SKU (XFCE + Calamares)"
	@echo "  make seed TOKEN=.. URL=.. - build a NoCloud cidata.iso from a fresh single-use token"
	@echo "  make scan ART=..  - run the mandatory no-secret scan on an artifact"
	@echo "  make all          - golden + cloud + both OVAs + iso"
	@echo "  make lint         - shellcheck the scripts + sanity-check YAML/OVF"
	@echo "  make clean        - remove build working trees and artifacts"

golden:
	$(GI)/build-golden.sh

cloud: golden
	$(GI)/convert-cloud.sh

vmware-ova: golden
	$(GI)/convert-vmware-ova.sh

vbox-ova: golden
	$(GI)/convert-vbox-ova.sh

# Fan-out all VM/cloud forms from the one golden disk (golden built once).
fanout: golden
	$(GI)/fanout.sh all

iso:
	VACTI_ISO_SKU=headless $(LBC)/build-iso.sh

iso-gui:
	VACTI_ISO_SKU=gui $(LBC)/build-iso.sh

# make seed TOKEN=<enroll-token> URL=<https://cp> [OUT=cidata.iso]
seed:
	@test -n "$(TOKEN)" || { echo "TOKEN=<fresh single-use enroll token> is required"; exit 2; }
	@test -n "$(URL)" || { echo "URL=<control-plane base url> is required"; exit 2; }
	$(DISTRO)/enroll/nocloud/make-seed.sh --token "$(TOKEN)" --url "$(URL)" $(if $(OUT),--out "$(OUT)",)

# make scan ART=out/vacti-engine-0.1.0-cloud.qcow2
scan:
	@test -n "$(ART)" || { echo "ART=<artifact path> is required"; exit 2; }
	ci/no-secret-scan.sh "$(ART)"

all: golden cloud vmware-ova vbox-ova iso
	@echo "[all] built golden + cloud + both OVAs + iso; artifacts under $(DISTRO)/out/"

lint:
	ci/lint.sh

clean:
	rm -rf $(DISTRO)/.build $(DISTRO)/out
	rm -rf $(LBC)/chroot $(LBC)/.build $(LBC)/cache $(LBC)/config/binary $(LBC)/config/chroot
	rm -f  $(LBC)/build.log $(LBC)/*.hybrid.iso
	rm -f  $(LBC)/config/package-lists/vacti-core.list.chroot $(LBC)/config/package-lists/vacti-gui.list.chroot
	rm -f  $(LBC)/config/includes.chroot/etc/apt/auth.conf.d/vacti-engine.conf
	@echo "[clean] done"
