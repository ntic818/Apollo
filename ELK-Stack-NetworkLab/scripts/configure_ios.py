#!/usr/bin/env python3
"""
Cisco IOS Device Configuration Script for ELK Stack Integration
Configures syslog forwarding, NTP, and monitoring on Cisco devices
"""

import argparse
import sys
import getpass
from typing import List, Dict, Optional
from netmiko import ConnectHandler
from netmiko.exceptions import NetmikoTimeoutException, NetmikoAuthenticationException
import yaml
import json
from datetime import datetime


class CiscoConfigurator:
    """Configure Cisco IOS devices for ELK integration"""
    
    def __init__(self, device: Dict[str, str], verbose: bool = False):
        self.device = device
        self.verbose = verbose
        self.connection = None
        
    def connect(self) -> bool:
        """Establish connection to device"""
        try:
            print(f"Connecting to {self.device['host']}...")
            self.connection = ConnectHandler(**self.device)
            
            if self.verbose:
                print(f"✓ Connected to {self.connection.find_prompt()}")
            
            return True
            
        except NetmikoTimeoutException:
            print(f"✗ Connection timeout to {self.device['host']}")
            return False
            
        except NetmikoAuthenticationException:
            print(f"✗ Authentication failed for {self.device['host']}")
            return False
            
        except Exception as e:
            print(f"✗ Connection error: {e}")
            return False
    
    def disconnect(self):
        """Close connection to device"""
        if self.connection:
            self.connection.disconnect()
            if self.verbose:
                print("✓ Disconnected")
    
    def backup_config(self) -> str:
        """Backup current configuration"""
        try:
            print("Creating configuration backup...")
            config = self.connection.send_command("show running-config")
            
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"backups/{self.device['host']}_{timestamp}.cfg"
            
            with open(filename, 'w') as f:
                f.write(config)
            
            print(f"✓ Backup saved: {filename}")
            return filename
            
        except Exception as e:
            print(f"⚠ Backup failed: {e}")
            return None
    
    def configure_syslog(self, syslog_servers: List[str], 
                        facility: str = "local0",
                        severity: str = "informational") -> bool:
        """Configure syslog forwarding"""
        try:
            print("Configuring syslog...")
            
            commands = [
                "service timestamps debug datetime msec localtime show-timezone",
                "service timestamps log datetime msec localtime show-timezone",
                f"logging trap {severity}",
                f"logging facility {facility}",
                "logging source-interface Loopback0",
            ]
            
            # Add syslog servers
            for server in syslog_servers:
                commands.append(f"logging host {server}")
            
            output = self.connection.send_config_set(commands)
            
            if self.verbose:
                print(output)
            
            # Verify configuration
            verify = self.connection.send_command("show logging | include Trap|Facility|Logging to")
            print("✓ Syslog configured:")
            print(verify)
            
            return True
            
        except Exception as e:
            print(f"✗ Syslog configuration failed: {e}")
            return False
    
    def configure_ntp(self, ntp_servers: List[str]) -> bool:
        """Configure NTP"""
        try:
            print("Configuring NTP...")
            
            commands = []
            for server in ntp_servers:
                commands.append(f"ntp server {server}")
            
            output = self.connection.send_config_set(commands)
            
            if self.verbose:
                print(output)
            
            # Verify NTP
            verify = self.connection.send_command("show ntp associations")
            print("✓ NTP configured:")
            print(verify)
            
            return True
            
        except Exception as e:
            print(f"✗ NTP configuration failed: {e}")
            return False
    
    def configure_snmp(self, snmp_config: Dict[str, str]) -> bool:
        """Configure SNMP"""
        try:
            print("Configuring SNMP...")
            
            commands = [
                f"snmp-server community {snmp_config['community']} RO",
                f"snmp-server location {snmp_config['location']}",
                f"snmp-server contact {snmp_config['contact']}",
                "snmp-server enable traps syslog",
                "snmp-server enable traps config",
            ]
            
            if 'trap_server' in snmp_config:
                commands.append(f"snmp-server host {snmp_config['trap_server']} version 2c {snmp_config['community']}")
            
            output = self.connection.send_config_set(commands)
            
            if self.verbose:
                print(output)
            
            print("✓ SNMP configured")
            return True
            
        except Exception as e:
            print(f"✗ SNMP configuration failed: {e}")
            return False
    
    def configure_logging_buffers(self, buffer_size: int = 51200) -> bool:
        """Configure local logging buffers"""
        try:
            print("Configuring logging buffers...")
            
            commands = [
                f"logging buffered {buffer_size}",
                "logging console warnings",
                "logging monitor warnings",
            ]
            
            output = self.connection.send_config_set(commands)
            
            if self.verbose:
                print(output)
            
            print("✓ Logging buffers configured")
            return True
            
        except Exception as e:
            print(f"✗ Buffer configuration failed: {e}")
            return False
    
    def save_config(self) -> bool:
        """Save configuration to startup-config"""
        try:
            print("Saving configuration...")
            output = self.connection.save_config()
            
            if self.verbose:
                print(output)
            
            print("✓ Configuration saved")
            return True
            
        except Exception as e:
            print(f"✗ Save failed: {e}")
            return False
    
    def verify_configuration(self) -> Dict[str, bool]:
        """Verify all configurations"""
        results = {
            'syslog': False,
            'ntp': False,
            'snmp': False,
        }
        
        try:
            # Check syslog
            syslog_output = self.connection.send_command("show logging | include Logging to")
            results['syslog'] = "Logging to" in syslog_output and len(syslog_output) > 0
            
            # Check NTP
            ntp_output = self.connection.send_command("show ntp associations")
            results['ntp'] = "configured" in ntp_output or "synced" in ntp_output
            
            # Check SNMP
            snmp_output = self.connection.send_command("show snmp community")
            results['snmp'] = len(snmp_output) > 0
            
        except Exception as e:
            print(f"⚠ Verification error: {e}")
        
        return results


