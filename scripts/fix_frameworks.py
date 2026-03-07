import os
import shutil

def fix_framework(framework_path):
    framework_name = os.path.basename(framework_path).replace('.framework', '')
    versions_dir = os.path.join(framework_path, 'Versions')
    version_a_dir = os.path.join(versions_dir, 'A')
    
    if not os.path.exists(version_a_dir):
        return

    current_symlink = os.path.join(versions_dir, 'Current')
    if os.path.islink(current_symlink) or os.path.exists(current_symlink):
        return
        
    print(f"Fixing {framework_path}...")
    cwd = os.getcwd()
    
    # 1. Move root level Resources to Versions/A/Resources
    root_resources = os.path.join(framework_path, 'Resources')
    version_a_resources = os.path.join(version_a_dir, 'Resources')
    if os.path.exists(root_resources) and not os.path.islink(root_resources):
        shutil.move(root_resources, version_a_resources)

    # 2. Move root level binary to Versions/A if needed
    root_binary = os.path.join(framework_path, framework_name)
    version_a_binary = os.path.join(version_a_dir, framework_name)
    if os.path.exists(root_binary) and not os.path.islink(root_binary):
        shutil.move(root_binary, version_a_binary)
        
    try:
        # Create Current symlink
        os.chdir(versions_dir)
        os.symlink('A', 'Current')
        
        # Create root symlinks
        os.chdir(cwd)
        os.chdir(framework_path)
        
        if os.path.exists(f'Versions/Current/{framework_name}'):
            if os.path.exists(framework_name) or os.path.islink(framework_name):
                os.remove(framework_name)
            os.symlink(f'Versions/Current/{framework_name}', framework_name)
            
        if os.path.exists('Versions/Current/Resources'):
            if os.path.exists('Resources') or os.path.islink('Resources'):
                os.remove('Resources')
            os.symlink('Versions/Current/Resources', 'Resources')
            
    finally:
        os.chdir(cwd)

def main():
    import sys
    app_path = sys.argv[1] if len(sys.argv) > 1 else 'dist/Steno.app'
    if not os.path.exists(app_path):
        print(f"App not found at {app_path}")
        return

    # Find all .framework directories
    count = 0
    for root, dirs, files in os.walk(app_path):
        for d in dirs:
            if d.endswith('.framework'):
                fix_framework(os.path.join(root, d))
                count += 1
                
    print(f"Fixed frameworks structure for {count} frameworks.")

if __name__ == '__main__':
    main()
