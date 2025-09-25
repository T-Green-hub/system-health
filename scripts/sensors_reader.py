#!/usr/bin/env python3
# System-Health — sensors_reader.py (upgraded)
# Fast-path via /sys; shell out only as last resort.
import os, json, subprocess, time, re, shutil, math, glob

HOME    = os.path.expanduser("~")
STATE   = os.path.join(HOME, ".local", "state", "system-health")
LOGDIR  = os.path.join(HOME, ".local", "share", "system-health", "logs")
STATUS  = os.path.join(STATE, "status.json")
os.makedirs(STATE, exist_ok=True)
os.makedirs(LOGDIR, exist_ok=True)

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""

def read_float(path):
    try:
        with open(path, "r") as f:
            s = f.read().strip()
            if s == "" or s.lower() == "nan":
                return None
            # Some hwmon temps are millidegrees
            v = float(s)
            return v/1000.0 if v > 200 else v
    except Exception:
        return None

def first(*vals):
    for v in vals:
        if v is not None:
            return v
    return None

def get_power_state():
    # AC online?
    for p in ["/sys/class/power_supply/AC/online",
              "/sys/class/power_supply/ACAD/online",
              "/sys/class/power_supply/AC0/online"]:
        if os.path.exists(p):
            try:
                return "AC" if open(p).read().strip() == "1" else "BAT"
            except Exception:
                pass
    out = sh("acpi -a")  # fallback
    if "on-line" in out:
        return "AC"
    if out:
        return "BAT"
    return "UNKNOWN"

def read_cpu_temp():
    # Try common hwmon labels for CPU package
    for hw in glob.glob("/sys/class/hwmon/hwmon*"):
        namep = os.path.join(hw, "name")
        try:
            nm = open(namep).read().strip()
        except Exception:
            nm = ""
        # Look for typical CPU providers
        if nm in ("coretemp", "k10temp", "zenpower", "acpitz", "pch_cannonlake", "iwlwifi_1"):
            for tfile in glob.glob(os.path.join(hw, "temp*_input")):
                # prefer labels that say 'Tctl', 'Package', or 'CPU'
                lbl = tfile.replace("_input", "_label")
                lab = ""
                if os.path.exists(lbl):
                    try: lab = open(lbl).read().strip()
                    except Exception: pass
                val = read_float(tfile)
                if val is None: 
                    continue
                tag = lab.lower()
                if any(k in tag for k in ("tctl","package","cpu","soc")):
                    return val
            # fallback to the hottest sensor in this hwmon
            vals = [read_float(t) for t in glob.glob(os.path.join(hw, "temp*_input"))]
            vals = [v for v in vals if v is not None]
            if vals:
                return max(vals)
    # lm-sensors fallback
    out = sh("sensors")
    m = re.search(r"(Package id \d+|Tctl|Tccd.*|Tdie|Tctl):\s*\+([\d\.]+)", out)
    if m:
        return float(m.group(2))
    # Try thermal zones
    for tz in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
        v = read_float(tz)
        if v and v > 15:
            return v
    return None

def read_gpu_temp():
    # AMD iGPU (amdgpu) via hwmon
    for hw in glob.glob("/sys/class/hwmon/hwmon*"):
        namep = os.path.join(hw, "name")
        try:
            nm = open(namep).read().strip()
        except Exception:
            nm = ""
        if nm == "amdgpu":
            # temp1_input (edge) commonly GPU core temp
            for tfile in glob.glob(os.path.join(hw, "temp*_input")):
                val = read_float(tfile)
                if val and 15 < val < 130:
                    return val
    # Intel iGPU occasionally exposes via i915 hwmon
    for hw in glob.glob("/sys/class/hwmon/hwmon*"):
        namep = os.path.join(hw, "name")
        try:
            nm = open(namep).read().strip()
        except Exception:
            nm = ""
        if nm in ("i915", "intel_gpu"):
            for tfile in glob.glob(os.path.join(hw, "temp*_input")):
                val = read_float(tfile)
                if val and 15 < val < 130:
                    return val
    # nvidia-smi (dGPU) fallback
    if shutil.which("nvidia-smi"):
        out = sh("nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits")
        try:
            v = float(out.splitlines()[0].strip())
            return v
        except Exception:
            pass
    return None

def read_nvme_temp():
    # /sys nvme hwmon path (fast, if present)
    for nv in glob.glob("/sys/class/nvme/nvme*/device/hwmon/hwmon*/temp1_input"):
        v = read_float(nv)
        if v and 5 < v < 120:
            return v
    # smartctl fallback
    if shutil.which("smartctl"):
        # Try all /dev/nvme?n?
        devs = sorted(glob.glob("/dev/nvme*n*")) or ["/dev/nvme0n1", "/dev/nvme0"]
        for d in devs:
            out = sh(f"smartctl -A {d}")
            m = re.search(r"Temperature_Celsius.*?(\d+)", out)
            if not m:
                m = re.search(r"Temperature:\s+(\d+)\s*C", out)
            if m:
                try:
                    v = float(m.group(1))
                    if 5 < v < 120:
                        return v
                except Exception:
                    pass
    # nvme-cli fallback
    if shutil.which("nvme"):
        # nvme smart-log /dev/nvme0
        for d in ("/dev/nvme0", "/dev/nvme1"):
            out = sh(f"nvme smart-log {d}")
            m = re.search(r"temperature\s*:\s*(\d+)", out)
            if m:
                v = float(m.group(1))
                if 5 < v < 120:
                    return v
    return None

def read_fan():
    # ThinkPad ACPI
    fanp = "/proc/acpi/ibm/fan"
    if os.path.exists(fanp):
        try:
            txt = open(fanp).read()
        except Exception:
            txt = ""
        mode = "thinkpad_acpi"
        status = "unknown"
        level = "unknown"
        rpm = None
        m = re.search(r"status:\s*(\w+)", txt)
        if m: status = m.group(1)
        m = re.search(r"level:\s*([a-z0-7\-]+)", txt)
        if m: level = m.group(1)
        m = re.search(r"speed:\s*(\d+)", txt)
        if m:
            try: rpm = float(m.group(1))
            except Exception: rpm = None
        return {"mode": mode, "status": status, "level": level, "rpm": rpm}
    return {"mode": "unknown", "status": "unknown", "level": "unknown", "rpm": None}

def classify_state(t):
    if t is None:
        return "unknown"
    if t >= 95: return "critical"
    if t >= 85: return "hot"
    if t >= 75: return "warm"
    return "normal"

def main():
    cpu  = read_cpu_temp()
    gpu  = read_gpu_temp()
    nvme = read_nvme_temp()
    temps = {"cpu": cpu, "gpu": gpu, "nvme": nvme}
    # Effective hottest (ignore Nones)
    vals = [v for v in temps.values() if isinstance(v, (int,float))]
    t_eff = max(vals) if vals else None

    fan = read_fan()
    power = get_power_state()
    state = classify_state(t_eff if t_eff is not None else cpu)

    payload = {
        "iso8601": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "t_eff": t_eff,
        "temps": temps,
        "fan": fan,
        "state": state,
        "meta": {"power": power}
    }

    with open(STATUS, "w") as f:
        json.dump(payload, f, indent=2)

if __name__ == "__main__":
    main()
