# Troubleshooting

Run the setup doctor first:

```bash
./scripts/doctor.sh
```

## Vani is not in the menu bar

Launch the installed app through macOS Launch Services:

```bash
open /Applications/Vani.app
```

Do not launch `.build` executables directly for final permission testing. macOS grants
privacy access to the exact signed application identity that requested it.

## Permissions stopped working after an update

Dictation needs three separate entries under System Settings > Privacy & Security:

- Microphone
- Accessibility
- Input Monitoring

Meetings also need Screen & System Audio Recording permission on macOS 15 or later.
Starting a meeting requests that permission; the three dictation grants alone do not
authorize Mac audio capture.

macOS attaches these permissions to the app's signing identity. If the setup doctor
reported that `Vani Local Development` was missing, the installer used an ad-hoc
signature. An updated ad-hoc executable can look like a different app to macOS even
though the name and bundle identifier are unchanged. This can leave a visible Vani
switch that turns off again or never changes to Allowed.

### Prevent it on future updates

Create the free `Vani Local Development` identity by following
[Stable local signing](BUILDING.md#stable-local-signing). Reinstall Vani after the
doctor reports `[ok] Stable local signing identity found`. Permissions should then
survive normal rebuilds made with that identity.

### Repair the current installation

1. Create the stable identity above. Do not continue while `./scripts/doctor.sh` still
   reports that it is missing.
2. Install without opening Vani, reset only Vani's permission records, and then launch
   the exact installed app. Apple documents this targeted reset mechanism in
   [Resetting access to protected resources in macOS](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos):

```bash
cd ~/vani
git switch main
git pull --ff-only origin main
./scripts/doctor.sh
VANI_SKIP_OPEN=1 ./scripts/install-local.sh
tccutil reset Microphone com.mrinoy.vani
tccutil reset Accessibility com.mrinoy.vani
tccutil reset ListenEvent com.mrinoy.vani
open /Applications/Vani.app
```

3. Use Vani's Allow buttons, then enable the exact `/Applications/Vani.app` entry in
   all three Privacy & Security panes. If an old or duplicate Vani row remains, remove
   it and add `/Applications/Vani.app` with the `+` button.
4. Quit and reopen Vani after granting Input Monitoring.

These commands do not remove the speech model, settings, snippets, dictionary, or
history. Do not run `sudo tccutil reset All`; that would reset permissions for unrelated
apps. If a targeted reset reports an error, include that exact output in a bug report.

Normal launches with the same stable identity do not require permissions to be reset.
A new bundle identifier, signing identity, ad-hoc executable, or reset privacy database
requires fresh grants.

## Left Fn does not start recording

1. Confirm Vani shows `Ready` and `Left Fn`.
2. Confirm Input Monitoring and Accessibility are enabled for `/Applications/Vani.app`.
3. In System Settings > Keyboard, set "Press Globe key to" to "Do Nothing."
4. Quit and reopen Vani after changing Input Monitoring.

## Signing waits for the keychain

When using `Vani Local Development`, macOS can ask whether `/usr/bin/codesign` may use
the private key. Unlock the login keychain and choose `Always Allow`. To make a one-off
ad-hoc build instead:

```bash
CODESIGN_IDENTITY=- ./scripts/install-local.sh
```

An ad-hoc rebuild can require new permission grants.

## The model does not download

The verified English model is approximately 443 MiB and comes from the pinned
`FluidInference/parakeet-tdt-0.6b-v2-coreml` Hugging Face revision. Check the network
connection and available disk space, then use Vani's Retry action. A failed replacement
does not overwrite an existing valid model.

## Text is ready to paste

Vani keeps the transcript when the focused application changes or macOS does not allow
the paste event. Return to the intended text field and use the recovery action. Do not
repeat the dictation because that creates a second transcript.

## Copied - paste if needed

Vani sent one paste command but the target did not expose enough Accessibility state to
prove the resulting text change. If the text is already present, no action is needed.
If it is missing, press `Cmd+V`; the transcript remains on the clipboard and Vani is
already ready for another recording.

## Reporting a problem

For meeting problems, keep the saved audio until transcript recovery succeeds. Use
**Meeting actions → Recover transcript** to retry pending chunks. If summaries fail,
start the local Ollama service with `qwen3:4b` installed and choose **Generate summary**.
Notes and transcript remain available without that service. See [meeting setup](../README.md#meeting-notes)
and [storage and recovery limits](MEETINGS_DESIGN.md#persistence-and-recovery).

Use the GitHub bug template and include the Vani commit, Mac model, macOS version, and
content-free diagnostic codes. Never attach transcript text, recordings, clipboard
content, or private text-field data.
