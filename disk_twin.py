#!/usr/bin/env python3
"""
DiskTwin Engine — UUID-safe macOS Volume Mode Switcher & Thermal-Paced Sync Manager
Manages:
  - Primary External SSD ("Main 1TB", UUID: F3D3AB1D-9B98-4124-8CB4-63E94D0B3C9D)
  - Internal microSD ("MicroSD 1TB" in Desk Mode / "Main 1TB" in Road Mode, UUID: E045C145-3AD5-4B73-8558-2C1C8C37D1B4)
"""

import argparse
import datetime
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

APP_DIR = Path.home() / ".disk-twin"
CONFIG_PATH = APP_DIR / "config.json"
STATE_PATH = APP_DIR / "state.json"
EXCLUDES_PATH = APP_DIR / "excludes.txt"
LOG_PATH = APP_DIR / "sync.log"
LAUNCH_AGENT_PLIST = Path.home() / "Library" / "LaunchAgents" / "com.antigravity.disktwin.plist"
LAUNCH_AGENT_LABEL = "com.antigravity.disktwin"

DEFAULT_CONFIG = {
    "ssd_uuid": "F3D3AB1D-9B98-4124-8CB4-63E94D0B3C9D",
    "sd_uuid": "E045C145-3AD5-4B73-8558-2C1C8C37D1B4",
    "ssd_default_name": "Main 1TB",
    "sd_desk_name": "MicroSD 1TB",
    "sd_road_name": "Main 1TB",
    "schedule_enabled": True,
    "schedule_days": [3, 7],  # 1=Mon ... 7=Sun (Wed & Sun default)
    "schedule_hour": 14,
    "schedule_minute": 0,
    "cooldown_enabled": True,
    "cooldown_every_gb": 35,
    "cooldown_seconds": 60,
    "bwlimit_mbps": 0,
    "excludes": [
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".TemporaryItems",
        ".DocumentRevisions-V100",
        ".DS_Store",
        ".metadata_never_index",
        ".apdisk"
    ]
}

DEFAULT_STATE = {
    "mode": "desk",
    "road_lock": False,
    "road_activated_at": None,
    "last_sync_at": None,
    "last_sync_result": "Ready (Initial sync pending)",
    "sync_running": False,
    "sync_pid": None,
    "sync_direction": None,
    "sync_phase": "Idle",
    "sync_gb_session": 0.0,
    "sync_gb_batch": 0.0,
    "sync_speed": "",
    "sync_percent": "",
    "cooldown_remaining": 0,
    "last_error": None
}


def ensure_app_dir():
    APP_DIR.mkdir(parents=True, exist_ok=True)
    if not CONFIG_PATH.exists():
        save_json_atomic(CONFIG_PATH, DEFAULT_CONFIG)
    if not STATE_PATH.exists():
        save_json_atomic(STATE_PATH, DEFAULT_STATE)
    cfg = load_config()
    write_excludes(cfg.get("excludes", DEFAULT_CONFIG["excludes"]))


def save_json_atomic(path: Path, data: dict):
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
    tmp.replace(path)


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        return dict(DEFAULT_CONFIG)
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        merged = dict(DEFAULT_CONFIG)
        merged.update(data)
        return merged
    except Exception:
        return dict(DEFAULT_CONFIG)


def load_state() -> dict:
    if not STATE_PATH.exists():
        return dict(DEFAULT_STATE)
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        merged = dict(DEFAULT_STATE)
        merged.update(data)
        # Verify if sync_pid is still alive
        pid = merged.get("sync_pid")
        if merged.get("sync_running") and pid:
            if not is_pid_alive(pid):
                merged["sync_running"] = False
                merged["sync_pid"] = None
                if merged.get("sync_phase", "").startswith(("Syncing", "❄️", "Starting")):
                    merged["sync_phase"] = "Idle"
                save_json_atomic(STATE_PATH, merged)
        return merged
    except Exception:
        return dict(DEFAULT_STATE)


def update_state(**kwargs):
    st = load_state()
    st.update(kwargs)
    save_json_atomic(STATE_PATH, st)
    return st


