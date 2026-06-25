# Windows / Qemu(KVM/Libvirt) Packer Templates

Builds Windows 10 (22h2), Windows 11 (23h2), Server 2022 and Server 2019 windows images.
These are suitable for consumption for QEMU and libvirt.

## Intent

Images have the following:

* Fully up to date (see `windows-update` provisioner)
* Access mechanisms:
  * winrm, rdp, and ssh enabled by default
  * username / password is "vagrant/vagrant"
* Installed packages
  * Chocolatey
  * QEMU guest additions
  * VirtIO drivers

## Prerequisites

* QEMU 8.1.5 or above
* Packer 1.9.4 or above

## Building

```bash
# Initialise plugins first (any template file works — they share the same plugins)
packer init win10_22h2.pkr.hcl

# Build everything (server core variants included)
make all
```

### Windows 10

`packer build win10_22h2.pkr.hcl`

### Windows 11

`packer build win11_23h2.pkr.hcl`

### Windows Server 2019

```bash
packer build win2019.pkr.hcl
# Build core edition instead
packer build -var=autounattend=answer_files/2019-core/Autounattend.xml win2019.pkr.hcl
```

### Windows Server 2022

```bash
packer build win2022.pkr.hcl
# Build core edition instead
packer build -var=autounattend=answer_files/2022-core/Autounattend.xml win2022.pkr.hcl
```

## Variables

Every template (`win10_22h2.pkr.hcl`, `win11_23h2.pkr.hcl`, `win2019.pkr.hcl`, `win2022.pkr.hcl`) exposes the same set of input variables. Built images are written to `output_directory/vm_name` (default: `output/windows_10`, etc.).

### Passing variables

Packer resolves variables in this order (later wins): defaults in the `.pkr.hcl` file, environment variables, `-var-file`, then `-var` on the command line.

**Command-line flags** — repeat `-var` for each override:

```bash
# Show the QEMU display (useful for debugging)
packer build -var='headless=false' win10_22h2.pkr.hcl

# Use a different ISO (always update the checksum too)
packer build \
  -var='iso_url=https://example.com/win10.iso' \
  -var='iso_checksum=sha256:abc123...' \
  win10_22h2.pkr.hcl

# Use a custom autounattend answer file
packer build -var='autounattend=./answer_files/10/Autounattend.xml' win10_22h2.pkr.hcl

# Combine several overrides
packer build \
  -var='cpus=8' \
  -var='memory_size=8192' \
  -var='disk_size=102400' \
  -var='vm_name=windows_10_custom' \
  win10_22h2.pkr.hcl
```

Quote values that contain spaces or shell metacharacters. For `shutdown_command`, escape inner quotes:

```bash
packer build -var='shutdown_command=shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\"' win10_22h2.pkr.hcl
```

**Variable files** — put overrides in a `.pkrvars.hcl` file and pass it with `-var-file`:

```hcl
# custom.pkrvars.hcl
headless      = "false"
cpus          = "8"
memory_size   = "8192"
iso_url       = "https://example.com/win10.iso"
iso_checksum  = "sha256:abc123..."
```

```bash
packer build -var-file=custom.pkrvars.hcl win10_22h2.pkr.hcl
```

**Environment variables** — prefix the variable name with `PKR_VAR_`:

```bash
export PKR_VAR_headless=false
export PKR_VAR_cpus=8
packer build win10_22h2.pkr.hcl
```

**Makefile** — the `Makefile` passes `headless` via `HEADLESS` (defaults to `true`):

```bash
HEADLESS=false make win10
```

Core server builds also set `vm_name` and `autounattend` (see `Makefile` targets `win2019_core` and `win2022_core`).

### Variable reference

| Variable | Description | Default (all templates) |
|----------|-------------|-------------------------|
| `accelerator` | QEMU accelerator (`kvm`, `tcg`, etc.) | `kvm` |
| `autounattend` | Path to the Windows unattended setup answer file | see per-template defaults below |
| `cpus` | Number of virtual CPUs | `4` |
| `disk_size` | Disk size in megabytes | `61440` (60 GB) |
| `headless` | Run QEMU without a display (`true` / `false`) | `true` |
| `iso_checksum` | Checksum of the installation ISO | see per-template defaults below |
| `iso_url` | URL or path to the installation ISO | see per-template defaults below |
| `memory_size` | RAM in megabytes | `4096` |
| `shutdown_command` | Command run to shut down the VM at the end of the build | sysprep (see [Toggling sysprep](#toggling-sysprep)) |
| `output_directory` | Base directory for build artefacts | `output` |
| `vm_name` | Subdirectory name under `output_directory` | see per-template defaults below |

Per-template defaults for `autounattend`, `iso_url`, `iso_checksum`, and `vm_name`:

| Template | `vm_name` | `autounattend` |
|----------|-----------|----------------|
| `win10_22h2.pkr.hcl` | `windows_10` | `./answer_files/10/Autounattend.xml` |
| `win11_23h2.pkr.hcl` | `windows_11` | `./answer_files/11/Autounattend.xml` |
| `win2019.pkr.hcl` | `windows_2019` | `./answer_files/2019-standard/Autounattend.xml` |
| `win2022.pkr.hcl` | `windows_2022` | `./answer_files/2022-standard/Autounattend.xml` |

Each template also ships with a pinned `iso_url` and matching `iso_checksum` in its `.pkr.hcl` file. Override both when pointing at a different ISO build.

Common override examples:

```bash
# Server 2019/2022 core edition (also set vm_name to avoid overwriting the standard build)
packer build \
  -var='vm_name=windows_2019_core' \
  -var='autounattend=answer_files/2019-core/Autounattend.xml' \
  win2019.pkr.hcl

# Custom output location
packer build -var='output_directory=output-custom' -var='vm_name=win10' win10_22h2.pkr.hcl
# -> writes to output-custom/win10/
```

## Building faster

* Remove the `windows-update` provisioner
  * This takes almost as long as the initial installation
* Comment out the `sdelete` command in `scripts/90-compact.bat`
  * This will save about 10 minutes on build time

## Customisations

### General customisations

Most of the time, you want to edit `scripts/70-install-misc.bat`

### Toggling sysprep

These images sysprep on first boot by default (`shutdown_command` runs `sysprep.exe`). To skip sysprep and shut down normally instead:

```bash
packer build -var='shutdown_command=shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\"' win10_22h2.pkr.hcl
```

See [Variables](#variables) for other ways to pass `shutdown_command`.

### Checking host prepared-ness

A file based lock is implemented, which creates the text
file `C:/not-yet-finished` in `70-install-misc.bat`, and is
deleted once the `Firstboot-Autounattend.xml` has finished
running (i.e. post sysprep). A simple check has been implemented
in the `Makefile` to check for this condition.

It is recommended to check for `C:/not-yet-finished` file,
if it is not present, the host has finished sysprepping
and is ready to be used (although depending on time, you *could*
hit a situation where sysprep has run the specialise phase,
but has not yet done one final reboot. ymmv)
