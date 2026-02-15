"""
install_teacher.py - Veyon Teacher Installation Script
- Fetches latest Veyon release from GitHub API
- Downloads win64 installer
- Verifies SHA256 checksum
- Installs silently
- Copies generated keys to keys directory
"""

import os
import sys
import re
import hashlib
import tempfile
import shutil
import subprocess
import time
from pathlib import Path

import requests

# Import logger
sys.path.insert(0, str(Path(__file__).parent))
from logger import get_logger

def get_file_sha256(filepath):
    """Calculate SHA256 hash of a file"""
    sha256_hash = hashlib.sha256()
    with open(filepath, "rb") as f:
        for byte_block in iter(lambda: f.read(4096), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest().lower()

def find_checksum_in_text(text, filename):
    """Extract SHA256 checksum from text content"""
    lines = text.split('\n')
    checksum = None
    
    for line in lines:
        # Look for 64-character hex strings (SHA256)
        match = re.search(r'\b([A-Fa-f0-9]{64})\b', line)
        if match:
            hash_value = match.group(1).lower()
            # If line contains our filename, that's our checksum
            if filename in line:
                return hash_value
            # Otherwise, save as fallback
            if checksum is None:
                checksum = hash_value
    
    return checksum

def download_file_with_progress(url, destination):
    """Download file with progress indicator"""
    logger = get_logger()
    
    response = requests.get(url, stream=True, headers={'User-Agent': 'Python'})
    response.raise_for_status()
    
    total_size = int(response.headers.get('content-length', 0))
    block_size = 8192
    downloaded = 0
    
    with open(destination, 'wb') as f:
        for chunk in response.iter_content(chunk_size=block_size):
            if chunk:
                f.write(chunk)
                downloaded += len(chunk)
                
                if total_size > 0:
                    percent = int((downloaded / total_size) * 100)
                    mb_downloaded = downloaded / (1024 * 1024)
                    mb_total = total_size / (1024 * 1024)
                    print(f"\rDownloading: {percent}% ({mb_downloaded:.1f} MB / {mb_total:.1f} MB)", end='')
    
    print()  # New line after progress
    logger.info(f"Download complete: {destination}")

def generate_veyon_keys():
    """Generate Veyon key pair using veyon-cli or verify existing keys"""
    logger = get_logger()
    
    logger.info("Checking for Veyon keys...")
    
    # Check if keys already exist
    keys_dir = Path(os.environ.get('PROGRAMDATA', 'C:/ProgramData')) / 'Veyon' / 'keys'
    private_key = keys_dir / 'private' / 'supervisor' / 'key'
    public_key = keys_dir / 'public' / 'supervisor' / 'key'
    
    # Comprehensive check - look for ANY key files
    if keys_dir.exists():
        # Check for supervisor keys specifically
        if private_key.exists() and public_key.exists():
            logger.info("✓ Supervisor keys already exist")
            logger.info(f"  Private: {private_key}")
            logger.info(f"  Public: {public_key}")
            return True
        
        # Check if ANY keys exist (may have different names)
        all_keys = list(keys_dir.rglob('*'))
        key_files = [f for f in all_keys if f.is_file()]
        
        if len(key_files) > 0:
            logger.info(f"Found {len(key_files)} existing key file(s)")
            
            # Check if supervisor keys exist with different structure
            for key_file in key_files:
                logger.debug(f"  Found: {key_file}")
            
            # If we have both private and public keys (anywhere), use them
            private_keys = [f for f in key_files if 'private' in str(f).lower()]
            public_keys = [f for f in key_files if 'public' in str(f).lower()]
            
            if private_keys and public_keys:
                logger.info("✓ Found existing private and public keys")
                return True
    
    # Keys don't exist - need to generate them
    logger.info("No keys found - generating new supervisor key pair...")
    
    # Find veyon-cli.exe location
    possible_paths = [
        Path(os.environ.get('PROGRAMFILES', 'C:/Program Files')) / 'Veyon' / 'veyon-cli.exe',
        Path(os.environ.get('PROGRAMFILES(X86)', 'C:/Program Files (x86)')) / 'Veyon' / 'veyon-cli.exe',
        Path('C:/Program Files/Veyon/veyon-cli.exe'),
    ]
    
    veyon_cli = None
    for path in possible_paths:
        if path.exists():
            veyon_cli = path
            logger.info(f"Found veyon-cli at: {veyon_cli}")
            break
    
    if not veyon_cli:
        logger.error("veyon-cli.exe not found! Veyon may not be installed correctly.")
        return False
    
    # Generate key pair with name "supervisor"
    max_attempts = 3
    attempt = 0
    
    while attempt < max_attempts:
        attempt += 1
        logger.info(f"Key generation attempt {attempt}/{max_attempts}...")
        
        try:
            # Create key pair
            result = subprocess.run(
                [str(veyon_cli), 'authkeys', 'create', 'supervisor'],
                capture_output=True,
                text=True,
                timeout=30
            )
            
            # Check for "already exist" error
            if "already exist" in result.stderr.lower():
                logger.info("Keys already exist according to veyon-cli")
                
                # Keys exist but we didn't detect them - verify again
                if private_key.exists() and public_key.exists():
                    logger.info("✓ Verified keys exist")
                    return True
                else:
                    # Keys might be elsewhere - do comprehensive search
                    logger.info("Searching for keys in Veyon directory...")
                    all_keys = list(keys_dir.rglob('*')) if keys_dir.exists() else []
                    key_files = [f for f in all_keys if f.is_file()]
                    
                    if len(key_files) >= 2:  # At least private + public
                        logger.info(f"✓ Found {len(key_files)} key files")
                        return True
                    else:
                        logger.warning("veyon-cli says keys exist but cannot find them")
                        logger.warning("Attempting to delete and regenerate...")
                        
                        # Try to delete existing keys
                        delete_result = subprocess.run(
                            [str(veyon_cli), 'authkeys', 'delete', 'supervisor'],
                            capture_output=True,
                            text=True,
                            timeout=30
                        )
                        logger.debug(f"Delete result: {delete_result.returncode}")
                        time.sleep(1)
                        continue
            
            if result.returncode == 0:
                logger.info("✓ Key pair created successfully")
                
                # Verify keys were created
                time.sleep(1)  # Give filesystem time to sync
                
                if private_key.exists() and public_key.exists():
                    logger.info(f"✓ Private key: {private_key}")
                    logger.info(f"✓ Public key: {public_key}")
                    return True
                else:
                    logger.warning("Command succeeded but keys not found - retrying...")
                    time.sleep(2)
                    continue
            else:
                logger.warning(f"Exit code: {result.returncode}")
                if result.stderr:
                    logger.warning(f"Error: {result.stderr.strip()}")
                time.sleep(2)
                
        except subprocess.TimeoutExpired:
            logger.error(f"Key generation timed out on attempt {attempt}")
            time.sleep(2)
        except Exception as e:
            logger.error(f"Key generation error: {e}")
            time.sleep(2)
    
    # Last resort - check one more time if keys exist
    if private_key.exists() and public_key.exists():
        logger.info("✓ Keys found after all attempts")
        return True
    
    logger.error(f"Failed to generate or find keys after {max_attempts} attempts")
    return False


def copy_veyon_keys(root_path):
    """Copy entire Veyon keys directory to PWD"""
    logger = get_logger()
    
    # Veyon keys are stored in C:\ProgramData\Veyon\keys
    veyon_keys_source = Path(os.environ.get('PROGRAMDATA', 'C:/ProgramData')) / 'Veyon' / 'keys'
    
    if not veyon_keys_source.exists():
        logger.error(f"Veyon keys directory not found at: {veyon_keys_source}")
        logger.error("Keys should have been generated but directory doesn't exist!")
        return False
    
    # Check that keys actually exist
    private_key = veyon_keys_source / 'private' / 'supervisor' / 'key'
    public_key = veyon_keys_source / 'public' / 'supervisor' / 'key'
    
    if not private_key.exists():
        logger.error(f"Private key not found at: {private_key}")
        return False
    
    if not public_key.exists():
        logger.error(f"Public key not found at: {public_key}")
        return False
    
    # Destination is PWD/keys/
    keys_destination = root_path / 'keys'
    
    logger.info(f"Copying keys from: {veyon_keys_source}")
    logger.info(f"Copying keys to: {keys_destination}")
    
    try:
        # Remove existing destination if it exists
        if keys_destination.exists():
            try:
                shutil.rmtree(keys_destination)
                logger.debug(f"Removed existing keys directory at {keys_destination}")
            except PermissionError:
                logger.warning("Permission denied removing old keys directory")
                logger.info("Attempting to fix permissions with UAC...")
                
                # Try to remove with elevated PowerShell
                if not remove_directory_elevated(keys_destination):
                    logger.error("Failed to remove old keys directory even with elevation")
                    return False
        
        # Copy entire directory tree
        try:
            shutil.copytree(veyon_keys_source, keys_destination)
        except PermissionError:
            logger.warning("Permission denied copying keys")
            logger.info("Attempting to copy with UAC elevation...")
            
            # Try to copy with elevated PowerShell
            if not copy_directory_elevated(veyon_keys_source, keys_destination):
                logger.error("Failed to copy keys even with elevation")
                return False
        
        # Count copied files
        copied_files = list(keys_destination.rglob('*'))
        file_count = len([f for f in copied_files if f.is_file()])
        
        logger.info(f"Successfully copied {file_count} file(s) from Veyon keys directory")
        
        # Log what was copied
        for file in copied_files:
            if file.is_file():
                relative_path = file.relative_to(keys_destination)
                logger.debug(f"  Copied: keys/{relative_path}")
        
        # Final verification
        dest_private = keys_destination / 'private' / 'supervisor' / 'key'
        dest_public = keys_destination / 'public' / 'supervisor' / 'key'
        
        if not dest_private.exists() or not dest_public.exists():
            logger.error("Keys copied but verification failed!")
            return False
        
        logger.info("✓ Keys verified at destination")
        return True
        
    except Exception as e:
        logger.error(f"Failed to copy keys directory: {e}")
        logger.exception("Full traceback:")
        return False


def remove_directory_elevated(directory_path):
    """Remove directory with UAC elevation using PowerShell"""
    logger = get_logger()
    
    logger.info(f"UAC prompt will appear to remove: {directory_path}")
    
    ps_command = f'Remove-Item -Path "{directory_path}" -Recurse -Force'
    
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
            win32event.WaitForSingleObject(hProcess, win32event.INFINITE)
            exit_code = win32process.GetExitCodeProcess(hProcess)
            win32api.CloseHandle(hProcess)
            
            return exit_code == 0
        
        return False
        
    except ImportError:
        logger.error("pywin32 not available - cannot elevate")
        return False
    except Exception as e:
        logger.error(f"Failed to elevate removal: {e}")
        return False


def copy_directory_elevated(source_path, dest_path):
    """Copy directory with UAC elevation using PowerShell"""
    logger = get_logger()
    
    logger.info(f"UAC prompt will appear to copy keys")
    
    ps_command = f'Copy-Item -Path "{source_path}" -Destination "{dest_path}" -Recurse -Force'
    
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
            win32event.WaitForSingleObject(hProcess, win32event.INFINITE)
            exit_code = win32process.GetExitCodeProcess(hProcess)
            win32api.CloseHandle(hProcess)
            
            return exit_code == 0
        
        return False
        
    except ImportError:
        logger.error("pywin32 not available - cannot elevate")
        return False
    except Exception as e:
        logger.error(f"Failed to elevate copy: {e}")
        return False

def install_teacher():
    """Main installation function"""
    logger = get_logger()
    
    try:
        logger.info("install_teacher: Starting")
        
        # Get script directory and create temp directory
        script_dir = Path(__file__).parent
        root_dir = script_dir.parent
        temp_dir = script_dir / 'temp'
        temp_dir.mkdir(exist_ok=True)
        
        # Query GitHub API
        api_url = 'https://api.github.com/repos/veyon/veyon/releases/latest'
        logger.debug(f"Querying GitHub API: {api_url}")
        
        headers = {'User-Agent': 'Python'}
        response = requests.get(api_url, headers=headers)
        response.raise_for_status()
        release = response.json()
        
        tag = release['tag_name']
        logger.info(f"Latest release: {tag}")
        
        # Find win64 installer asset
        assets = release.get('assets', [])
        if not assets:
            raise Exception(f"No assets found in release {tag}")
        
        asset64 = None
        for asset in assets:
            if 'win64' in asset['name'].lower() or 'win64' in asset['browser_download_url'].lower():
                asset64 = asset
                break
        
        if not asset64:
            raise Exception(f"No win64 asset found in release {tag}")
        
        download_url = asset64['browser_download_url']
        filename = asset64['name']
        logger.info(f"Found asset: {filename}")
        
        # Try to find checksum
        checksum = None
        
        # Look for checksum asset (SHA256SUMS, checksums.txt, etc.)
        checksum_asset = None
        for asset in assets:
            name_lower = asset['name'].lower()
            if any(keyword in name_lower for keyword in ['sha256', 'checksum', 'hash', 'sum']):
                checksum_asset = asset
                logger.debug(f"Found potential checksum asset: {asset['name']}")
                break
        
        if checksum_asset:
            logger.debug(f"Downloading checksum file: {checksum_asset['name']}")
            try:
                checksum_response = requests.get(checksum_asset['browser_download_url'], headers=headers)
                checksum_response.raise_for_status()
                checksum_text = checksum_response.text
                logger.debug(f"Checksum file content:\n{checksum_text[:500]}")  # Log first 500 chars
                checksum = find_checksum_in_text(checksum_text, filename)
                if checksum:
                    logger.info(f"Found matching checksum for {filename}")
            except Exception as e:
                logger.warning(f"Failed to download checksum file: {e}")
        
        # Fallback: parse release body for SHA256
        if not checksum and release.get('body'):
            logger.debug("Attempting to parse release body for checksum")
            checksum = find_checksum_in_text(release['body'], filename)
            if checksum:
                logger.info(f"Found checksum in release body")
        
        if checksum:
            logger.info(f"Remote SHA256: {checksum}")
        else:
            logger.warning("No remote checksum found - will compute local SHA256 only")
            logger.warning("Veyon may not publish SHA256 checksums in releases")
        
        # Download installer
        output_file = temp_dir / filename
        if output_file.exists():
            output_file.unlink()
        
        logger.info(f"Downloading {download_url}")
        download_file_with_progress(download_url, output_file)
        
        # Verify SHA256
        local_hash = get_file_sha256(output_file)
        logger.info(f"Local SHA256: {local_hash}")
        
        if checksum:
            if local_hash != checksum:
                raise Exception(
                    f"SHA256 VERIFICATION FAILED!\n"
                    f"Remote: {checksum}\n"
                    f"Local:  {local_hash}"
                )
            logger.info("SHA256 verified successfully - checksums match!")
        else:
            logger.warning("No remote checksum available for comparison")
            logger.warning(f"Computed local SHA256: {local_hash}")
            logger.warning("Please verify this checksum manually if security is critical")
        
        # Copy to temp directory for installation
        with tempfile.NamedTemporaryFile(delete=False, suffix='.exe', dir=tempfile.gettempdir()) as tmp:
            temp_installer = Path(tmp.name)
        
        shutil.copy2(output_file, temp_installer)
        logger.info(f"Copied installer to: {temp_installer}")
        
        # Run installer silently
        logger.info(f"Starting silent installation: {temp_installer}")
        
        if sys.platform == 'win32':
            # Windows silent install - need elevation
            import ctypes
            
            # Check if running as admin
            try:
                is_admin = ctypes.windll.shell32.IsUserAnAdmin()
            except:
                is_admin = False
            
            if not is_admin:
                logger.warning("Not running as administrator!")
                logger.warning("The installer requires elevation. Attempting to elevate...")
                
                # Use ShellExecute with runas to trigger UAC prompt
                try:
                    import win32api
                    import win32event
                    import win32process
                    from win32com.shell import shell, shellcon
                    
                    # Get process info structure
                    sei_mask = shellcon.SEE_MASK_NOCLOSEPROCESS | shellcon.SEE_MASK_NO_CONSOLE
                    sei = shell.ShellExecuteEx(
                        fMask=sei_mask,
                        lpVerb='runas',
                        lpFile=str(temp_installer),
                        lpParameters='/S',
                        nShow=1
                    )
                    
                    hProcess = sei['hProcess']
                    
                    if hProcess:
                        logger.info("Installer launched with elevation (UAC prompted)")
                        logger.info("Waiting for installer to complete...")
                        
                        # Wait for process to finish (infinite timeout)
                        win32event.WaitForSingleObject(hProcess, win32event.INFINITE)
                        
                        # Get exit code
                        exit_code = win32process.GetExitCodeProcess(hProcess)
                        win32api.CloseHandle(hProcess)
                        
                        logger.info(f"Installer exited with code {exit_code}")
                        
                        if exit_code != 0:
                            logger.warning(f"Installer returned non-zero exit code: {exit_code}")
                    else:
                        raise Exception("Failed to get process handle from elevated installer")
                    
                except ImportError:
                    # Fallback if pywin32 not available
                    logger.warning("pywin32 not available, using fallback method")
                    
                    result = ctypes.windll.shell32.ShellExecuteW(
                        None, 
                        "runas",
                        str(temp_installer),
                        "/S",
                        None,
                        1
                    )
                    
                    if result <= 32:
                        raise Exception(f"ShellExecute failed with code {result}")
                    
                    logger.info("Installer launched with elevation (UAC prompted)")
                    logger.warning("Cannot track process without pywin32. Waiting 30 seconds...")
                    time.sleep(30)
                    exit_code = 0
                    
                except Exception as e:
                    logger.error(f"Failed to elevate installer: {e}")
                    raise Exception(
                        "Installation requires administrator privileges.\n"
                        "Please run this script as Administrator:\n"
                        "  Right-click menu.py → 'Run as administrator'"
                    )
            else:
                # Already admin, run normally
                process = subprocess.Popen(
                    [str(temp_installer), '/S'],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE
                )
                process.wait()
                exit_code = process.returncode
                
                if exit_code != 0:
                    raise Exception(f"Installer exited with code {exit_code}")
                
                logger.info(f"Installer exited with code {exit_code}")
        else:
            logger.warning("Not running on Windows - skipping installation")
            logger.info("On Linux, install Veyon using: sudo apt install veyon")
        
        # Clean up temp installer
        try:
            if temp_installer.exists():
                temp_installer.unlink()
                logger.info(f"Cleaned up temp installer: {temp_installer}")
        except Exception as e:
            logger.warning(f"Failed to clean up temp installer: {e}")
        
        # Wait a moment for installation to complete
        time.sleep(2)
        
        # Generate Veyon keys - retry until successful
        logger.info("Generating Veyon authentication keys...")
        
        keys_generated = generate_veyon_keys()
        
        if not keys_generated:
            raise Exception(
                "CRITICAL ERROR: Failed to generate Veyon keys!\n"
                "The installation cannot continue without keys.\n"
                "Please check the logs and try again."
            )
        
        # Copy keys to PWD
        logger.info("Copying Veyon keys to working directory...")
        keys_copied = copy_veyon_keys(root_dir)
        
        if not keys_copied:
            raise Exception(
                "CRITICAL ERROR: Failed to copy Veyon keys!\n"
                "Keys were generated but could not be copied to PWD.\n"
                "Check permissions and try again."
            )
        
        logger.info("install_teacher: Completed successfully")
        return True
        
    except Exception as e:
        logger.error(f"install_teacher failed: {e}")
        logger.exception("Full traceback:")
        raise

if __name__ == '__main__':
    # If run directly, initialize logger
    from logger import init_logger
    init_logger()
    install_teacher()