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

def copy_veyon_keys(root_path):
    """Copy Veyon keys to keys directory structure"""
    logger = get_logger()
    
    # Veyon keys are typically stored in:
    # Windows: C:\ProgramData\Veyon\keys\
    # Or in user profile: %APPDATA%\Veyon\keys\
    
    possible_key_locations = [
        Path(os.environ.get('PROGRAMDATA', 'C:/ProgramData')) / 'Veyon' / 'keys',
        Path(os.environ.get('APPDATA', '')) / 'Veyon' / 'keys',
        Path.home() / '.veyon' / 'keys',  # Linux location
    ]
    
    veyon_keys_dir = None
    for location in possible_key_locations:
        if location.exists():
            veyon_keys_dir = location
            logger.info(f"Found Veyon keys at: {veyon_keys_dir}")
            break
    
    if not veyon_keys_dir:
        logger.warning("Could not find Veyon keys directory. Keys may not have been generated yet.")
        logger.warning("You may need to run Veyon Configurator to generate keys.")
        return False
    
    # Create destination directory structure
    keys_root = root_path / 'keys'
    keys_private = keys_root / 'private' / 'supervisor'
    keys_public = keys_root / 'public' / 'supervisor'
    
    keys_private.mkdir(parents=True, exist_ok=True)
    keys_public.mkdir(parents=True, exist_ok=True)
    
    # Copy keys
    copied_count = 0
    
    # Look for key files
    for key_file in veyon_keys_dir.rglob('*'):
        if key_file.is_file():
            # Determine if private or public key
            if 'private' in key_file.name.lower() or key_file.suffix == '.pem':
                dest = keys_private / 'key'
                shutil.copy2(key_file, dest)
                logger.info(f"Copied private key: {key_file} -> {dest}")
                copied_count += 1
            elif 'public' in key_file.name.lower() or key_file.suffix == '.pub':
                dest = keys_public / 'key'
                shutil.copy2(key_file, dest)
                logger.info(f"Copied public key: {key_file} -> {dest}")
                copied_count += 1
    
    if copied_count > 0:
        logger.info(f"Successfully copied {copied_count} key(s)")
        return True
    else:
        logger.warning("No keys were copied. Generate keys using Veyon Configurator.")
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
        
        # Look for checksum asset
        checksum_asset = None
        for asset in assets:
            name_lower = asset['name'].lower()
            if 'sha256' in name_lower or 'checksum' in name_lower or 'sha256sum' in name_lower:
                checksum_asset = asset
                break
        
        if checksum_asset:
            logger.debug(f"Found checksum asset: {checksum_asset['name']}")
            checksum_response = requests.get(checksum_asset['browser_download_url'], headers=headers)
            checksum_response.raise_for_status()
            checksum_text = checksum_response.text
            checksum = find_checksum_in_text(checksum_text, filename)
            if checksum:
                logger.info(f"Found matching checksum for {filename}")
        
        # Fallback: parse release body
        if not checksum and release.get('body'):
            logger.debug("Attempting to parse release body for checksum")
            checksum = find_checksum_in_text(release['body'], filename)
            if checksum:
                logger.info(f"Found checksum in release body")
        
        if checksum:
            logger.info(f"Remote SHA256: {checksum}")
        else:
            logger.warning("No remote checksum found - will compute local SHA256 only")
        
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
                    result = ctypes.windll.shell32.ShellExecuteW(
                        None, 
                        "runas",  # Trigger UAC
                        str(temp_installer),
                        "/S",  # Silent flag
                        None,
                        1  # SW_SHOWNORMAL
                    )
                    
                    # ShellExecute returns > 32 on success
                    if result <= 32:
                        raise Exception(f"ShellExecute failed with code {result}")
                    
                    logger.info("Installer launched with elevation (UAC prompted)")
                    logger.warning("Waiting 30 seconds for installation to complete...")
                    time.sleep(30)  # Wait for installer to finish
                    exit_code = 0  # Assume success if no error
                    
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
        
        # Copy keys
        logger.info("Attempting to copy Veyon keys...")
        copy_veyon_keys(root_dir)
        
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