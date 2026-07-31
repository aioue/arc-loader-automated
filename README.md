# arc-loader-automated

Bash helpers to go from **zero** to the **DSM Web Assistant** (`:5000`) on Proxmox without clicking through Arc Config Mode (`:7080`).

Validated on Arc **3.1.0**, DSM **7.2.2-72806**, DS923+ / r1000. A 2-core, 4 GB RAM VM on a Ryzen 5600G-class host reaches `:5000` in about **2 minutes** from first loader boot when PAT download is online.

This repo is the maintained path for headless installs. It includes workarounds (p1 `/automated`, `arc.offline`, and similar) discovered while automating Arc on Proxmox. I opened upstream PRs first ([#9536](https://github.com/AuxXxilium/arc/pull/9536) and others); they were closed without merge — see [Upstream](#upstream) below.

## Links

- **Blog post:** [Zero to Synology DSM on Proxmox: headless Arc install in about 2 minutes](https://aioue.github.io/2026/07/31/proxmox-headless-arc-zero-to-dsm.html)
- **Arc Loader upstream:** [AuxXxilium/arc](https://github.com/AuxXxilium/arc)
- **Closed upstream PRs (reference):** [aioue PRs on AuxXxilium/arc](https://github.com/AuxXxilium/arc/pulls?q=is%3Apr+author%3Aaioue)

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| Proxmox VE | SSH as `root` from the machine running these scripts |
| `arc.img` on Proxmox | e.g. `/var/lib/vz/template/iso/arc.img` from [Arc releases](https://github.com/AuxXxilium/arc/releases) |
| `sshpass` on Proxmox | Loader SSH is `root` / `arc` |
| `yq` on Arc loader | Already present on current Arc images |
| Network | PAT download needs outbound HTTPS; seed sets `arc.offline: false` (default) |

## Quick start

Pick a **free VMID** and a **unique name** on your host.

```bash
git clone https://github.com/aioue/arc-loader-automated.git
cd arc-loader-automated

export PVE_HOST=192.168.1.10
export ARC_VMID=105
export ARC_VM_NAME=xpenology-arc-lab

./run-from-scratch.sh --yes
```

When it finishes:

```
DSM Web Assistant: http://192.168.x.x:5000
```

Complete the DSM first-boot wizard in a browser. Storage pool creation on the data disk (`sata1`) is still manual in DSM.

## Scripts

| Script | Purpose |
|--------|---------|
| `run-from-scratch.sh` | Optional destroy → create VM → seed → automated build → wait for `:5000` |
| `create-test-vm.sh` | Create OVMF VM (sata0 loader, sata1 data) or start if exists |
| `destroy-test-vm.sh` | Destroy **only** after name/OVMF/sata0 safety checks + `--yes` |
| `wait-for-loader-ip.sh` | Guest-agent IP + loader SSH readiness |
| `configure-and-build.sh` | Seed + `automated_arc` reboot + poll (existing loader IP) |
| `loader-seed-config.sh` | Runs **on loader** — yq-only `user-config.yml` seed |
| `loader-trigger-automated.sh` | Runs **on loader** — grub `next_entry=automated` + reboot |
| `lib.sh` | Shared defaults (source only) |

## Safety: destroy

`destroy-test-vm.sh` **will not** destroy a VM unless **all** of these pass:

1. `--yes` was passed
2. VMID is not in `PROTECTED_VMIDS` (optional env, e.g. `PROTECTED_VMIDS=103`)
3. VM **name** matches `--name`
4. VM uses **OVMF**, has sata0 + sata1, guest agent enabled, boots from sata0
5. When running, loader SSH confirms `/opt/arc` exists

## Configuration

Defaults live in `lib.sh`. Override via environment or CLI flags:

```bash
./run-from-scratch.sh \
  --pve-host 192.168.1.10 \
  --vmid 105 \
  --name my-arc \
  --storage local-zfs \
  --cores 2 \
  --memory 4096 \
  --data-disk-gb 80 \
  --model DS923+ \
  --platform r1000 \
  --productver 7.2 \
  --buildnum 72806 \
  --yes
```

PAT URL and hash must match your model/build. Find them in Arc Config Mode or Arc's model database.

### Reuse an existing loader

```bash
./run-from-scratch.sh --skip-destroy --skip-create
# or, if you know the IP:
./configure-and-build.sh 192.168.1.41
```

## How it works

1. **Seed** `user-config.yml` with yq only (never partial Arc lib edits over SSH).
2. Write **both** `/mnt/p1/automated` and `/mnt/p3/automated`, set `grub-editenv next_entry=automated`, reboot.
3. Loader boots **`automated_arc`**; `arc.sh` runs on the serial console (dialog works).
4. PAT downloads, loader builds, DSM boots. Success when `arc.builddone=true` or loader SSH closes and `:5000` responds.

## Upstream

Small PRs to [AuxXxilium/arc](https://github.com/AuxXxilium/arc) ([#9536](https://github.com/AuxXxilium/arc/pull/9536) and others) were submitted with repro steps before this repo was published. They were closed without merge. Workarounds stay here so headless installs work on stock Arc 3.1.0 without waiting on upstream.

## License

MIT — see [LICENSE](LICENSE).