def write_excludes(excludes_list):
    with open(EXCLUDES_PATH, "w", encoding="utf-8") as f:
        for item in excludes_list:
            f.write(f"{item}\n")


def log_msg(msg: str):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}\n"
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def notify_macos(title: str, message: str):
    script = f'display notification {json.dumps(message)} with title {json.dumps(title)}'
    subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True)


def is_pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def get_disk_info_by_uuid(uuid_str: str) -> dict:
    """Query diskutil info -plist <UUID> to get live hardware/mount status."""
    res = subprocess.run(
        ["/usr/sbin/diskutil", "info", "-plist", uuid_str],
        capture_output=True
    )
    if res.returncode != 0 or not res.stdout:
        return {
            "uuid": uuid_str,
            "connected": False,
            "mounted": False,
            "mount_point": "",
            "volume_name": "",
            "device_id": "",
            "whole_disk": "",
            "physical_disk": "",
            "used_gb": 0.0,
            "free_gb": 0.0,
            "total_gb": 0.0
        }
    try:
        pl = plistlib.loads(res.stdout)
    except Exception:
        return {"uuid": uuid_str, "connected": False, "mounted": False}

    mount_point = pl.get("MountPoint", "") or ""
    mounted = bool(mount_point)
    total_bytes = pl.get("TotalSize") or pl.get("Size") or 0
    free_bytes = pl.get("APFSContainerFree") or pl.get("FreeSpace") or 0
    used_bytes = pl.get("CapacityInUse") or (total_bytes - free_bytes if total_bytes >= free_bytes else 0)

    # Find physical store whole disk for APFS (e.g. disk13s2 -> disk13) so iostat works
    phys_stores = pl.get("APFSPhysicalStores", [])
    phys_disk = ""
    if phys_stores and isinstance(phys_stores, list):
        store_dev = phys_stores[0].get("APFSPhysicalStore", "")
        m = re.match(r"^(disk\d+)", store_dev)
        if m:
            phys_disk = m.group(1)
    if not phys_disk:
        whole = pl.get("ParentWholeDisk", "")
        phys_disk = whole

    return {
        "uuid": uuid_str,
        "connected": True,
        "mounted": mounted,
        "mount_point": mount_point,
        "volume_name": pl.get("VolumeName", ""),
        "device_id": pl.get("DeviceIdentifier", ""),
        "whole_disk": pl.get("ParentWholeDisk", ""),
        "physical_disk": phys_disk,
        "used_gb": round(used_bytes / (1024 ** 3), 1),
        "free_gb": round(free_bytes / (1024 ** 3), 1),
        "total_gb": round(total_bytes / (1024 ** 3), 1)
    }


def get_iostat_mb(disk_name: str) -> float:
    """Return cumulative MB transferred on physical disk via iostat -Id <disk>."""
    if not disk_name:
        return 0.0
    res = subprocess.run(
        ["/usr/sbin/iostat", "-Id", disk_name],
        capture_output=True,
        text=True
    )
    if res.returncode != 0:
        return 0.0
    lines = [ln.strip() for ln in res.stdout.strip().splitlines() if ln.strip()]
    if not lines:
        return 0.0
    last = lines[-1].split()
    if len(last) >= 3:
        try:
            return float(last[2])
        except ValueError:
            return 0.0
    return 0.0


def apply_sd_antiwear(mount_point: str):
    """Ensure Spotlight indexing and fseventsd logging are disabled on MicroSD."""
    if not mount_point or not os.path.ismount(mount_point):
        return
    mp = Path(mount_point)
    try:
        (mp / ".metadata_never_index").touch(exist_ok=True)
        fsev = mp / ".fseventsd"
        fsev.mkdir(exist_ok=True)
        (fsev / "no_log").touch(exist_ok=True)
    except Exception as e:
        log_msg(f"Warning: could not touch anti-wear files on {mount_point}: {e}")


