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

## A permission still shows Allow

Vani needs three separate entries under System Settings > Privacy & Security:

- Microphone
- Accessibility
- Input Monitoring

Quit Vani, enable the exact `/Applications/Vani.app` entry in each pane, then reopen
the app. If an old or duplicate Vani row exists, remove that row and add the installed
app again. As a last resort, reset only Vani's records and grant them again:

```bash
tccutil reset Microphone com.mrinoy.vani
tccutil reset Accessibility com.mrinoy.vani
tccutil reset ListenEvent com.mrinoy.vani
open /Applications/Vani.app
```

A new bundle identifier, signing identity, ad-hoc executable, or reset privacy database
requires fresh grants. Normal launches with the same stable identity do not.

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

Use the GitHub bug template and include the Vani commit, Mac model, macOS version, and
content-free diagnostic codes. Never attach transcript text, recordings, clipboard
content, or private text-field data.
