# Repository Guidelines

## Project Structure & Module Organization

This is a ROCKNIX distribution tree with RetroPixel Pocket work layered into the RK3326 target. Core package definitions live in `packages/` and project-specific overrides live in `projects/ROCKNIX/`. Device-tree work for this port is under `projects/ROCKNIX/devices/RK3326/linux/dts/rockchip/`, especially `rk3326-funnyplaying-rppocket.dts`. Build outputs go to `build.ROCKNIX-RK3326.*` and compressed images go to `target/`.

The `debug/` directory documents hardware bring-up. Use numbered decision logs such as `debug/015-clean-dts-decision-log.txt` for active experiments. Keep `debug/current_state.txt` for accepted project state, not every trial. Factory/vendor references and images are in `original-sources/`.

## Build, Test, and Development Commands

Use:

```bash
make docker-RK3326
```

to build RK3326 images in Docker. Generated images should appear as `target/ROCKNIX-RK3326.aarch64-*.img.gz`.

For hardware flashing, only prompt the user to run `debug/pre.sh --flash /dev/<sdX>` when an image or boot-critical artifact changed. The user performs device testing manually, then reinserts the SD card for inspection. Prefer mounting and reading the card directly over adding summary scripts.

## Coding Style & Naming Conventions

Follow existing ROCKNIX style. Shell scripts use POSIX/Bash-compatible patterns already present in nearby files. Device-tree files use tabs for indentation, lowercase node names, descriptive labels, and existing Rockchip binding names. Keep RPPocket-specific changes scoped to RPPocket files unless a shared change is clearly required.

## Testing Guidelines

Always build before requesting a hardware flash. For DTS changes, verify the compiled DTB with `dtc -I dtb -O dts ...` and inspect the relevant nodes with `rg`. Hardware results must be recorded in the active decision log with hypothesis, change, requested test, observed result, and next step.

## Commit & Pull Request Guidelines

Commits must stay on `retropixel-pocket-support`. Do not commit until the user has manually confirmed the flashed change works. Recent commit messages use short subsystem prefixes, for example `input: map rppocket volume rocker to vendor GPIOs` or `pico8: support retropixel pocket standalone launch`.

Pull requests should explain the hardware problem, summarize tested images, link or reference the relevant `debug/` decision log, and list remaining known issues.

## Agent-Specific Instructions

Do not resurrect `debug/post.sh`; it was intentionally removed. Use `original-sources/` as the primary reference before assuming another RK3326 handheld is compatible. Preserve unrelated dirty work and never reset or revert user changes without explicit instruction.