def list_external_volumes() -> list[dict]:
    """List all mounted non-root volumes under /Volumes with their UUID, name, size, and protocol."""
    vols = []
    volumes_root = Path("/Volumes")
    if not volumes_root.exists():
        return vols
    for entry in sorted(volumes_root.iterdir()):
        if entry.is_symlink() or not entry.is_dir():
            continue
        res = subprocess.run(
            ["/usr/sbin/diskutil", "info", "-plist", str(entry)],
            capture_output=True
        )
        if res.returncode != 0 or not res.stdout:
            continue
        try:
            pl = plistlib.loads(res.stdout)
        except Exception:
            continue
        uuid_str = pl.get("VolumeUUID") or pl.get("DiskUUID") or ""
        if not uuid_str:
            continue
        mp = pl.get("MountPoint", "")
        if mp == "/":
            continue
        total_bytes = pl.get("TotalSize") or pl.get("Size") or 0
        total_gb = round(total_bytes / (1024 ** 3), 1)
        proto = pl.get("BusProtocol", "") or "Disk"
        vols.append({
            "uuid": uuid_str,
            "volume_name": pl.get("VolumeName", entry.name),
            "mount_point": mp,
            "total_gb": total_gb,
            "protocol": proto
        })
    return vols


def compute_full_status() -> dict:
    ensure_app_dir()
    cfg = load_config()
    st = load_state()
    ssd = get_disk_info_by_uuid(cfg["ssd_uuid"])
    sd = get_disk_info_by_uuid(cfg["sd_uuid"])

    # Determine effective mode
    if sd["mounted"] and sd["mount_point"] == "/Volumes/Main 1TB" and not ssd["mounted"]:
        effective_mode = "road"
    elif ssd["mounted"] and ssd["mount_point"] == "/Volumes/Main 1TB" and sd["volume_name"] == cfg["sd_desk_name"]:
        effective_mode = "desk"
    elif sd["volume_name"] == cfg["sd_road_name"] and ssd["mounted"]:
        effective_mode = "both_connected_road_named"
    elif not ssd["connected"] and sd["connected"]:
        effective_mode = "ssd_unplugged_ready_for_road"
    else:
        effective_mode = st.get("mode", "desk")

    return {
        "effective_mode": effective_mode,
        "ssd": ssd,
        "sd": sd,
        "state": st,
        "config": cfg
    }


def rename_and_remount(uuid_str: str, new_name: str) -> tuple[bool, str]:
    """Rename an APFS volume by UUID and remount it cleanly so /Volumes/<new_name> updates."""
    info = get_disk_info_by_uuid(uuid_str)
    if not info["connected"]:
        return False, f"Volume {uuid_str} is not connected."

    if not info["mounted"]:
        subprocess.run(["/usr/sbin/diskutil", "mount", uuid_str], capture_output=True)
        info = get_disk_info_by_uuid(uuid_str)

    if info["volume_name"] != new_name:
        r = subprocess.run(
            ["/usr/sbin/diskutil", "rename", uuid_str, new_name],
            capture_output=True, text=True
        )
        if r.returncode != 0:
            return False, f"Rename failed: {r.stderr.strip() or r.stdout.strip()}"

    # Unmount and remount so /Volumes/<new_name> is guaranteed to be fresh
    u = subprocess.run(["/usr/sbin/diskutil", "unmount", uuid_str], capture_output=True, text=True)
    if u.returncode != 0:
        # Try force unmount if Spotlight/Finder held a transient reference
        subprocess.run(["/usr/sbin/diskutil", "unmount", "force", uuid_str], capture_output=True, text=True)

    time.sleep(0.4)
    m = subprocess.run(["/usr/sbin/diskutil", "mount", uuid_str], capture_output=True, text=True)
    if m.returncode != 0:
        return False, f"Remount failed: {m.stderr.strip() or m.stdout.strip()}"

    updated = get_disk_info_by_uuid(uuid_str)
    return True, updated.get("mount_point", "")


