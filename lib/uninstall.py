"""
uninstall.py - Veyon Complete Uninstallation Script
- Stops Veyon service
- Runs silent uninstaller
- Removes ProgramData\Veyon folder (including keys)
- Cleans up registry entries (if needed)
"""

import os
import sys
import shutil
import subprocess
import time
from pathlib import Path

# Import logger
sys.path.insert(0, str(Path(__file__).parent))
from logger import get_logger

def stop_veyon_service():
    """Stop Veyon service before uninstalling"""
    logger = get_logger()
    
    logger.info("Stopping Veyon service...")
    
    try:
        # Stop the service using sc stop (we're running as admin now)
        result = subprocess.run(
            ['sc', 'stop', 'VeyonService'],
            capture_output=True,
            text=True,
            timeout=30
        )
        
        if result.returncode == 0:
            logger.info("Veyon service stopped successfully")
            time.sleep(2)  # Wait for service to fully stop
            return True
        elif "not started" in result.stdout.lower() or "does not exist" in result.stdout.lower():
            logger.info("Veyon service is not running or doesn't exist")
            return True
        else:
            logger.warning(f"Service stop returned code {result.returncode}")
            logger.debug(f"Output: {result.stdout}")
            logger.warning("Continuing anyway...")
            return True  # Don't fail on this
            
    except Exception as e:
        logger.warning(f"Error stopping service: {e}")
        logger.warning("Continuing anyway...")
        return True

def find_veyon_uninstaller():
    """Locate the Veyon uninstaller"""
    logger = get_logger()
    
    possible_paths = [
        Path(os.environ.get('PROGRAMFILES', 'C:/Program Files')) / 'Veyon' / 'uninstall.exe',
        Path(os.environ.get('PROGRAMFILES(X86)', 'C:/Program Files (x86)')) / 'Veyon' / 'uninstall.exe',
        Path('C:/Program Files/Veyon/uninstall.exe'),
    ]
    
    for path in possible_paths:
        if path.exists():
            logger.info(f"Found uninstaller at: {path}")
            return path
    
    logger.error("Veyon uninstaller not found!")
    logger.error("Veyon may not be installed or was installed to a custom location.")
    return None

