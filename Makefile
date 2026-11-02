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

.PHONY: all golden golden-headless golden-gui cloud vmware-ova vbox-ova \
        fanout fanout-headless fanout-gui iso iso-gui seed scan lint clean help

# Flavor knob for the VM/cloud forms (golden + cloud/vmware-ova/vbox-ova).
# VACTI_FLAVOR=headless (default) | gui. It drives both the GUI stack bake
# (build-golden.sh) and the -headless/-gui filename tag (vacti-appliance.env ->
# VACTI_FLAVOR_SUFFIX), mirroring the ISO's -headless/-gui split. The golden-*
# and fanout-* convenience targets below just set it; `make golden` honors a
# VACTI_FLAVOR passed in the environment.
VACTI_FLAVOR ?= headless
export VACTI_FLAVOR

help:
	@echo "vacti-distro targets:"
	@echo "  make golden       - virt-customize the golden disk (VACTI_FLAVOR=headless|gui, default headless)"
	@echo "  make golden-headless / golden-gui - build a specific flavor's golden disk"
	@echo "  make cloud        - golden -> cloud qcow2 + raw.gz (honors VACTI_FLAVOR)"
	@echo "  make vmware-ova   - golden -> streamOptimized VMDK -> OVF(vmx-13) -> .ova (honors VACTI_FLAVOR)"
	@echo "  make vbox-ova     - golden -> VMDK -> OVF(virtualbox-2.2) -> .ova (honors VACTI_FLAVOR)"
	@echo "  make fanout       - golden -> all VM/cloud forms for one flavor (honors VACTI_FLAVOR)"
	@echo "  make fanout-headless / fanout-gui - fan out a specific flavor"
	@echo "  make iso          - live-build headless hybrid ISO (preseed install-to-disk)"
	@echo "  make iso-gui      - live-build GUI SKU (XFCE + Calamares)"
	@echo "  make seed TOKEN=.. URL=.. - build a NoCloud cidata.iso from a fresh single-use token"
	@echo "  make scan ART=..  - run the mandatory no-secret scan on an artifact"
	@echo "  make all          - golden + cloud + both OVAs + iso (headless flavor)"
	@echo "  make lint         - shellcheck the scripts + sanity-check YAML/OVF"
	@echo "  make clean        - remove build working trees and artifacts"

golden:
	$(GI)/build-golden.sh

# Flavor-explicit golden builds (the CI matrix sets VACTI_FLAVOR directly).
golden-headless:
	$(MAKE) golden VACTI_FLAVOR=headless

golden-gui:
	$(MAKE) golden VACTI_FLAVOR=gui

cloud: golden
	$(GI)/convert-cloud.sh

vmware-ova: golden
	$(GI)/convert-vmware-ova.sh

vbox-ova: golden
	$(GI)/convert-vbox-ova.sh

# Fan-out all VM/cloud forms from the one golden disk (golden built once).
fanout: golden
	$(GI)/fanout.sh all

# Flavor-explicit fan-outs.
fanout-headless:
	$(MAKE) fanout VACTI_FLAVOR=headless

fanout-gui:
	$(MAKE) fanout VACTI_FLAVOR=gui

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
	rm -rf $(LBC)/config/includes.chroot_before_packages
	@echo "[clean] done"
