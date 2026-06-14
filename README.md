# qwerty-fretboard

QWERTY keyboard to MIDI fretboard translator.

The repository includes a native macOS menu bar app in addition to the original browser version.

## macOS app

- Creates a virtual CoreMIDI source named `qwerty-fretboard`.
- Toggle MIDI keyboard capture with `Control + Option + Command + Space`.
- When MIDI mode is inactive, typing passes through normally.
- When MIDI mode is active, fretboard/control keys are captured and sent as MIDI instead of typing into the front app.
- The menu bar icon is a template keyboard icon so macOS adapts it to the menu bar appearance.
- Optional mini fretboard overlay highlights notes as they are played.
- Settings include velocity, transpose, bend range, overlay visibility, panic/all notes off, and a key reference.

Build and run:

```sh
./script/build_and_run.sh --verify
```

For global keyboard capture, macOS may require Accessibility/Input Monitoring permission for the app.

## Browser version

The original browser version is still available at:

https://santismo.github.io/qwerty-fretboard/

Note: various chord clusters may not be possible on some keyboards due to hardware rollover limitations.
