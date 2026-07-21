# Uninstalling

Before uninstalling, open Vani Settings > General and turn off `Launch Vani at login`.
Then run:

```bash
./scripts/uninstall-local.sh
```

This removes the installed app, Vani settings, optional history, cache, and Vani's
macOS privacy records. It keeps the shared FluidAudio speech model by default because
another local app may use it.

To also remove the approximately 443 MiB shared English model:

```bash
./scripts/uninstall-local.sh --remove-model
```

The script does not remove Xcode, Swift, Git, SwiftPM caches, unrelated FluidAudio
models, or the optional `Vani Local Development` keychain identity.
