"""
info.py - Display Computer Information
Shows system details: PC name, IP, MAC, BIOS, Windows activation, etc.
"""

import os
import sys
import platform
import socket
import subprocess
import uuid
from pathlib import Path
from datetime import datetime

try:
    from colorama import init, Fore, Style

    init(autoreset=True)
    COLORS = True
except ImportError:
    COLORS = False

# Import logger
sys.path.insert(0, str(Path(__file__).parent))
from logger import get_logger


def get_header(text):
    """Format a section header"""
    if COLORS:
        return f"\n{Fore.CYAN}{'=' * 70}\n{Fore.YELLOW}{text}\n{Fore.CYAN}{'=' * 70}{Style.RESET_ALL}"
    else:
        return f"\n{'=' * 70}\n{text}\n{'=' * 70}"


def get_value_line(label, value, status=None):
    """Format a label-value line with optional status color"""
    if COLORS:
        if status == "good":
            return f"{Fore.WHITE}{label:<30} {Fore.GREEN}{value}{Style.RESET_ALL}"
        elif status == "warning":
            return f"{Fore.WHITE}{label:<30} {Fore.YELLOW}{value}{Style.RESET_ALL}"
        elif status == "bad":
            return f"{Fore.WHITE}{label:<30} {Fore.RED}{value}{Style.RESET_ALL}"
        else:
            return f"{Fore.WHITE}{label:<30} {Fore.CYAN}{value}{Style.RESET_ALL}"
    else:
        return f"{label:<30} {value}"


