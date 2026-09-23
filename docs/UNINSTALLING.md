# Uninstalling

Before uninstalling, stop any meeting, then save and export notes you want to keep, including notes
in Recently Deleted. Copy `~/Library/Application Support/Vani/Notes` outside Vani's
Application Support directory if you also want its previous/recovery files.
Export meetings you want to keep, or copy `~/Library/Application Support/Vani/Meetings`
to retain their audio and previous records. Then open Vani Settings > General, turn off `Launch Vani at login`, and run:

```bash
./scripts/uninstall-local.sh
```

The script waits for Vani to quit gracefully. If recording cleanup or an unsaved draft
keeps it running, uninstalling stops before removing files or resetting permissions.
Finish saving and quit Vani, then retry; the script never force-quits the app.

This removes the installed app, Vani settings, optional history, learned corrections,
all local Notes and Meetings files (including audio and backups), cache, and Vani's
Microphone, Accessibility and Input Monitoring privacy records. This deletion is permanent.
It keeps the shared FluidAudio speech model by default because
another local app may use it.

To also remove the approximately 443 MiB shared English model:

```bash
./scripts/uninstall-local.sh --remove-model
```

The script does not remove Xcode, Swift, Git, SwiftPM caches, unrelated FluidAudio
models, Ollama or its downloaded models, or the optional `Vani Local Development` keychain identity.
