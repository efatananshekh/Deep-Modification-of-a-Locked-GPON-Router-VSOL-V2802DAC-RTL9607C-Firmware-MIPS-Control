#!/usr/bin/env python3
"""
firmware_extract.py - Extract and analyze VSOL firmware
Uses binwalk for extraction, provides analysis of filesystem structure
"""

import os
import sys
import subprocess
import argparse
from pathlib import Path

def check_tools():
    """Check required tools are installed"""
    tools = {
        "binwalk": "pip install binwalk",
        "hexdump": "Built-in on Linux/WSL",
        "file": "Built-in on Linux/WSL",
    }
    
    missing = []
    for tool, install in tools.items():
        try:
            subprocess.run([tool, "--version"], capture_output=True)
        except FileNotFoundError:
            print(f"[!] Missing: {tool}")
            print(f"    Install: {install}")
            missing.append(tool)
    
    return len(missing) == 0

def extract_firmware(firmware_path, output_dir=None):
    """Extract firmware using binwalk"""
    
    if not Path(firmware_path).exists():
        print(f"[!] Firmware file not found: {firmware_path}")
        return None
    
    if output_dir is None:
        output_dir = Path(firmware_path).stem + "_extracted"
    
    print(f"[*] Analyzing firmware: {firmware_path}")
    print(f"[*] Output directory: {output_dir}")
    
    # Run binwalk scan first
    print("\n=== Binwalk Signature Scan ===")
    result = subprocess.run(
        ["binwalk", firmware_path],
        capture_output=True, text=True
    )
    print(result.stdout)
    
    # Extract
    print("\n=== Extracting ===")
    result = subprocess.run(
        ["binwalk", "-e", "-C", output_dir, firmware_path],
        capture_output=True, text=True
    )
    print(result.stdout)
    if result.stderr:
        print(result.stderr)
    
    # Find extracted filesystem
    extracted = Path(output_dir)
    if extracted.exists():
        print(f"\n[+] Extraction complete!")
        
        # Look for interesting files
        interesting = [
            "**/passwd",
            "**/shadow",
            "**/etc/config/*",
            "**/*.sh",
            "**/*.conf",
            "**/busybox",
        ]
        
        print("\n=== Interesting Files ===")
        for pattern in interesting:
            for f in extracted.rglob(pattern.replace("**/", "")):
                print(f"  {f}")
        
        return str(extracted)
    
    return None

def analyze_binary(binary_path):
    """Analyze extracted binary"""
    if not Path(binary_path).exists():
        print(f"[!] Binary not found: {binary_path}")
        return
    
    print(f"\n=== Binary Analysis: {binary_path} ===")
    
    # File type
    result = subprocess.run(["file", binary_path], capture_output=True, text=True)
    print(f"Type: {result.stdout.strip()}")
    
    # Strings
    print("\n--- Interesting Strings ---")
    result = subprocess.run(
        ["strings", binary_path],
        capture_output=True, text=True
    )
    
    keywords = ["password", "admin", "root", "shell", "telnet", "debug", "gpon", "serial"]
    for line in result.stdout.split('\n'):
        for kw in keywords:
            if kw.lower() in line.lower() and len(line) < 100:
                print(f"  {line}")
                break

def main():
    parser = argparse.ArgumentParser(description="VSOL Firmware Extractor")
    parser.add_argument("firmware", help="Path to firmware file")
    parser.add_argument("-o", "--output", help="Output directory")
    parser.add_argument("-a", "--analyze", help="Analyze specific binary")
    
    args = parser.parse_args()
    
    if not check_tools():
        print("\n[!] Install missing tools first")
        sys.exit(1)
    
    if args.analyze:
        analyze_binary(args.analyze)
    else:
        extract_firmware(args.firmware, args.output)

if __name__ == "__main__":
    main()
