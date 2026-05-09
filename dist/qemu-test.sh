#!/bin/sh
apk add --no-cache qemu-system-x86_64 seabios 2>/dev/null
echo '=== QEMU boot start ===';timeout 45 qemu-system-x86_64 -cdrom /boot.iso -m 512M -accel tcg -cpu qemu64 -nographic -serial mon:stdio -boot d -no-reboot -net nic,model=virtio -net user 2>&1 || true;echo '=== QEMU boot end ==='