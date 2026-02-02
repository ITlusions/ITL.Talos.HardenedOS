# GitHub Actions Workflow Updates

## Summary

Updated `.github/workflows/build-talos-hardened.yaml` to produce a bootable ISO image from the custom Talos installer.

## Changes Made

### 1. Build Branding Assets
- **Removed**: Box-drawing characters and emoji characters from console banner
- **Updated**: Banner to use simple ASCII separators (====)
- **Format**: Clean, portable text-based branding

### 2. Convert Logos Step
- **Added**: Explicit directory creation (`mkdir -p branding/logos` and `branding/output`)
- **Fixed**: Install order for ImageMagick dependencies
- **Added**: `libtext-english-perl` for better compatibility

### 3. Build ISO Job (MAJOR CHANGES)
Previously used Talos Image Factory API, now uses local Docker-based build:

#### Old Approach
```bash
# Requested custom image from Talos factory API
curl -X POST https://factory.talos.dev/schematics
# Downloaded pre-built ISO
curl -Lo iso-output/itl-talos.iso https://factory.talos.dev/image/...
```

#### New Approach
```bash
# Extract from built installer image
docker run --rm -v $(pwd)/iso-output:/out <INSTALLER_IMAGE> \
  bash -c "cp /usr/install/amd64/vmlinuz /out/ && cp /usr/install/amd64/initramfs.xz /out/"

# Build ISO in Docker container
docker run --rm -v $(pwd)/iso-output:/out ubuntu:24.04 \
  bash -c "... xorriso -as mkisofs ..."
```

### Benefits of New Approach
- **Guaranteed Consistency**: ISO built from exact same installer image
- **No External Dependencies**: Doesn't rely on Talos factory service
- **Faster**: No need to wait for external API
- **Reproducible**: Build output is deterministic
- **Better Control**: Can customize ISO building process

### New Workflow Steps

1. **Extract kernel and initramfs from installer**
   - Uses built Docker image from `build-installer` job
   - Extracts: `vmlinuz` and `initramfs.xz`
   - Output: `iso-output/` directory

2. **Build bootable ISO**
   - Uses `xorriso` in Ubuntu container
   - Creates ISO with Rock Ridge and Joliet extensions
   - Supports UEFI boot
   - Output: `itl-talos-v1.9.0.iso`

3. **Generate ISO checksums**
   - SHA256 hash
   - MD5 hash
   - Info file with build metadata

4. **Upload ISO artifact**
   - Retention: 30 days
   - Available for download from workflow run

5. **Create GitHub Release** (when tag is pushed)
   - Automatically creates release with ISO files
   - Includes checksums and info file
   - Supports pre-releases (alpha/beta/rc tags)

## Job Dependencies

```
build-branding
    └─> build-extensions
            └─> build-installer
                    └─> generate-configs
                            └─> build-iso (NEW)
```

## Output Files

When the workflow completes (non-PR runs):

### Artifacts (30-day retention)
- `itl-talos-v1.9.0.iso` - Bootable ISO
- `itl-talos-v1.9.0.iso.sha256` - SHA256 checksum
- `itl-talos-v1.9.0.iso.md5` - MD5 checksum
- `itl-talos-v1.9.0-info.txt` - Build information

### GitHub Release (tag-based only)
All artifact files automatically attached to release when tag is pushed:
```
git tag v1.9.0
git push origin v1.9.0
```

## Logging Standards

All output messages now use simple text format (no emoji/special characters):
- `[*]` - Information/status
- `[>]` - Processing/step
- `[OK]` - Success
- `[!]` - Warning
- `[ERROR]` - Failure (with `$?` exit code)

## Testing the Workflow

### Local Pre-flight Check
```bash
# Validate YAML syntax
yamllint .github/workflows/build-talos-hardened.yaml

# Lint workflow
docker run --rm -v $(pwd):/tmp \
  rhysd/actionlint:latest \
  /tmp/.github/workflows/build-talos-hardened.yaml
```

### Trigger Workflow
```bash
# Manual trigger via dispatch
gh workflow run build-talos-hardened.yaml

# Via tag push
git tag v1.9.0
git push origin v1.9.0

# Check status
gh run list --workflow build-talos-hardened.yaml
gh run view <RUN_ID> --log
```

## Cleanup Notes

- **Removed**: Image Factory integration code
- **Removed**: Factory request JSON generation
- **Removed**: Schematic ID logic
- **Kept**: Configuration generation (still useful for manual deployments)

## Future Improvements

1. Add ISO signature generation (GPG signing)
2. Parallel builds for multiple architectures (arm64, etc.)
3. Integration with release notes generation
4. Automated smoke testing of ISO
5. Direct push to OCI registry for quick deployment

## Related Files

- [build-local.ps1](build-local.ps1) - Local build script (uses same approach)
- [build-iso.ps1](build-iso.ps1) - Local ISO script
- [BUILD_SUMMARY.md](BUILD_SUMMARY.md) - Build documentation

---

**Last Updated**: February 1, 2026
**Workflow Status**: Ready for deployment