def switch_to_road(sync_first: bool = False) -> tuple[bool, str]:
    ensure_app_dir()
    cfg = load_config()
    st = load_state()

    if st.get("sync_running"):
        return False, "A sync is currently running. Wait for it to finish or stop it first."

    ssd = get_disk_info_by_uuid(cfg["ssd_uuid"])
    sd = get_disk_info_by_uuid(cfg["sd_uuid"])

    if not sd["connected"]:
        return False, "MicroSD card is not detected in the SDXC slot."

    if sync_first and ssd["mounted"]:
        log_msg("Pre-flight sync requested before switching to Road Mode...")
        ok, msg = run_sync(direction="ssd_to_sd", manual=True)
        if not ok:
            return False, f"Pre-flight sync failed: {msg}"

    # Refresh SSD info and eject if connected
    ssd = get_disk_info_by_uuid(cfg["ssd_uuid"])
    if ssd["connected"] and ssd["mounted"]:
        update_state(sync_phase="Ejecting External SSD...")
        target_disk = ssd["physical_disk"] or ssd["whole_disk"] or cfg["ssd_uuid"]
        ej = subprocess.run(["/usr/sbin/diskutil", "eject", target_disk], capture_output=True, text=True)
        if ej.returncode != 0:
            unm = subprocess.run(["/usr/sbin/diskutil", "unmountDisk", target_disk], capture_output=True, text=True)
            if unm.returncode != 0:
                update_state(sync_phase="Idle")
                return False, f"Could not eject Main 1TB SSD (files in use): {ej.stderr.strip() or unm.stderr.strip()}"

    # Wait briefly for /Volumes/Main 1TB to clear
    for _ in range(10):
        if not os.path.exists("/Volumes/Main 1TB") or get_disk_info_by_uuid(cfg["sd_uuid"]).get("mount_point") == "/Volumes/Main 1TB":
            break
        time.sleep(0.3)

    # Rename MicroSD to "Main 1TB" and mount at /Volumes/Main 1TB
    update_state(sync_phase="Switching MicroSD to /Volumes/Main 1TB...")
    ok, mp_or_err = rename_and_remount(cfg["sd_uuid"], cfg["sd_road_name"])
    if not ok:
        update_state(sync_phase="Idle")
        return False, mp_or_err

    apply_sd_antiwear(mp_or_err)
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    update_state(
        mode="road",
        road_lock=True,
        road_activated_at=now_str,
        sync_phase="Idle",
        last_error=None
    )
    msg = f"MicroSD is now mounted at {mp_or_err}. Safe to unplug External SSD!"
    log_msg(f"Switched to ROAD MODE: {msg}")
    notify_macos("✈️ Road Mode Active", msg)
    return True, msg


def switch_to_desk(sync_back: bool = False) -> tuple[bool, str]:
    ensure_app_dir()
    cfg = load_config()
    st = load_state()

    if st.get("sync_running"):
        return False, "A sync is currently running. Stop it before switching modes."

    ssd = get_disk_info_by_uuid(cfg["ssd_uuid"])
    sd = get_disk_info_by_uuid(cfg["sd_uuid"])

    if not ssd["connected"]:
        return False, "External SSD ('Main 1TB') is not plugged in! Connect it via USB first."
    if not sd["connected"]:
        return False, "MicroSD card is not detected."

    update_state(sync_phase="Restoring Desk Mode mounts...")

    # Step 1: Rename MicroSD back to "MicroSD 1TB" and remount at /Volumes/MicroSD 1TB
    ok_sd, sd_mp = rename_and_remount(cfg["sd_uuid"], cfg["sd_desk_name"])
    if not ok_sd:
        update_state(sync_phase="Idle")
        return False, f"Failed to rename MicroSD: {sd_mp}"
    apply_sd_antiwear(sd_mp)

    # Step 2: Ensure External SSD is named "Main 1TB" and mounted cleanly at /Volumes/Main 1TB
    ok_ssd, ssd_mp = rename_and_remount(cfg["ssd_uuid"], cfg["ssd_default_name"])
    if not ok_ssd:
        update_state(sync_phase="Idle")
        return False, f"Failed to mount External SSD at /Volumes/Main 1TB: {ssd_mp}"

    # Step 3: Optional Sync-Back (MicroSD -> External SSD, update-only, no --delete)
    if sync_back:
        log_msg("Syncing Road Mode changes from MicroSD back to External SSD...")
        ok_sync, sync_msg = run_sync(direction="sd_to_ssd", manual=True)
        if not ok_sync:
            return False, f"Volumes restored, but Sync-Back reported an issue: {sync_msg}"

    update_state(
        mode="desk",
        road_lock=False,
        road_activated_at=None,
        sync_phase="Idle",
        last_error=None
    )
    msg = f"SSD mounted at {ssd_mp} & MicroSD at {sd_mp}."
    log_msg(f"Switched to DESK MODE: {msg}")
    notify_macos("🏠 Desk Mode Active", msg)
    return True, msg


