# Mac Burn-In Test (mac-burnin.command)

One script that tests a used Intel MacBook (2016–2020) before you sell it.
It writes a PASS / WARN / FAIL report for each Mac.

## Download

- **Double-click version (recommended):** [mac-burnin.zip](https://github.com/elipayan98/mac-burnin/raw/main/mac-burnin.zip).
  Safari opens the ZIP. In **Downloads**, double-click `mac-burnin.command`.
- **Terminal, one command:**

  ```
  curl -fsSLO https://raw.githubusercontent.com/elipayan98/mac-burnin/main/mac-burnin.command && bash mac-burnin.command
  ```

Do not download `mac-burnin.command` alone in a browser. The browser removes its "run" permission, and a double-click fails.

## What the script tests

| Part | How | Who |
|---|---|---|
| Activation Lock, MDM, Apple Business Manager, firmware password, SIP | System commands | Automatic |
| Battery: cycles, health %, condition, failure flag | `ioreg`, `system_profiler` | Automatic |
| SSD: SMART, write/read speed, data check, full-disk read | Writes 8 GB, reads it back, compares | Automatic |
| Memory, GPUs (and the AMD GPU on 15"/16"), display, camera, speakers, mic, Wi-Fi, Bluetooth | `system_profiler` | Automatic |
| Wi-Fi speed, internet | `networkQuality`, `curl` | Automatic |
| Screen: dead pixels, bleed, stains, flex cable | Full-screen color page in Safari | Tester looks |
| Keyboard: every key, double-typing (butterfly), typing test | Key map page in Safari | Tester types |
| Trackpad: click, right click, scroll, pinch, force click, drag | Same page | Tester |
| Speakers: left, right, sweep for rattle | Test tones | Tester listens |
| Camera and microphone | Photo Booth | Tester |
| Each charging port, USB data on each port | Script detects the charger / USB device | Tester plugs in |
| Touch Bar, Touch ID, brightness, keyboard light, hinge, headphone jack, swollen battery | Questions | Tester |
| CPU burn-in (hours) | `yes` on every thread | Automatic |
| GPU burn-in | WebGL page in Safari | Automatic |
| Temperature, fan, throttling, charger drops, PROCHOT | Sample every 30 s | Automatic |
| Kernel panics, GPU restarts, WindowServer crashes | Crash report folder | Automatic |
| Battery run-down (optional) | Runs on battery to a set % | Automatic |

## Procedure for each Mac

1. Erase the Mac and install macOS. Make a temporary admin user.
2. Connect to Wi-Fi. Connect the charger.
3. Optional (recommended): restart and hold **D**. Write down the Apple Diagnostics code (ADP000 = no issue).
4. Start the script. Use one of these methods:
   - **USB stick (fastest):** copy the `mac-burnin` folder to a USB stick. Connect the stick. Double-click `mac-burnin.command`.
   - **Download:** download `mac-burnin.zip` in Safari. Safari opens the ZIP. In **Downloads**, double-click `mac-burnin.command`.
   - **Terminal:** type `bash ` (with a space), drag the file into the Terminal window, push **Return**.

   A Terminal window opens and the test starts. The test asks its questions in that window.
   If macOS says it cannot verify the developer (only for a downloaded file):
   - macOS 15 Sequoia or later: click **Done**. Open **System Settings > Privacy & Security**. Scroll down. Click **Open Anyway**. Type the password.
   - macOS 12 to 14: Control-click the file, click **Open**, then click **Open** again.
5. Select a test plan in the menu (type a number, push Return). Then type the admin password.
6. Do the hands-on tests (about 15 minutes). Follow the prompts.
7. Leave the Mac for the burn-in (default 4 hours). Keep the lid open.
8. Come back. Answer the last question about the GPU page.
9. Read the report. The script opens it.
10. Erase the Mac again before you sell it (System Settings > General > Transfer or Reset > Erase All Content and Settings).

Reports go to `~/Desktop/MacBurnIn/<serial>_<date>/`. When the script runs from a USB stick,
it also saves a copy in `MacBurnIn-reports` on the stick. Thus one stick collects the reports for all your Macs.

## Menu

When you start the script with no options (also with a double-click), it shows this menu:

```
Select a test plan:
  1  Full test: checks, hands-on tests, SSD test, 4-hour burn-in (recommended)
  2  Quick test: checks, hands-on tests, SSD test, 30-minute burn-in
  3  Unattended: checks, SSD test, 4-hour burn-in, no questions
  4  Heavy SSD and battery: checks, 64 GB SSD test, 1-hour burn-in, battery stress test to 10%
  5  Checks and hands-on tests only (no burn-in)
  6  Custom: select each test
  q  Quit
```

**Custom** asks for each setting: hands-on tests yes or no, burn-in minutes, SSD test size, and the battery test.
Before the test starts, the script shows the plan and the same plan as a command (for the options below).

## Options

With options, the script starts at once and shows no menu.

```
bash mac-burnin.command                     # no options: shows the menu
bash mac-burnin.command --hours 24          # 1-day burn-in
bash mac-burnin.command --minutes 30        # short burn-in
bash mac-burnin.command --auto              # no questions: automatic checks + SSD + burn-in
bash mac-burnin.command --skip-burnin       # checks + hands-on only
bash mac-burnin.command --battery-rundown 30  # after burn-in, run on battery down to 30 % (light load)
bash mac-burnin.command --battery-stress 10   # after burn-in, run on battery down to 10 % at full CPU + GPU load
bash mac-burnin.command --ssd-gb 16         # bigger SSD data test
```

**Heavy SSD and battery test** (no hands-on tests):

```
bash mac-burnin.command --auto --minutes 60 --ssd-gb 64 --battery-stress 10
```

When the battery test starts, disconnect the charger. The script waits 5 minutes for that, then skips the test.
The battery stress test finds weak batteries: under full load, a weak battery makes the Mac shut down early
(often at 20–40 %). If the Mac shuts down, connect the charger, start the Mac and run the script again.
It then marks the battery FAIL in the report.

## How to read the report

- **FAIL**: fix the fault or tell the buyer. Do **not** sell a Mac with a FAIL in **Locks**
  (Activation Lock, MDM, Apple Business Manager, firmware password). The buyer cannot use that Mac.
- **WARN**: look at the item. Some warnings are normal (for example, no internet).
- **INFO**: data only.
- `samples.csv` has the temperature, fan, throttle and battery data for each 30 seconds.

## If the Mac restarts or shuts down during the test

Run the script again. It finds the test that did not finish. It adds a FAIL to that report
with the last battery %, the macOS shutdown cause code and the kernel panic text (if there is one).

## Limits

- A software test cannot find every fault. Intermittent faults (loose cables, some butterfly keys,
  some logic board faults) can pass today and fail next week.
- It cannot see liquid damage, cosmetic damage, or a bad screen coating. You must look.
- It cannot test RAM directly. Use Apple Diagnostics (hold **D**) for that.
- The script does not wear the SSD much: it writes 8 GB one time (or the `--ssd-gb` size, at most half of the
  free space). During the burn-in it only reads. A 64 GB test takes about 2 to 5 minutes; the screen shows the progress.
- Long burn-ins put heat on the battery. Each run-down uses about one battery cycle, and the stress run-down
  also adds heat. Use them for batteries you doubt (high cycle count, health below about 85 %), not on every Mac.
- MacBook Air 2018–2020 and MacBook 12-inch throttle under full load by design. The script does not mark that as a fault.
- On first run, macOS can ask for permission (Desktop folder, camera, microphone, removable volume). Click **OK**.
- The full-disk SSD read can be blocked by macOS. If the report says so, give Terminal Full Disk Access
  (System Settings > Privacy & Security > Full Disk Access), or ignore it.
