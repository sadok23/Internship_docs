# Realtek NIC Driver Setup (`realtek-re-kmod`)

This guide covers installing the `realtek-re-kmod` driver on FreeBSD-based systems (including OPNsense) to enable Realtek NICs not supported by the in-tree `re(4)` driver.

---

## Installation Steps

### 1. Install the package

```sh
pkg install realtek-re-kmod
```

---

### 2. Configure the bootloader

> ⚠️ **Best practice: use `/boot/loader.conf.local` instead of `/boot/loader.conf`**
>
> On OPNsense (and some FreeBSD setups), `/boot/loader.conf` may be **overwritten on upgrades**. Always put your custom entries in `/boot/loader.conf.local` — it is preserved across system updates and is sourced automatically by the bootloader.

Add the following two lines to `/boot/loader.conf.local` (create the file if it doesn't exist):

```sh
if_re_load="YES"
if_re_name="/boot/modules/if_re.ko"
```

---

### 3. Reboot

```sh
reboot
```

---

### 4. Verify the interface is detected

After rebooting, confirm the NIC is visible with `ifconfig`:

```sh
ifconfig 
```

Expected output (example):

```
re0: flags=1008943<UP,BROADCAST,RUNNING,PROMISC,SIMPLEX,MULTICAST,LOWER_UP> metric 0 mtu 1500
    ...
```

If `re0` (or `re1`, `re2`, etc.) appears in the output, the driver loaded successfully.

---

## Summary

| File | Purpose |
|------|---------|
| `/boot/loader.conf.local` | Persistent boot-time kernel module loading (upgrade-safe) |
| `/boot/modules/if_re.ko` | Out-of-tree Realtek driver kernel module |

---

## Notes

- The interface name (`re0`, `re1`, ...) depends on how many Realtek NICs are present and their detection order.
- On OPNsense, you can also verify via **Interfaces → Assignments** in the web UI.