def find_rsync_binary() -> str:
    for candidate in ["/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync"]:
        if os.path.exists(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return "/usr/bin/rsync"


def run_sync(direction: str = "ssd_to_sd", manual: bool = True) -> tuple[bool, str]:
    """
    Run UUID-verified rsync with thermal/SLC cooldown breaks.
    direction:
      - 'ssd_to_sd': Mirror Main 1TB SSD -> MicroSD 1TB (with --delete-after)
      - 'sd_to_ssd': Sync newer Road Mode files from MicroSD -> Main 1TB SSD (--update, NO --delete)
    """
    ensure_app_dir()
    cfg = load_config()
    st = load_state()

    if st.get("sync_running"):
        return False, "Sync is already running."

    if not manual and st.get("road_lock"):
        msg = "Scheduled sync skipped: Road Mode lock is active (protecting road edits)."
        log_msg(msg)
        return False, msg

    ssd = get_disk_info_by_uuid(cfg["ssd_uuid"])
    sd = get_disk_info_by_uuid(cfg["sd_uuid"])

    if not ssd["mounted"] or not sd["mounted"]:
        msg = "Both External SSD and MicroSD must be mounted to sync."
        if manual:
            notify_macos("⚠️ DiskTwin Sync Aborted", msg)
        log_msg(msg)
        return False, msg

    if ssd["mount_point"] == sd["mount_point"]:
        msg = f"Mount point collision detected ({ssd['mount_point']}). Switch to Desk Mode first."
        log_msg(msg)
        return False, msg

    if direction == "ssd_to_sd" and sd["volume_name"] == cfg["sd_road_name"]:
        msg = "MicroSD is still named 'Main 1TB' (Road Mode). Switch to Desk Mode first."
        log_msg(msg)
        return False, msg

    write_excludes(cfg.get("excludes", DEFAULT_CONFIG["excludes"]))
    rsync_bin = find_rsync_binary()
    is_modern_rsync = "/homebrew/" in rsync_bin or "/usr/local/" in rsync_bin

    if direction == "ssd_to_sd":
        src = ssd["mount_point"].rstrip("/") + "/"
        dst = sd["mount_point"].rstrip("/") + "/"
        label = "SSD → MicroSD"
    else:
        src = sd["mount_point"].rstrip("/") + "/"
        dst = ssd["mount_point"].rstrip("/") + "/"
        label = "MicroSD → SSD (Road Changes)"

    cmd = [rsync_bin, "-aHAX"]
    if direction == "ssd_to_sd":
        cmd.append("--delete-after")
    else:
        cmd.append("--update")  # Never overwrite newer files on SSD during road sync-back

    if is_modern_rsync:
        cmd.extend(["--info=progress2", "--human-readable"])
    else:
        cmd.append("--progress")

    bwlimit_mbps = int(cfg.get("bwlimit_mbps", 0) or 0)
    if bwlimit_mbps > 0 and direction == "ssd_to_sd":
        cmd.append(f"--bwlimit={bwlimit_mbps * 1024}")

    cmd.extend([f"--exclude-from={EXCLUDES_PATH}", src, dst])

    log_msg(f"Starting sync ({label}): {' '.join(cmd)}")
    notify_macos("🔄 DiskTwin Sync Started", f"{label} started.")

    sd_phys_disk = sd.get("physical_disk") or "disk13"
    start_io_mb = get_iostat_mb(sd_phys_disk)
    batch_start_io_mb = start_io_mb

    cooldown_enabled = bool(cfg.get("cooldown_enabled", True)) and direction == "ssd_to_sd"
    cooldown_every_mb = float(cfg.get("cooldown_every_gb", 25)) * 1024.0
    cooldown_seconds = int(cfg.get("cooldown_seconds", 90))

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        preexec_fn=os.setsid
    )

    update_state(
        sync_running=True,
        sync_pid=proc.pid,
        sync_direction=direction,
        sync_phase=f"Syncing ({label})",
        sync_gb_session=0.0,
        sync_gb_batch=0.0,
        sync_speed="Scanning...",
        sync_percent="0%",
        cooldown_remaining=0,
        last_error=None
    )

    import selectors
    sel = selectors.DefaultSelector()
    if proc.stdout:
        sel.register(proc.stdout, selectors.EVENT_READ)

    last_io_check = time.time()
    pct_str = "0%"
    spd_str = ""
    stopped_by_user = False

    def handle_sigterm(signum, frame):
        nonlocal stopped_by_user
        stopped_by_user = True
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGCONT)
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except Exception:
            pass

    signal.signal(signal.SIGTERM, handle_sigterm)
    signal.signal(signal.SIGINT, handle_sigterm)

    buf = ""
    try:
        while True:
            if proc.poll() is not None:
                break

            events = sel.select(timeout=1.0)
            for key, _ in events:
                chunk = os.read(key.fileobj.fileno(), 4096).decode("utf-8", errors="replace")
                if not chunk:
                    continue
                buf += chunk
                parts = re.split(r"[\r\n]+", buf)
                buf = parts[-1]
                for line in parts[:-1]:
                    line_s = line.strip()
                    if not line_s:
                        continue
                    # Parse --info=progress2 line: e.g. "  1.25G  14%   41.20MB/s    0:01:12"
                    m_prog = re.search(r"(\d+%)\s+([0-9.]+[KMGTP]?B/s)", line_s)
                    if m_prog:
                        pct_str = m_prog.group(1)
                        spd_str = m_prog.group(2)

            now = time.time()
            if now - last_io_check >= 2.0:
                last_io_check = now
                cur_io_mb = get_iostat_mb(sd_phys_disk)
                session_mb = max(0.0, cur_io_mb - start_io_mb)
                batch_mb = max(0.0, cur_io_mb - batch_start_io_mb)
                session_gb = round(session_mb / 1024.0, 2)
                batch_gb = round(batch_mb / 1024.0, 2)

                update_state(
                    sync_running=True,
                    sync_pid=proc.pid,
                    sync_phase=f"Syncing {pct_str} ({session_gb} GB written)",
                    sync_gb_session=session_gb,
                    sync_gb_batch=batch_gb,
                    sync_speed=spd_str,
                    sync_percent=pct_str,
                    cooldown_remaining=0
                )

                # Check if thermal/SLC cooldown break threshold reached
                if cooldown_enabled and cooldown_every_mb > 0 and batch_mb >= cooldown_every_mb:
                    log_msg(f"Thermal cooldown triggered after {batch_gb} GB batch. Pausing rsync for {cooldown_seconds}s...")
                    try:
                        os.killpg(os.getpgid(proc.pid), signal.SIGSTOP)
                    except Exception:
                        pass
                    subprocess.run(["/bin/sync"], capture_output=True)

                    for rem in range(cooldown_seconds, 0, -1):
                        if stopped_by_user:
                            break
                        update_state(
                            sync_running=True,
                            sync_pid=proc.pid,
                            sync_phase=f"Cooling SD ({rem}s) — {session_gb} GB done",
                            sync_gb_session=session_gb,
                            sync_gb_batch=batch_gb,
                            sync_speed="Paused (Cooling)",
                            sync_percent=pct_str,
                            cooldown_remaining=rem
                        )
                        time.sleep(1.0)

                    batch_start_io_mb = get_iostat_mb(sd_phys_disk)
                    if not stopped_by_user:
                        log_msg("Resuming rsync after thermal cooldown.")
                        try:
                            os.killpg(os.getpgid(proc.pid), signal.SIGCONT)
                        except Exception:
                            pass

        rc = proc.wait()
    finally:
        sel.close()

    apply_sd_antiwear(sd["mount_point"])
    end_io_mb = get_iostat_mb(sd_phys_disk)
    total_gb = round(max(0.0, end_io_mb - start_io_mb) / 1024.0, 2)
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")

    # rsync code 0 = success, 23/24 = partial transfer due to vanished/permission on system sockets (normal on macOS roots)
    if stopped_by_user:
        res_msg = f"Stopped by user at {now_str} ({total_gb} GB written)"
        update_state(
            sync_running=False,
            sync_pid=None,
            sync_phase="Idle",
            cooldown_remaining=0,
            last_sync_result=res_msg
        )
        log_msg(res_msg)
        notify_macos("⏹ DiskTwin Sync Stopped", res_msg)
        return False, res_msg
    elif rc in (0, 23, 24):
        res_msg = f"Success ({label}) — {total_gb} GB written"
        update_state(
            sync_running=False,
            sync_pid=None,
            sync_phase="Idle",
            cooldown_remaining=0,
            last_sync_at=now_str,
            last_sync_result=res_msg,
            last_error=None
        )
        log_msg(f"Sync finished (rc={rc}): {res_msg}")
        notify_macos("✅ DiskTwin Sync Complete", f"{res_msg} at {now_str}")
        return True, res_msg
    else:
        err_msg = f"Sync exited with code {rc}"
        update_state(
            sync_running=False,
            sync_pid=None,
            sync_phase="Idle",
            cooldown_remaining=0,
            last_sync_result=err_msg,
            last_error=err_msg
        )
        log_msg(err_msg)
        notify_macos("⚠️ DiskTwin Sync Error", err_msg)
        return False, err_msg


