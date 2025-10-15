#!/usr/bin/env python3
import sys
import re
import yaml

def validate_semantic_version(version):
    """Validate that the version string follows semantic versioning."""
    pattern = r'^(?P<major>0|[1-9]\d*)\.(?P<minor>0|[1-9]\d*)\.(?P<patch>0|[1-9]\d*)(?:-(?P<prerelease>(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+(?P<buildmetadata>[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$'
    return bool(re.match(pattern, version))

def main():
    try:
        with open('config.yaml', 'r') as f:
            config = yaml.safe_load(f)
            
        version = config.get('version')
        if not version:
            print("Error: No version field found in config.yaml")
            return 1
            
        if not isinstance(version, str):
            print(f"Error: Version must be a string, got {type(version)}")
            return 1
            
        if not validate_semantic_version(version):
            print(f"Error: Version '{version}' does not follow semantic versioning (major.minor.patch)")
            print("Example valid versions: 1.0.0, 2.1.3, 0.1.0")
            return 1
            
        print(f"Version {version} is valid")
        return 0
            
    except yaml.YAMLError as e:
        print(f"Error parsing config.yaml: {e}")
        return 1
    except FileNotFoundError:
        print("Error: config.yaml not found")
        return 1

if __name__ == '__main__':
    sys.exit(main())