#!/usr/bin/env python3
"""
menu.py - Main Menu for Veyon Installer Suite
Interactive command-line menu for managing Veyon installations
"""

import os
import sys
import importlib.util
from pathlib import Path

try:
    from colorama import init, Fore, Style
    init(autoreset=True)
    COLORS = True
except ImportError:
    COLORS = False
    print("Tip: Install colorama for colored output: pip install colorama")

# Setup paths
SCRIPT_DIR = Path(__file__).parent
LIB_DIR = SCRIPT_DIR / 'lib'
LIB_DIR.mkdir(exist_ok=True)

# Add lib to path
sys.path.insert(0, str(LIB_DIR))

# Import logger
from logger import init_logger, get_logger

# Initialize logger
init_logger(root_path=SCRIPT_DIR)
logger = get_logger()


def clear_screen():
    """Clear the terminal screen"""
    os.system('cls' if os.name == 'nt' else 'clear')


def print_header():
    """Print the menu header"""
    clear_screen()
    
    # Get terminal width
    try:
        cols = os.get_terminal_size().columns
    except:
        cols = 80
    
    if cols < 40:
        cols = 40
    
    title = ' Veyon Installer Suite '
    line = '=' * (cols - 2)
    
    if COLORS:
        print(Fore.CYAN + '+' + line + '+')
        pad_left = (cols - 2 - len(title)) // 2
        pad_right = cols - 2 - len(title) - pad_left
        middle = '|' + (' ' * pad_left) + title + (' ' * pad_right) + '|'
        print(Fore.YELLOW + middle)
        print(Fore.CYAN + '+' + line + '+')
    else:
        print('+' + line + '+')
        pad_left = (cols - 2 - len(title)) // 2
        pad_right = cols - 2 - len(title) - pad_left
        middle = '|' + (' ' * pad_left) + title + (' ' * pad_right) + '|'
        print(middle)
        print('+' + line + '+')


def get_lib_scripts():
    """Get list of Python scripts in lib directory"""
    scripts = []
    try:
        for file in sorted(LIB_DIR.glob('*.py')):
            if file.name not in ['logger.py', '__init__.py']:
                scripts.append(file)
    except Exception as e:
        logger.error(f"Error reading lib directory: {e}")
    
    return scripts


def display_menu():
    """Display the main menu"""
    print_header()
    print()
    
    if COLORS:
        print(Fore.GREEN + "Available Scripts (lib):")
    else:
        print("Available Scripts (lib):")
    
    scripts = get_lib_scripts()
    
    if not scripts:
        if COLORS:
            print(Fore.YELLOW + "  (No scripts found in 'lib' folder.)")
        else:
            print("  (No scripts found in 'lib' folder.)")
    else:
        for i, script in enumerate(scripts, 1):
            description = get_script_description(script)
            
            if COLORS:
                print(Fore.WHITE + f"  {i}) {script.name:<30} {Fore.CYAN}{description}")
            else:
                print(f"  {i}) {script.name:<30} {description}")
    
    print()
    if COLORS:
        print(Fore.LIGHTBLACK_EX + "  r) Reload menu")
        print(Fore.LIGHTBLACK_EX + "  e) Run external script by path")
        print(Fore.MAGENTA + "  0) Exit")
    else:
        print("  r) Reload menu")
        print("  e) Run external script by path")
        print("  0) Exit")
    print()


def get_script_description(script_path):
    """Extract description from script docstring"""
    try:
        with open(script_path, 'r', encoding='utf-8') as f:
            lines = f.readlines()
            # Look for first line of docstring
            for i, line in enumerate(lines):
                if '"""' in line or "'''" in line:
                    # Get the line after opening quotes
                    if i + 1 < len(lines):
                        desc = lines[i + 1].strip()
                        if desc and not desc.startswith(('"""', "'''")):
                            return f"- {desc[:50]}"
                    break
    except:
        pass
    return ""