def stop_running_sync() -> tuple[bool, str]:
    st = load_state()
    pid = st.get("sync_pid")
    if not st.get("sync_running") or not pid:
        update_state(sync_running=False, sync_pid=None, sync_phase="Idle", cooldown_remaining=0)
        return True, "No active sync was running."
    try:
        pgid = os.getpgid(pid)
        os.killpg(pgid, signal.SIGCONT)
        os.killpg(pgid, signal.SIGTERM)
    except Exception:
        try:
            os.kill(pid, signal.SIGTERM)
        except Exception:
            pass
    time.sleep(0.5)
    now_str = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    update_state(
        sync_running=False,
        sync_pid=None,
        sync_phase="Idle",
        cooldown_remaining=0,
        last_sync_result=f"Stopped at {now_str}"
    )
    return True, "Sync stopped cleanly."


def update_launchd_schedule() -> tuple[bool, str]:
    ensure_app_dir()
    cfg = load_config()
    LAUNCH_AGENT_PLIST.parent.mkdir(parents=True, exist_ok=True)

    uid = os.getuid()
    subprocess.run(
        ["/bin/launchctl", "bootout", f"gui/{uid}", str(LAUNCH_AGENT_PLIST)],
        capture_output=True
    )

    if not cfg.get("schedule_enabled", True) or not cfg.get("schedule_days"):
        if LAUNCH_AGENT_PLIST.exists():
            LAUNCH_AGENT_PLIST.unlink()
        return True, "Automatic schedule disabled."

    hour = int(cfg.get("schedule_hour", 14))
    minute = int(cfg.get("schedule_minute", 0))
    days = cfg.get("schedule_days", [3, 7])

    intervals = []
    for d in days:
        intervals.append({
            "Weekday": int(d),
            "Hour": hour,
            "Minute": minute
        })

    script_path = str(APP_DIR / "disk_twin.py")
    plist_data = {
        "Label": LAUNCH_AGENT_LABEL,
        "ProgramArguments": ["/usr/bin/python3", script_path, "sync", "--scheduled"],
        "StartCalendarInterval": intervals,
        "StandardOutPath": str(APP_DIR / "launchd.out.log"),
        "StandardErrorPath": str(APP_DIR / "launchd.err.log"),
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "Nice": 10
    }

    with open(LAUNCH_AGENT_PLIST, "wb") as f:
        plistlib.dump(plist_data, f)

    r = subprocess.run(
        ["/bin/launchctl", "bootstrap", f"gui/{uid}", str(LAUNCH_AGENT_PLIST)],
        capture_output=True, text=True
    )
    if r.returncode != 0:
        subprocess.run(["/bin/launchctl", "load", "-w", str(LAUNCH_AGENT_PLIST)], capture_output=True)

    day_names = {1: "Mon", 2: "Tue", 3: "Wed", 4: "Thu", 5: "Fri", 6: "Sat", 7: "Sun"}
    days_str = ", ".join(day_names.get(int(d), str(d)) for d in sorted(days))
    msg = f"Scheduled for {days_str} at {hour:02d}:{minute:02d}"
    log_msg(f"Updated launchd schedule: {msg}")
    return True, msg


