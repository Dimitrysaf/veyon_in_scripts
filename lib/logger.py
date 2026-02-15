"""
logger.py - Logging module for Veyon Installer Suite
Provides colored console output and file logging
"""

import logging
import os
import sys
from datetime import datetime
from pathlib import Path

try:
    from colorama import init, Fore, Style

    init(autoreset=True)
    COLORS_AVAILABLE = True
except ImportError:
    COLORS_AVAILABLE = False
    print("Warning: colorama not installed. Install with: pip install colorama")


class ColoredFormatter(logging.Formatter):
    """Custom formatter with colors for console output"""

    COLORS = {
        "DEBUG": Fore.CYAN if COLORS_AVAILABLE else "",
        "INFO": Fore.GREEN if COLORS_AVAILABLE else "",
        "WARNING": Fore.YELLOW if COLORS_AVAILABLE else "",
        "ERROR": Fore.RED if COLORS_AVAILABLE else "",
        "CRITICAL": Fore.RED + Style.BRIGHT if COLORS_AVAILABLE else "",
    }

    RESET = Style.RESET_ALL if COLORS_AVAILABLE else ""

    def format(self, record):
        color = self.COLORS.get(record.levelname, "")
        record.levelname = f"{color}{record.levelname}{self.RESET}"
        return super().format(record)


class Logger:
    """Centralized logging manager"""

    def __init__(self, root_path=None, log_level=logging.DEBUG):
        self.root_path = Path(root_path) if root_path else Path.cwd()
        self.logs_dir = self.root_path / "logs"
        self.logs_dir.mkdir(exist_ok=True)

        # Generate log filename: COMPUTERNAME_YYMMDD_HHMMSS.log
        computer_name = os.environ.get(
            "COMPUTERNAME", os.environ.get("HOSTNAME", "UNKNOWN")
        )
        timestamp = datetime.now().strftime("%y%m%d_%H%M%S")
        log_filename = f"{computer_name}_{timestamp}.log"
        self.log_file = self.logs_dir / log_filename

        # Create logger
        self.logger = logging.getLogger("VeyonInstaller")
        self.logger.setLevel(log_level)
        self.logger.handlers.clear()  # Clear any existing handlers

        # File handler (detailed)
        file_handler = logging.FileHandler(self.log_file, encoding="utf-8")
        file_handler.setLevel(logging.DEBUG)
        file_formatter = logging.Formatter(
            "[%(asctime)s] [%(levelname)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
        )
        file_handler.setFormatter(file_formatter)
        self.logger.addHandler(file_handler)

        # Console handler (colored)
        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setLevel(logging.INFO)
        console_formatter = ColoredFormatter("[%(levelname)s] %(message)s")
        console_handler.setFormatter(console_formatter)
        self.logger.addHandler(console_handler)

        self.info(f"Logger initialized. Log file: {self.log_file}")

    def debug(self, message):
        """Log debug message"""
        self.logger.debug(message)

    def info(self, message):
        """Log info message"""
        self.logger.info(message)

    def warning(self, message):
        """Log warning message"""
        self.logger.warning(message)

    def error(self, message):
        """Log error message"""
        self.logger.error(message)

    def critical(self, message):
        """Log critical message"""
        self.logger.critical(message)

    def exception(self, message):
        """Log exception with traceback"""
        self.logger.exception(message)


# Global logger instance
_logger_instance = None


def init_logger(root_path=None, log_level=logging.DEBUG):
    """Initialize the global logger"""
    global _logger_instance
    _logger_instance = Logger(root_path, log_level)
    return _logger_instance


def get_logger():
    """Get the global logger instance"""
    global _logger_instance
    if _logger_instance is None:
        _logger_instance = Logger()
    return _logger_instance