def load_config_file(config_file: str) -> Dict:
    """Load configuration from YAML file"""
    try:
        with open(config_file, 'r') as f:
            return yaml.safe_load(f)
    except Exception as e:
        print(f"✗ Failed to load config file: {e}")
        sys.exit(1)


def configure_device(device_config: Dict, elk_config: Dict, 
                    dry_run: bool = False, backup: bool = True) -> bool:
    """Configure a single device"""
    print(f"\n{'='*60}")
    print(f"Configuring: {device_config['host']}")
    print(f"{'='*60}\n")
    
    # Prepare device connection info
    device = {
        'device_type': device_config.get('device_type', 'cisco_ios'),
        'host': device_config['host'],
        'username': device_config['username'],
        'password': device_config['password'],
        'secret': device_config.get('enable_password', device_config['password']),
        'timeout': 30,
    }
    
    configurator = CiscoConfigurator(device, verbose=True)
    
    if not configurator.connect():
        return False
    
    try:
        # Backup configuration
        if backup and not dry_run:
            configurator.backup_config()
        
        # Configure components
        success = True
        
        if 'syslog_servers' in elk_config:
            if not dry_run:
                success &= configurator.configure_syslog(
                    elk_config['syslog_servers'],
                    elk_config.get('syslog_facility', 'local0'),
                    elk_config.get('syslog_severity', 'informational')
                )
            else:
                print("DRY RUN: Would configure syslog")
        
        if 'ntp_servers' in elk_config:
            if not dry_run:
                success &= configurator.configure_ntp(elk_config['ntp_servers'])
            else:
                print("DRY RUN: Would configure NTP")
        
        if 'snmp' in elk_config:
            if not dry_run:
                success &= configurator.configure_snmp(elk_config['snmp'])
            else:
                print("DRY RUN: Would configure SNMP")
        
        if not dry_run:
            success &= configurator.configure_logging_buffers()
        
        # Save configuration
        if success and not dry_run:
            configurator.save_config()
        
        # Verify
        if not dry_run:
            print("\nVerifying configuration...")
            results = configurator.verify_configuration()
            
            for component, status in results.items():
                symbol = "✓" if status else "✗"
                print(f"{symbol} {component}: {'OK' if status else 'FAILED'}")
        
        return success
        
    finally:
        configurator.disconnect()


def main():
    parser = argparse.ArgumentParser(
        description='Configure Cisco IOS devices for ELK Stack integration'
    )
    parser.add_argument(
        '--config',
        required=True,
        help='Path to configuration YAML file'
    )
    parser.add_argument(
        '--device',
        help='Configure specific device (by hostname)'
    )
    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Show what would be configured without making changes'
    )
    parser.add_argument(
        '--no-backup',
        action='store_true',
        help='Skip configuration backup'
    )
    
    args = parser.parse_args()
    
    # Load configuration
    config = load_config_file(args.config)
    
    if 'elk_config' not in config or 'devices' not in config:
        print("✗ Invalid configuration file format")
        sys.exit(1)
    
    # Filter devices if specific device requested
    devices = config['devices']
    if args.device:
        devices = [d for d in devices if d['host'] == args.device]
        if not devices:
            print(f"✗ Device {args.device} not found in configuration")
            sys.exit(1)
    
    # Configure devices
    print(f"\nConfiguring {len(devices)} device(s)...\n")
    
    results = []
    for device in devices:
        success = configure_device(
            device,
            config['elk_config'],
            dry_run=args.dry_run,
            backup=not args.no_backup
        )
        results.append((device['host'], success))
    
    # Summary
    print(f"\n{'='*60}")
    print("Configuration Summary")
    print(f"{'='*60}")
    
    for host, success in results:
        symbol = "✓" if success else "✗"
        status = "SUCCESS" if success else "FAILED"
        print(f"{symbol} {host}: {status}")
    
    successful = sum(1 for _, s in results if s)
    print(f"\nTotal: {successful}/{len(results)} successful")
    
    sys.exit(0 if successful == len(results) else 1)


if __name__ == '__main__':
    main()