def main():
    parser = argparse.ArgumentParser(description="DiskTwin Manager")
    sub = parser.add_subparsers(dest="cmd")

    p_status = sub.add_parser("status")
    p_status.add_argument("--json", action="store_true")

    p_road = sub.add_parser("to-road")
    p_road.add_argument("--sync-first", action="store_true")

    p_desk = sub.add_parser("to-desk")
    p_desk.add_argument("--sync-back", action="store_true")

    p_sync = sub.add_parser("sync")
    p_sync.add_argument("--scheduled", action="store_true")
    p_sync.add_argument("--reverse", action="store_true")

    sub.add_parser("stop-sync")
    sub.add_parser("update-schedule")
    sub.add_parser("list-volumes")

    args = parser.parse_args()
    ensure_app_dir()

    if args.cmd == "status" or not args.cmd:
        st = compute_full_status()
        if getattr(args, "json", False):
            print(json.dumps(st, indent=2))
        else:
            print(f"Effective Mode : {st['effective_mode'].upper()}")
            print(f"Road Lock      : {'ACTIVE 🔒' if st['state']['road_lock'] else 'Off'}")
            print(f"External SSD   : {'Mounted at ' + st['ssd']['mount_point'] if st['ssd']['mounted'] else 'Unmounted/Disconnected'} ({st['ssd']['used_gb']} / {st['ssd']['total_gb']} GB)")
            print(f"MicroSD 1TB    : {'Mounted at ' + st['sd']['mount_point'] if st['sd']['mounted'] else 'Unmounted/Disconnected'} ({st['sd']['used_gb']} / {st['sd']['total_gb']} GB)")
            print(f"Sync Status    : {st['state']['sync_phase']}")
            print(f"Last Sync      : {st['state']['last_sync_at'] or 'Never'} — {st['state']['last_sync_result']}")
        return

    if args.cmd == "to-road":
        ok, msg = switch_to_road(sync_first=args.sync_first)
        print(json.dumps({"ok": ok, "message": msg}))
        sys.exit(0 if ok else 1)

    if args.cmd == "to-desk":
        ok, msg = switch_to_desk(sync_back=args.sync_back)
        print(json.dumps({"ok": ok, "message": msg}))
        sys.exit(0 if ok else 1)

    if args.cmd == "sync":
        direction = "sd_to_ssd" if args.reverse else "ssd_to_sd"
        ok, msg = run_sync(direction=direction, manual=not args.scheduled)
        print(json.dumps({"ok": ok, "message": msg}))
        sys.exit(0 if ok else 1)

    if args.cmd == "stop-sync":
        ok, msg = stop_running_sync()
        print(json.dumps({"ok": ok, "message": msg}))
        sys.exit(0 if ok else 1)

    if args.cmd == "update-schedule":
        ok, msg = update_launchd_schedule()
        print(json.dumps({"ok": ok, "message": msg}))
        sys.exit(0 if ok else 1)

    if args.cmd == "list-volumes":
        print(json.dumps(list_external_volumes(), indent=2))
        return


if __name__ == "__main__":
    main()
