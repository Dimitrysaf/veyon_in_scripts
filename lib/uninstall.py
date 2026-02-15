"""
uninstall.py - Veyon Complete Uninstallation Script
- Runs uninstaller with UAC elevation
- Asks user if they want to remove data
- Removes ProgramData\Veyon with UAC elevation (if user confirms)
"""

import os
import sys
import subprocess
import time
from pathlib import Path

# Import logger
sys.path.insert(0, str(Path(__file__).parent))
from logger import get_logger

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
    
    # Just return None silently - caller will handle it
    return None

def run_uninstaller_elevated(uninstaller_path):
    """Run Veyon uninstaller with UAC elevation"""
    logger = get_logger()
    
    logger.info(f"Running uninstaller: {uninstaller_path}")
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
            lpVerb='runas',
            lpFile=str(uninstaller_path),
            lpParameters='/S',
            nShow=1
        )
        
        hProcess = sei['hProcess']
        
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

def remove_programdata_elevated():
    """Remove ProgramData folder with UAC elevation using PowerShell"""
    logger = get_logger()
    
    veyon_data_dir = Path(os.environ.get('PROGRAMDATA', 'C:/ProgramData')) / 'Veyon'
    
    if not veyon_data_dir.exists():
        logger.info(f"ProgramData directory not found: {veyon_data_dir}")
        logger.info("Nothing to clean up")
        return True
    
    try:
        files = list(veyon_data_dir.rglob('*'))
        file_count = len([f for f in files if f.is_file()])
        logger.info(f"Found {file_count} file(s) in ProgramData to remove")
    except:
        pass
    
    logger.info(f"Removing ProgramData directory: {veyon_data_dir}")
    logger.info("UAC prompt will appear - please approve")
    
    ps_command = f'Remove-Item -Path "{veyon_data_dir}" -Recurse -Force'
    
    try:
        import win32api
        import win32event
        import win32process
        from win32com.shell import shell, shellcon
        
        sei_mask = shellcon.SEE_MASK_NOCLOSEPROCESS | shellcon.SEE_MASK_NO_CONSOLE
        sei = shell.ShellExecuteEx(
            fMask=sei_mask,
            lpVerb='runas',
            lpFile='powershell.exe',
            lpParameters=f'-NoProfile -ExecutionPolicy Bypass -Command "{ps_command}"',
            nShow=0
        )
        
        hProcess = sei['hProcess']
        
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
                ['sc', 'stop', 'VeyonService'],
                capture_output=True,
                text=True,
                timeout=10
            )
            if result.returncode == 0:
                logger.info("Veyon service stopped")
                time.sleep(2)
            else:
                logger.info("Service may not be running or already stopped")
        except:
            logger.info("Could not stop service - continuing anyway")
        
        # Step 2: Run uninstaller with UAC
        logger.info("Step 2: Running uninstaller...")
        uninstaller_path = find_veyon_uninstaller()
        
        if not uninstaller_path:
            logger.warning("Veyon uninstaller not found - Veyon may not be installed")
            
            # Check if data folder exists
            veyon_data_dir = Path(os.environ.get('PROGRAMDATA', 'C:/ProgramData')) / 'Veyon'
            if veyon_data_dir.exists():
                logger.info("However, Veyon data folder exists - offering to clean it up")
            else:
                logger.info("No Veyon installation or data found")
                logger.info("uninstall: Nothing to remove")
                return True  # Success - nothing to do
        else:
            # Run uninstaller with UAC
            uninstall_success = run_uninstaller_elevated(uninstaller_path)
            
            if not uninstall_success:
                logger.warning("Uninstaller may have failed - continuing with cleanup")
            
            logger.info("Waiting for uninstaller to complete cleanup...")
            time.sleep(3)
        
        # Step 3: Ask user about data removal
        logger.info("Step 3: ProgramData cleanup...")
        
        veyon_data_dir = Path(os.environ.get('PROGRAMDATA', 'C:/ProgramData')) / 'Veyon'
        
        if veyon_data_dir.exists():
            print("\n" + "=" * 60)
            print("ATTENTION: Veyon configuration and keys still exist")
            print(f"Location: {veyon_data_dir}")
            print("=" * 60)
            
            response = input("\nDo you want to remove ALL Veyon data (keys, config)? [y/N]: ").strip().lower()
            
            if response in ['y', 'yes']:
                logger.info("User chose to remove ProgramData")
                
                remove_success = remove_programdata_elevated()
                
                if remove_success:
                    logger.info("✓ All Veyon data has been removed")
                else:
                    logger.warning("Failed to remove ProgramData - may need manual cleanup")
            else:
                logger.info("User chose to keep ProgramData")
                logger.info("Keys and configuration preserved at: " + str(veyon_data_dir))
        else:
            logger.info("ProgramData directory already removed by uninstaller")
        
        logger.info("uninstall: Completed successfully")
        logger.info("Veyon has been removed from this system")
        
        return True
        
    except Exception as e:
        logger.error(f"uninstall failed: {e}")
        logger.exception("Full traceback:")
        raise

if __name__ == '__main__':
    from logger import init_logger
    init_logger()
    uninstall_veyon()