def run_uninstaller(uninstaller_path):
    """Run Veyon uninstaller silently"""
    logger = get_logger()
    
    logger.info(f"Running uninstaller: {uninstaller_path}")
    logger.info("This may take a moment...")
    
    if sys.platform != 'win32':
        logger.warning("Not running on Windows - skipping uninstaller")
        return False
    
    import ctypes
    
    # Check if running as admin
    try:
        is_admin = ctypes.windll.shell32.IsUserAnAdmin()
    except:
        is_admin = False
    
    if not is_admin:
        # This shouldn't happen since we check at the start
        logger.error("Not running as administrator!")
        raise Exception("Administrator privileges required")
    
    # Running as admin - execute directly and track process
    logger.info("Running uninstaller with administrator privileges...")
    
    try:
        process = subprocess.Popen(
            [str(uninstaller_path), '/S'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE
        )
        
        logger.info("Waiting for uninstaller to complete...")
        process.wait()  # This will actually wait!
        
        exit_code = process.returncode
        logger.info(f"Uninstaller exited with code {exit_code}")
        
        if exit_code != 0:
            logger.warning(f"Uninstaller returned non-zero exit code: {exit_code}")
        
        return True
        
    except Exception as e:
        logger.error(f"Failed to run uninstaller: {e}")
        raise

def remove_programdata():
    """Remove Veyon folder from ProgramData (includes keys)"""
    logger = get_logger()
    
    veyon_data_dir = Path(os.environ.get('PROGRAMDATA', 'C:/ProgramData')) / 'Veyon'
    
    if not veyon_data_dir.exists():
        logger.info(f"ProgramData directory not found: {veyon_data_dir}")
        logger.info("Nothing to clean up")
        return True
    
    logger.info(f"Removing ProgramData directory: {veyon_data_dir}")
    
    try:
        # Count files before deletion
        files = list(veyon_data_dir.rglob('*'))
        file_count = len([f for f in files if f.is_file()])
        
        logger.info(f"Found {file_count} file(s) to remove")
        
        # Remove the directory
        shutil.rmtree(veyon_data_dir)
        
        logger.info(f"Successfully removed {veyon_data_dir}")
        logger.info("All Veyon keys and configuration have been deleted")
        
        return True
        
    except PermissionError as e:
        logger.error(f"Permission denied: {e}")
        logger.error("Make sure Veyon is not running and you have administrator privileges")
        return False
    except Exception as e:
        logger.error(f"Failed to remove ProgramData directory: {e}")
        return False

def remove_program_files():
    """Remove Veyon installation directory if it still exists"""
    logger = get_logger()
    
    possible_dirs = [
        Path(os.environ.get('PROGRAMFILES', 'C:/Program Files')) / 'Veyon',
        Path(os.environ.get('PROGRAMFILES(X86)', 'C:/Program Files (x86)')) / 'Veyon',
    ]
    
    removed_any = False
    
    for veyon_dir in possible_dirs:
        if veyon_dir.exists():
            logger.info(f"Removing installation directory: {veyon_dir}")
            
            try:
                shutil.rmtree(veyon_dir)
                logger.info(f"Successfully removed {veyon_dir}")
                removed_any = True
            except Exception as e:
                logger.warning(f"Could not remove {veyon_dir}: {e}")
                logger.warning("This is normal if uninstaller already removed it")
    
    if not removed_any:
        logger.info("No installation directories found to remove")
    
    return True

def uninstall_veyon():
    """Main uninstallation function"""
    logger = get_logger()
    
    try:
        logger.info("uninstall: Starting Veyon removal")
        logger.info("This will completely remove Veyon and all its data")
        
        # Check if running as admin
        if sys.platform == 'win32':
            import ctypes
            try:
                is_admin = ctypes.windll.shell32.IsUserAnAdmin()
            except:
                is_admin = False
            
            if not is_admin:
                logger.warning("Not running as administrator!")
                logger.warning("Attempting to elevate and relaunch uninstall script...")
                
                # Get the path to this script
                script_path = Path(__file__)
                python_exe = sys.executable
                
                try:
                    # Try with pywin32 first for better control
                    try:
                        import win32api
                        import win32event
                        import win32process
                        from win32com.shell import shell, shellcon
                        
                        # Relaunch this script with admin rights
                        sei_mask = shellcon.SEE_MASK_NOCLOSEPROCESS | shellcon.SEE_MASK_NO_CONSOLE
                        sei = shell.ShellExecuteEx(
                            fMask=sei_mask,
                            lpVerb='runas',
                            lpFile=python_exe,
                            lpParameters=f'"{script_path}"',
                            nShow=1
                        )
                        
                        hProcess = sei['hProcess']
                        
                        if hProcess:
                            logger.info("Uninstall script relaunched with elevation (UAC prompted)")
                            logger.info("Waiting for elevated script to complete...")
                            
                            # Wait for process to finish
                            win32event.WaitForSingleObject(hProcess, win32event.INFINITE)
                            
                            # Get exit code
                            exit_code = win32process.GetExitCodeProcess(hProcess)
                            win32api.CloseHandle(hProcess)
                            
                            if exit_code == 0:
                                logger.info("Uninstallation completed successfully")
                            else:
                                logger.warning(f"Elevated script exited with code {exit_code}")
                            
                            return True
                        else:
                            raise Exception("Failed to get process handle")
                    
                    except ImportError:
                        # Fallback to ctypes
                        logger.warning("pywin32 not available, using fallback elevation")
                        
                        result = ctypes.windll.shell32.ShellExecuteW(
                            None,
                            "runas",
                            python_exe,
                            f'"{script_path}"',
                            None,
                            1
                        )
                        
                        if result > 32:
                            logger.info("Uninstall script relaunched with elevation")
                            logger.info("Waiting for completion...")
                            import time
                            time.sleep(3)  # Give it time to start
                            logger.info("Elevated script is running. Check logs for completion.")
                            return True
                        else:
                            raise Exception(f"ShellExecute failed with code {result}")
                
                except Exception as e:
                    logger.error(f"Failed to elevate: {e}")
                    logger.error("Please manually run as Administrator:")
                    logger.error("  Right-click menu.py → 'Run as administrator'")
                    raise Exception(
                        "Could not auto-elevate. Please run as Administrator manually."
                    )
        
        logger.info("Running with administrator privileges")
        
        # Step 1: Stop the service
        logger.info("Step 1: Stopping Veyon service...")
        stop_veyon_service()
        
        # Step 2: Find and run uninstaller
        logger.info("Step 2: Running uninstaller...")
        uninstaller_path = find_veyon_uninstaller()
        
        if uninstaller_path:
            run_uninstaller(uninstaller_path)
            
            # Wait for uninstaller to finish and files to be released
            logger.info("Waiting for uninstaller to complete...")
            time.sleep(5)
        else:
            logger.warning("Uninstaller not found - will try to clean up manually")
        
        # Step 3: Remove ProgramData (keys and config)
        logger.info("Step 3: Removing ProgramData directory...")
        remove_programdata()
        
        # Step 4: Remove installation directory if still present
        logger.info("Step 4: Cleaning up installation directory...")
        remove_program_files()
        
        logger.info("uninstall: Completed successfully")
        logger.info("Veyon has been completely removed from this system")
        
        return True
        
    except Exception as e:
        logger.error(f"uninstall failed: {e}")
        logger.exception("Full traceback:")
        raise

if __name__ == '__main__':
    # If run directly, initialize logger
    from logger import init_logger
    init_logger()
    uninstall_veyon()