"""
install_student.py - Install for Students
- Downloads Veyon and stages to local disk for UAC compatibility
- Installs silently (Client only)
- Interactive key distribution with secondary elevation prompt
"""

import os
import sys
import re
import hashlib
import tempfile
import shutil
import subprocess
import time
import ctypes
from pathlib import Path

import requests

# Try to import pywin32 for better process tracking
try:
    import win32api
    import win32event
    import win32process
    from win32com.shell import shell, shellcon

    HAS_PYWIN32 = True
except ImportError:
    HAS_PYWIN32 = False

# Import logger
sys.path.insert(0, str(Path(__file__).parent))
from logger import get_logger


def is_admin():
    """Check if script is running with administrator privileges"""
    if sys.platform != "win32":
        return True  # On non-Windows, assume we have needed privileges

    try:
        return ctypes.windll.shell32.IsUserAnAdmin()
    except:
        return False


def get_file_sha256(filepath):
    sha256_hash = hashlib.sha256()
    with open(filepath, "rb") as f:
        for byte_block in iter(lambda: f.read(4096), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest().lower()


def download_file_with_progress(url, destination):
    logger = get_logger()
    response = requests.get(url, stream=True, headers={"User-Agent": "Python"})
    response.raise_for_status()
    total_size = int(response.headers.get("content-length", 0))
    downloaded = 0
    with open(destination, "wb") as f:
        for chunk in response.iter_content(chunk_size=8192):
            if chunk:
                f.write(chunk)
                downloaded += len(chunk)
                if total_size > 0:
                    percent = int((downloaded / total_size) * 100)
                    print(f"\rDownloading: {percent}%", end="")
    print()


def distribute_keys_to_veyon(root_path):
    """Copy keys from PWD to Veyon Data folder. Prompt for elevation if denied."""
    logger = get_logger()
    keys_source = root_path / "keys"
    veyon_keys_destination = (
        Path(os.environ.get("PROGRAMDATA", "C:/ProgramData")) / "Veyon" / "keys"
    )

    if not keys_source.exists():
        logger.error(f"Keys directory not found at: {keys_source}")
        logger.error("=" * 70)
        logger.error("STUDENT INSTALLATION REQUIRES TEACHER'S PUBLIC KEY")
        logger.error("=" * 70)
        print("\n" + "!" * 70)
        print("ERROR: No keys directory found!")
        print("!" * 70)
        print("\nStudent installation requires the teacher's public key.")
        print("\nTo fix this:")
        print("  1. On the TEACHER computer:")
        print("     - Run menu.py")
        print("     - Choose option 1 (install_teacher.py)")
        print("     - This creates keys in the 'keys/' directory")
        print("")
        print("  2. Copy the 'keys/' directory from teacher computer to:")
        print(f"     {root_path / 'keys'}")
        print("")
        print("  3. The keys directory should contain:")
        print("     keys/")
        print("       └── public/")
        print("           └── supervisor/")
        print("               └── key")
        print("")
        print("  4. Re-run this student installation")
        print("!" * 70)
        input("\nPress Enter to continue...")
        return False

    # Check if public key exists
    public_key = keys_source / "public" / "supervisor" / "key"
    if not public_key.exists():
        logger.error(f"Public key not found at: {public_key}")
        logger.error("Keys directory exists but public key is missing")
        print("\n" + "!" * 70)
        print("ERROR: Public key not found!")
        print("!" * 70)
        print(f"\nExpected location: {public_key}")
        print("\nThe keys directory structure should be:")
        print("  keys/")
        print("    └── public/")
        print("        └── supervisor/")
        print("            └── key  ← This file is missing!")
        print("\nPlease get the complete keys directory from the teacher computer.")
        print("!" * 70)
        input("\nPress Enter to continue...")
        return False

    logger.info(f"Found public key at: {public_key}")
    logger.info(f"Distributing keys to: {veyon_keys_destination}")

    try:
        # 1. Attempt standard copy
        veyon_keys_destination.parent.mkdir(parents=True, exist_ok=True)
        if veyon_keys_destination.exists():
            shutil.rmtree(veyon_keys_destination)
        shutil.copytree(keys_source, veyon_keys_destination)
        logger.info("Keys distributed successfully.")
        return True

    except PermissionError:
        # 2. Permission denied - only prompt if not already admin
        if is_admin():
            logger.error("Permission denied even though running as administrator!")
            logger.error("This should not happen. Check folder permissions.")
            return False

        # Not admin - prompt for elevation
        print("\n" + "!" * 60)
        print("Permission is denied to move the keys to the Data folder.")
        choice = input("Wanna try with admin rights? (Y/n): ").strip().lower()
        print("!" * 60 + "\n")

        if choice in ["y", "yes", ""]:
            logger.info("Requesting UAC for key distribution...")
            # Use robocopy via elevated cmd. /MIR mirrors the directory.
            # 0 = SW_HIDE (runs in background)
            params = (
                f'/c robocopy "{keys_source}" "{veyon_keys_destination}" /MIR /R:1 /W:1'
            )

            ret = ctypes.windll.shell32.ShellExecuteW(
                None, "runas", "cmd.exe", params, None, 0
            )
            if ret > 32:
                logger.info("Keys distributed successfully via elevated Robocopy.")
                return True
            else:
                logger.error(f"UAC denied or failed (Code: {ret})")
        else:
            logger.warning("User declined elevation. Keys were not copied.")
        return False


def install_student():
    logger = get_logger()
    try:
        logger.info("install_student: Starting")
        script_dir = Path(__file__).parent
        root_dir = script_dir.parent
        temp_dir = script_dir / "temp"
        temp_dir.mkdir(exist_ok=True)

        # GitHub Query
        api_url = "https://api.github.com/repos/veyon/veyon/releases/latest"
        release = requests.get(api_url, headers={"User-Agent": "Python"}).json()
        tag = release["tag_name"]
        asset = next(a for a in release["assets"] if "win64" in a["name"].lower())

        # Download to local temp directory first
        network_installer = temp_dir / asset["name"]
        logger.info(f"Downloading Veyon {tag}...")
        download_file_with_progress(asset["browser_download_url"], network_installer)

        # STAGING: Copy from working directory to local C: temp folder (Fixes UAC "File Not Found" on network drives)
        local_installer = Path(tempfile.gettempdir()) / asset["name"]
        logger.info(f"Staging installer to local disk: {local_installer}")
        shutil.copy2(network_installer, local_installer)

        # Check if already running as admin
        already_admin = is_admin()

        if already_admin:
            # Already admin - install directly without UAC prompt
            logger.info("Already running as administrator - installing directly")

            if HAS_PYWIN32:
                # Use CreateProcess for better control
                process = subprocess.Popen(
                    [str(local_installer), "/S", "/Service"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                logger.info("Installer running... waiting for completion.")
                process.wait()
                exit_code = process.returncode

                if exit_code != 0:
                    logger.warning(f"Installer exited with code {exit_code}")
            else:
                # Fallback without pywin32
                process = subprocess.Popen(
                    [str(local_installer), "/S", "/Service"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                logger.info("Installer running... waiting for completion.")
                process.wait()
                exit_code = process.returncode
        else:
            # Not admin - need to request elevation
            logger.info("Launching installer with UAC elevation...")
            logger.info("Please approve the UAC prompt.")

            if HAS_PYWIN32:
                # Better way: track process handle to wait exactly as long as needed
                sei = {
                    "fMask": shellcon.SEE_MASK_NOCLOSEPROCESS,
                    "lpVerb": "runas",
                    "lpFile": str(local_installer),
                    "lpParameters": "/S /Service",
                    "nShow": 1,
                }
                # Execute and get process handle
                struct_sei = shell.ShellExecuteEx(**sei)
                hProcess = struct_sei["hProcess"]

                if hProcess:
                    logger.info("Installer running... waiting for completion.")
                    win32event.WaitForSingleObject(hProcess, win32event.INFINITE)
                    win32api.CloseHandle(hProcess)
                else:
                    raise Exception("Failed to get installer process handle.")
            else:
                # Fallback if pywin32 is missing
                ret = ctypes.windll.shell32.ShellExecuteW(
                    None, "runas", str(local_installer), "/S /Service", None, 1
                )
                if ret <= 32:
                    raise Exception(f"Installer failed to launch (Error Code: {ret})")
                logger.info("Waiting 45 seconds for installation...")
                time.sleep(45)

        # Cleanup local installer
        if local_installer.exists():
            local_installer.unlink()

        # Step 2: Distribute Keys
        keys_distributed = distribute_keys_to_veyon(root_dir)

        if keys_distributed:
            logger.info("install_student: Completed successfully")
        else:
            logger.warning("install_student: Completed but keys were not distributed")
            logger.warning(
                "You will need to manually import the teacher's public key using Veyon Configurator"
            )

        return True

    except Exception as e:
        logger.error(f"install_student failed: {e}")
        raise


if __name__ == "__main__":
    from logger import init_logger

    init_logger()
    install_student()