def run_command(command, shell=True):
    """Run a command and return output"""
    try:
        result = subprocess.run(
            command, shell=shell, capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            return result.stdout.strip()
        return None
    except:
        return None


def get_computer_name():
    """Get computer name"""
    return platform.node() or os.environ.get("COMPUTERNAME", "Unknown")


def get_ip_addresses():
    """Get all IP addresses"""
    ips = []
    try:
        # Get hostname
        hostname = socket.gethostname()
        # Get all IP addresses for this host
        addrs = socket.getaddrinfo(hostname, None)
        for addr in addrs:
            ip = addr[4][0]
            # Filter out IPv6 link-local and loopback
            if (
                not ip.startswith("fe80")
                and not ip.startswith("::1")
                and ip != "127.0.0.1"
            ):
                if ip not in ips:
                    ips.append(ip)
    except:
        pass

    return ips if ips else ["Unable to determine"]


def get_mac_address():
    """Get MAC address"""
    try:
        mac = ":".join(
            [
                "{:02x}".format((uuid.getnode() >> elements) & 0xFF)
                for elements in range(0, 2 * 6, 2)
            ][::-1]
        )
        return mac.upper()
    except:
        return "Unknown"


def get_windows_version():
    """Get detailed Windows version"""
    try:
        # Use wmic to get OS info
        result = run_command("wmic os get Caption,Version,BuildNumber /format:list")
        if result:
            info = {}
            for line in result.split("\n"):
                if "=" in line:
                    key, value = line.split("=", 1)
                    info[key.strip()] = value.strip()

            caption = info.get("Caption", "Windows")
            version = info.get("Version", "")
            build = info.get("BuildNumber", "")

            return f"{caption} (Build {build})"

        # Fallback
        return f"{platform.system()} {platform.release()}"
    except:
        return f"{platform.system()} {platform.release()}"


def get_windows_activation():
    """Check Windows activation status"""
    try:
        result = run_command("cscript //NoLogo C:\\Windows\\System32\\slmgr.vbs /xpr")
        if result:
            if "permanently activated" in result.lower():
                return ("Activated (Permanent)", "good")
            elif "will expire" in result.lower():
                return (result, "warning")
            else:
                return ("Not Activated", "bad")

        # Alternative check
        result = run_command(
            'wmic path softwarelicensingproduct where "PartialProductKey<>null" get LicenseStatus /value'
        )
        if result and "LicenseStatus=1" in result:
            return ("Activated", "good")

        return ("Unable to determine", None)
    except:
        return ("Unable to determine", None)


def get_bios_info():
    """Get BIOS information"""
    try:
        result = run_command(
            "wmic bios get Manufacturer,Name,Version,ReleaseDate /format:list"
        )
        if result:
            info = {}
            for line in result.split("\n"):
                if "=" in line:
                    key, value = line.split("=", 1)
                    info[key.strip()] = value.strip()

            return {
                "manufacturer": info.get("Manufacturer", "Unknown"),
                "version": info.get("Version", "Unknown"),
                "name": info.get("Name", "Unknown"),
                "date": (
                    info.get("ReleaseDate", "Unknown")[:8]
                    if info.get("ReleaseDate")
                    else "Unknown"
                ),
            }
    except:
        pass

    return {
        "manufacturer": "Unknown",
        "version": "Unknown",
        "name": "Unknown",
        "date": "Unknown",
    }


def get_secure_boot_status():
    """Check Secure Boot status"""
    try:
        # Method 1: Check via PowerShell
        result = run_command('powershell -Command "Confirm-SecureBootUEFI"')
        if result:
            if "True" in result:
                return ("Enabled", "good")
            elif "False" in result:
                return ("Disabled", "warning")

        # Method 2: Check registry
        result = run_command(
            'reg query "HKLM\\SYSTEM\\CurrentControlSet\\Control\\SecureBootStateN" /v UEFISecureBootEnabled'
        )
        if result:
            if "0x1" in result:
                return ("Enabled", "good")
            elif "0x0" in result:
                return ("Disabled", "warning")

        return ("Not Supported / Unable to determine", None)
    except:
        return ("Unable to determine", None)


def get_time_sync_status():
    """Check if time synchronization is working"""
    try:
        result = run_command("w32tm /query /status")
        if result:
            if "error" in result.lower():
                return ("Not Syncing", "bad")

            # Look for last successful sync
            for line in result.split("\n"):
                if "Last Successful Sync Time" in line:
                    if "unspecified" not in line.lower():
                        return ("Syncing", "good")

            # Check if service is running
            if "source" in result.lower():
                return ("Syncing", "good")

            return ("Not Syncing", "warning")

        return ("Unable to determine", None)
    except:
        return ("Unable to determine", None)


def get_system_model():
    """Get system manufacturer and model"""
    try:
        result = run_command("wmic computersystem get Manufacturer,Model /format:list")
        if result:
            info = {}
            for line in result.split("\n"):
                if "=" in line:
                    key, value = line.split("=", 1)
                    info[key.strip()] = value.strip()

            manufacturer = info.get("Manufacturer", "Unknown")
            model = info.get("Model", "Unknown")

            return f"{manufacturer} {model}"
    except:
        pass

    return "Unknown"


def get_processor_info():
    """Get processor information"""
    try:
        result = run_command("wmic cpu get Name /format:list")
        if result:
            for line in result.split("\n"):
                if "Name=" in line:
                    return line.split("=", 1)[1].strip()
    except:
        pass

    return platform.processor() or "Unknown"


def get_ram_info():
    """Get RAM information"""
    try:
        result = run_command("wmic computersystem get TotalPhysicalMemory /format:list")
        if result:
            for line in result.split("\n"):
                if "TotalPhysicalMemory=" in line:
                    bytes_ram = int(line.split("=", 1)[1].strip())
                    gb_ram = bytes_ram / (1024**3)
                    return f"{gb_ram:.2f} GB"
    except:
        pass

    return "Unknown"


def get_disk_info():
    """Get primary disk information"""
    try:
        result = run_command(
            "wmic logicaldisk where \"DeviceID='C:'\" get Size,FreeSpace /format:list"
        )
        if result:
            info = {}
            for line in result.split("\n"):
                if "=" in line:
                    key, value = line.split("=", 1)
                    info[key.strip()] = value.strip()

            if "Size" in info and "FreeSpace" in info:
                total_bytes = int(info["Size"])
                free_bytes = int(info["FreeSpace"])

                total_gb = total_bytes / (1024**3)
                free_gb = free_bytes / (1024**3)
                used_gb = total_gb - free_gb
                percent_used = (used_gb / total_gb) * 100

                status = (
                    "good"
                    if percent_used < 80
                    else "warning" if percent_used < 90 else "bad"
                )

                return (
                    f"{used_gb:.1f} GB / {total_gb:.1f} GB ({percent_used:.1f}% used)",
                    status,
                )
    except:
        pass

    return ("Unknown", None)


def get_uptime():
    """Get system uptime"""
    try:
        result = run_command("wmic os get LastBootUpTime /format:list")
        if result:
            for line in result.split("\n"):
                if "LastBootUpTime=" in line:
                    boot_time_str = line.split("=", 1)[1].strip()
                    # Parse format: 20260215192345.500000+120
                    if boot_time_str:
                        year = int(boot_time_str[0:4])
                        month = int(boot_time_str[4:6])
                        day = int(boot_time_str[6:8])
                        hour = int(boot_time_str[8:10])
                        minute = int(boot_time_str[10:12])
                        second = int(boot_time_str[12:14])

                        boot_time = datetime(year, month, day, hour, minute, second)
                        uptime = datetime.now() - boot_time

                        days = uptime.days
                        hours = uptime.seconds // 3600
                        minutes = (uptime.seconds % 3600) // 60

                        if days > 0:
                            return (
                                f"{days} day(s), {hours} hour(s), {minutes} minute(s)"
                            )
                        elif hours > 0:
                            return f"{hours} hour(s), {minutes} minute(s)"
                        else:
                            return f"{minutes} minute(s)"
    except:
        pass

    return "Unknown"


def show_computer_info():
    """Main function to display all computer information"""
    logger = get_logger()
    logger.info("info: Gathering computer information...")

    print(get_header("COMPUTER INFORMATION"))

    # Basic Information
    print(get_header("Basic Information"))
    print(get_value_line("Computer Name:", get_computer_name()))
    print(get_value_line("System Model:", get_system_model()))
    print(get_value_line("Processor:", get_processor_info()))
    print(get_value_line("RAM:", get_ram_info()))

    disk_info, disk_status = get_disk_info()
    print(get_value_line("Disk (C:) Usage:", disk_info, disk_status))

    print(get_value_line("System Uptime:", get_uptime()))

    # Network Information
    print(get_header("Network Information"))
    ips = get_ip_addresses()
    for i, ip in enumerate(ips):
        label = "IP Address:" if i == 0 else ""
        print(get_value_line(label, ip))

    print(get_value_line("MAC Address:", get_mac_address()))

    # Operating System
    print(get_header("Operating System"))
    print(get_value_line("Windows Version:", get_windows_version()))

    activation, activation_status = get_windows_activation()
    print(get_value_line("Activation Status:", activation, activation_status))

    # BIOS Information
    print(get_header("BIOS / UEFI Information"))
    bios = get_bios_info()
    print(get_value_line("Manufacturer:", bios["manufacturer"]))
    print(get_value_line("Version:", bios["version"]))
    print(get_value_line("Release Date:", bios["date"]))

    # Security
    print(get_header("Security"))
    secure_boot, secure_boot_status = get_secure_boot_status()
    print(get_value_line("Secure Boot:", secure_boot, secure_boot_status))

    # Time Sync
    print(get_header("Time Synchronization"))
    time_sync, time_sync_status = get_time_sync_status()
    print(get_value_line("Time Sync Status:", time_sync, time_sync_status))
    print(get_value_line("Current Time:", datetime.now().strftime("%Y-%m-%d %H:%M:%S")))

    print("\n" + "=" * 70)

    logger.info("info: Information display completed")


if __name__ == "__main__":
    from logger import init_logger

    init_logger()
    show_computer_info()
