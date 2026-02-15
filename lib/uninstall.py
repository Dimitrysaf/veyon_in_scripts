"""
uninstall.py - Uninstall Veyon
- Runs uninstaller with UAC elevation
- Asks user if they want to remove data
- Removes ProgramData\Veyon with UAC elevation (if user confirms)
"""

import os
import sys
import subprocess
import time
import ctypes
import stat
from pathlib import Path

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


def find_veyon_uninstaller():
    """Locate the Veyon uninstaller"""
    logger = get_logger()

    possible_paths = [
        Path(os.environ.get("PROGRAMFILES", "C:/Program Files"))
        / "Veyon"
        / "uninstall.exe",
        Path(os.environ.get("PROGRAMFILES(X86)", "C:/Program Files (x86)"))
        / "Veyon"
        / "uninstall.exe",
        Path("C:/Program Files/Veyon/uninstall.exe"),
    ]

    for path in possible_paths:
        if path.exists():
            logger.info(f"Found uninstaller at: {path}")
            return path

    # Just return None silently - caller will handle it
    return None


def run_uninstaller_elevated(uninstaller_path):
    """Run Veyon uninstaller with UAC elevation (only if needed)"""
    logger = get_logger()

    logger.info(f"Running uninstaller: {uninstaller_path}")

    # Check if already admin
    already_admin = is_admin()

    if already_admin:
        # Already admin - run directly without UAC prompt
        logger.info("Already running as administrator - running uninstaller directly")

        try:
            # Use Popen with DETACHED_PROCESS to properly track completion
            DETACHED_PROCESS = 0x00000008
            process = subprocess.Popen(
                [str(uninstaller_path), "/S"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                creationflags=DETACHED_PROCESS,
            )
            logger.info("Uninstaller started... waiting for completion.")

            # Wait for the process to complete
            stdout, stderr = process.communicate(timeout=120)  # 2 minute timeout
            exit_code = process.returncode

            logger.info(f"Uninstaller exited with code {exit_code}")

            if exit_code != 0:
                logger.warning(f"Uninstaller returned non-zero exit code: {exit_code}")

            return exit_code == 0

        except subprocess.TimeoutExpired:
            logger.error("Uninstaller timed out after 120 seconds")
            process.kill()
            return False
        except Exception as e:
            logger.error(f"Failed to run uninstaller: {e}")
            return False
    else:
        # Not admin - request elevation
        logger.info("UAC prompt will appear - please approve")

        try:
            import win32api
            import win32event
            import win32process
            from win32com.shell import shell, shellcon

            # Run uninstaller with elevation
            sei_mask = shellcon.SEE_MASK_NOCLOSEPROCESS | shellcon.SEE_MASK_NO_CONSOLE
            sei = shell.ShellExecuteEx(
                fMask=sei_mask,
                lpVerb="runas",
                lpFile=str(uninstaller_path),
                lpParameters="/S",
                nShow=1,
            )

            hProcess = sei["hProcess"]

            if hProcess:
                logger.info("Uninstaller launched with elevation")
                logger.info("Waiting for uninstaller to complete...")

                win32event.WaitForSingleObject(hProcess, win32event.INFINITE)

                exit_code = win32process.GetExitCodeProcess(hProcess)
                win32api.CloseHandle(hProcess)

                logger.info(f"Uninstaller exited with code {exit_code}")
                return exit_code == 0
            else:
                raise Exception("Failed to get process handle")

        except ImportError:
            logger.error("pywin32 not available - cannot elevate uninstaller")
            logger.error("Install pywin32: pip install pywin32")
            return False
        except Exception as e:
            logger.error(f"Failed to run uninstaller: {e}")
            return False


def remove_readonly(func, path, excinfo):
    """Error handler for shutil.rmtree to handle read-only files"""
    logger = get_logger()
    logger.debug(f"Removing read-only attribute from: {path}")

    # Clear the read-only bit and try again
    try:
        os.chmod(path, stat.S_IWRITE)
        func(path)
    except Exception as e:
        logger.warning(f"Still cannot delete {path}: {e}")


def remove_programdata_elevated():
    """Remove ProgramData folder with UAC elevation (only if needed)"""
    logger = get_logger()

    veyon_data_dir = Path(os.environ.get("PROGRAMDATA", "C:/ProgramData")) / "Veyon"

    if not veyon_data_dir.exists():
        logger.info(f"ProgramData directory not found: {veyon_data_dir}")
        logger.info("Nothing to clean up")
        return True

    try:
        files = list(veyon_data_dir.rglob("*"))
        file_count = len([f for f in files if f.is_file()])
        logger.info(f"Found {file_count} file(s) in ProgramData to remove")
    except:
        pass

    logger.info(f"Removing ProgramData directory: {veyon_data_dir}")

    # Check if already admin
    already_admin = is_admin()

    if already_admin:
        # Already admin - delete directly without UAC prompt
        logger.info("Already running as administrator - removing directory directly")

        try:
            import shutil

            # First, try to remove read-only attributes from all files
            logger.debug("Removing read-only attributes from files...")
            try:
                for root, dirs, files in os.walk(veyon_data_dir):
                    for fname in files:
                        full_path = os.path.join(root, fname)
                        try:
                            os.chmod(full_path, stat.S_IWRITE)
                        except:
                            pass
            except Exception as e:
                logger.debug(f"Error removing read-only attributes: {e}")

            # Now try to remove the directory with error handler
            shutil.rmtree(veyon_data_dir, onerror=remove_readonly)
            logger.info("ProgramData directory removed successfully")
            return True

        except PermissionError as e:
            logger.error(f"Permission denied even with admin rights: {e}")
            logger.info("Attempting elevated PowerShell as fallback...")

            # Fall back to PowerShell elevation
            return remove_with_powershell_elevated(veyon_data_dir)

        except Exception as e:
            logger.error(f"Failed to remove directory: {e}")
            logger.info("Attempting elevated PowerShell as fallback...")

            # Fall back to PowerShell elevation
            return remove_with_powershell_elevated(veyon_data_dir)
    else:
        # Not admin - request elevation
        logger.info("UAC prompt will appear - please approve")
        return remove_with_powershell_elevated(veyon_data_dir)


def remove_with_powershell_elevated(veyon_data_dir):
    """Remove directory using elevated PowerShell"""
    logger = get_logger()

    # PowerShell command to force remove with all attributes cleared
    ps_command = (
        f'Get-ChildItem -Path "{veyon_data_dir}" -Recurse | '
        f'ForEach-Object {{ $_.Attributes = "Normal" }}; '
        f'Remove-Item -Path "{veyon_data_dir}" -Recurse -Force'
    )

    try:
        import win32api
        import win32event
        import win32process
        from win32com.shell import shell, shellcon

        sei_mask = shellcon.SEE_MASK_NOCLOSEPROCESS | shellcon.SEE_MASK_NO_CONSOLE
        sei = shell.ShellExecuteEx(
            fMask=sei_mask,
            lpVerb="runas",
            lpFile="powershell.exe",
            lpParameters=f'-NoProfile -ExecutionPolicy Bypass -Command "{ps_command}"',
            nShow=0,
        )

        hProcess = sei["hProcess"]

        if hProcess:
            logger.info("Folder deletion launched with elevation")
            logger.info("Waiting for deletion to complete...")

            win32event.WaitForSingleObject(hProcess, win32event.INFINITE)

            exit_code = win32process.GetExitCodeProcess(hProcess)
            win32api.CloseHandle(hProcess)

            if exit_code == 0:
                logger.info("ProgramData directory removed successfully")
                return True
            else:
                logger.warning(f"Deletion exited with code {exit_code}")
                return False
        else:
            raise Exception("Failed to get process handle")

    except ImportError:
        logger.error("pywin32 not available - cannot elevate deletion")
        logger.error("Install pywin32: pip install pywin32")
        return False
    except Exception as e:
        logger.error(f"Failed to remove ProgramData: {e}")
        return False


def uninstall_veyon():
    """Main uninstallation function"""
    logger = get_logger()

    try:
        logger.info("uninstall: Starting Veyon removal")
        logger.info("This will uninstall Veyon from your system")

        # Step 1: Stop the service
        logger.info("Step 1: Attempting to stop Veyon service...")
        try:
            result = subprocess.run(
                ["sc", "stop", "VeyonService"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode == 0:
                logger.info("Veyon service stopped")
                time.sleep(2)
            else:
                logger.info("Service may not be running or already stopped")
        except:
            logger.info("Could not stop service - continuing anyway")

        # Step 2: Run uninstaller with UAC (only if needed)
        logger.info("Step 2: Running uninstaller...")
        uninstaller_path = find_veyon_uninstaller()

        if not uninstaller_path:
            logger.warning("Veyon uninstaller not found - Veyon may not be installed")

            # Check if data folder exists
            veyon_data_dir = (
                Path(os.environ.get("PROGRAMDATA", "C:/ProgramData")) / "Veyon"
            )
            if veyon_data_dir.exists():
                logger.info(
                    "However, Veyon data folder exists - offering to clean it up"
                )
            else:
                logger.info("No Veyon installation or data found")
                logger.info("uninstall: Nothing to remove")
                return True  # Success - nothing to do
        else:
            # Run uninstaller (with UAC only if not already admin)
            uninstall_success = run_uninstaller_elevated(uninstaller_path)

            if not uninstall_success:
                logger.warning("Uninstaller may have failed - continuing with cleanup")

            logger.info("Waiting for uninstaller to complete cleanup...")
            time.sleep(3)

        # Step 3: Ask user about data removal
        logger.info("Step 3: ProgramData cleanup...")

        veyon_data_dir = Path(os.environ.get("PROGRAMDATA", "C:/ProgramData")) / "Veyon"

        if veyon_data_dir.exists():
            print("\n" + "=" * 60)
            print("ATTENTION: Veyon configuration and keys still exist")
            print(f"Location: {veyon_data_dir}")
            print("=" * 60)

            response = (
                input("\nDo you want to remove ALL Veyon data (keys, config)? [y/N]: ")
                .strip()
                .lower()
            )

            if response in ["y", "yes"]:
                logger.info("User chose to remove ProgramData")

                remove_success = remove_programdata_elevated()

                if remove_success:
                    logger.info("✓ All Veyon data has been removed")
                else:
                    logger.warning(
                        "Failed to remove ProgramData - may need manual cleanup"
                    )
            else:
                logger.info("User chose to keep ProgramData")
                logger.info(
                    "Keys and configuration preserved at: " + str(veyon_data_dir)
                )
        else:
            logger.info("ProgramData directory already removed by uninstaller")

        logger.info("uninstall: Completed successfully")
        logger.info("Veyon has been removed from this system")

        return True

    except Exception as e:
        logger.error(f"uninstall failed: {e}")
        logger.exception("Full traceback:")
        raise


if __name__ == "__main__":
    from logger import init_logger

    init_logger()
    uninstall_veyon()
