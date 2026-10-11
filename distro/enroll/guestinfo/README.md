# Optional VMware guestinfo enroll channel

A VMware-native alternative to attaching a NoCloud `cidata.iso`: cloud-init's
`DataSourceVMwareGuestInfo` reads `guestinfo.userdata` + `guestinfo.metadata`
from VMware extraconfig (NOT a CD-ROM), each with a matching `*.encoding` key of
`base64` or `gzip+base64`. It layers on the SAME `vacti-firstboot` unit - no
extra code path, just a different place the per-boot token arrives from.

This is an optional enhancement; the NoCloud `cidata.iso` (see `../nocloud/`) is
the lingua franca that works identically on cloud, VMware, VirtualBox, and the
installed ISO, so prefer it unless a vSphere deploy specifically wants guestinfo.

## Set the token via guestinfo (examples)

ESXi / vCenter - as an OVF vApp property at deploy time:

```sh
ovftool --prop:guestinfo.userdata="$(base64 -w0 user-data)" \
        --prop:guestinfo.userdata.encoding=base64 \
        vacti-engine-vmware.ova  "vi://user@vcenter/.../host"
```

Workstation / Player - add to the `.vmx` before power-on:

```
guestinfo.userdata = "<base64 of a user-data carrying the per-boot token>"
guestinfo.userdata.encoding = "base64"
```

govc (scripted):

```sh
govc vm.change -vm vacti-engine \
  -e guestinfo.userdata="$(base64 -w0 user-data)" \
  -e guestinfo.userdata.encoding=base64
```

The `user-data` is the SAME `../nocloud/user-data.example` the seed uses (filled
with a fresh single-use token). No secret is ever baked into the OVA; the token
is supplied here, per instance, at deploy time.