def run_script(script_path):
    """Dynamically import and run a script"""
    logger.info(f"Running script: {script_path}")
    
    try:
        # Load module dynamically
        spec = importlib.util.spec_from_file_location("script_module", script_path)
        module = importlib.util.module_from_spec(spec)
        sys.modules["script_module"] = module
        spec.loader.exec_module(module)
        
        # Look for main function or run directly
        if hasattr(module, 'install_teacher'):
            module.install_teacher()
        elif hasattr(module, 'install_student'):
            module.install_student()
        elif hasattr(module, 'uninstall_veyon'):
            module.uninstall_veyon()
        elif hasattr(module, 'main'):
            module.main()
        else:
            logger.warning(f"No entry point found in {script_path.name}")
            
    except Exception as e:
        logger.error(f"Script error: {e}")
        logger.exception("Full traceback:")
        if COLORS:
            print(Fore.RED + f"\nScript error: {e}")
        else:
            print(f"\nScript error: {e}")


def main():
    """Main menu loop"""
    logger.info("Menu started")
    
    # Check admin status
    is_admin = False
    if sys.platform == 'win32':
        try:
            import ctypes
            is_admin = ctypes.windll.shell32.IsUserAnAdmin()
        except:
            pass
    
    if COLORS:
        status = f"{Fore.GREEN}✓ Running as Administrator" if is_admin else f"{Fore.YELLOW}⚠ Not running as Administrator"
        print(f"{Fore.CYAN}menu.py: startup OK")
        print(status + Style.RESET_ALL + "\n")
    else:
        status = "✓ Running as Administrator" if is_admin else "⚠ Not running as Administrator"
        print("menu.py: startup OK")
        print(status + "\n")
    
    try:
        while True:
            display_menu()
            
            if COLORS:
                choice = input(Fore.YELLOW + "Choose an option (number/r/e/0): " + Style.RESET_ALL)
            else:
                choice = input("Choose an option (number/r/e/0): ")
            
            logger.debug(f"User choice: {choice}")
            
            # Exit
            if choice == '0':
                logger.info("User requested exit")
                break
            
            # Reload menu
            elif choice.lower() == 'r':
                continue
            
            # Run external script
            elif choice.lower() == 'e':
                path = input("Enter path to script: ").strip()
                
                if not path:
                    if COLORS:
                        print(Fore.YELLOW + "No path provided.")
                    else:
                        print("No path provided.")
                    input("\nPress Enter to continue...")
                    continue
                
                script_path = Path(path)
                if not script_path.exists():
                    if COLORS:
                        print(Fore.RED + f"File not found: {path}")
                    else:
                        print(f"File not found: {path}")
                    input("\nPress Enter to continue...")
                    continue
                
                logger.info(f"Running external script: {path}")
                run_script(script_path)
                input("\nPress Enter to continue...")
            
            # Run numbered script
            else:
                try:
                    index = int(choice) - 1
                    scripts = get_lib_scripts()
                    
                    if 0 <= index < len(scripts):
                        run_script(scripts[index])
                        input("\nPress Enter to continue...")
                    else:
                        if COLORS:
                            print(Fore.YELLOW + "Invalid selection.")
                        else:
                            print("Invalid selection.")
                        input("\nPress Enter to continue...")
                        
                except ValueError:
                    if COLORS:
                        print(Fore.YELLOW + "Invalid input.")
                    else:
                        print("Invalid input.")
                    input("\nPress Enter to continue...")
    
    except KeyboardInterrupt:
        print("\n\nInterrupted by user")
        logger.info("Menu interrupted by user")
    
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        logger.exception("Full traceback:")
        if COLORS:
            print(Fore.RED + f"\nFatal error: {e}")
        else:
            print(f"\nFatal error: {e}")
    
    finally:
        logger.info("Menu exiting")
        if COLORS:
            print(Fore.GREEN + "\nGoodbye!")
        else:
            print("\nGoodbye!")


if __name__ == '__main__':
    main()