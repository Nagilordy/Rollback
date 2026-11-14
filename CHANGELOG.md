# Changelog

What changed in each version of Rollback. Newest first.

Rollback started over at 0.1 with its new name (it was called Frame). The earlier test versions,
0.2 and 0.3, were previews and are no longer listed here.

## 0.1.1 (in testing: Linux and Windows)

The first version for Windows, and an update for Linux (Linux 0.1 stays as released).

### New (Linux and Windows)
- **Deleted films and shows disappear straight away.** Rollback now listens for the server's
  "library changed" message, so a deleted item leaves Home, the library grid and the show page
  without reopening them, and everything else refreshes.
- **Files deleted on the disk disappear too.** Opening a library asks Jellyfin to look through
  its folders for files added or deleted (what "Scan library" does in Jellyfin), at most once
  an hour, for administrator profiles. Deleted videos then leave the grid a few seconds later.

### Faster (nothing changes on screen)
- **The shading over backdrops** (Home, libraries, movie pages) is drawn once into a picture the
  size of the window and shown as is, instead of being drawn from scratch on every frame: that
  alone took about 10 ms of every frame on Windows, more than the rest of Home together. Same
  smooth fade.
- **The dark fade under the rows** (Home, show pages) is drawn the same way: once, then faded in
  and out as a finished picture.
- **Pictures are drawn without extra copies.** Flutter used to build a set of smaller copies
  of every picture the first time it was drawn (for showing it much smaller); Rollback already
  downloads each picture at the size it's shown, so they were never needed. Less work for the
  graphics card each time new artwork appears, same look.
- **Home's backdrop cross-fade** draws each picture straight with its fade, instead of drawing
  both into full-screen off-screen copies on every frame of the fade. Same fade, same timing.
- **Leaving full screen or resizing the window:** pictures are no longer decoded again at every
  in-between size (that briefly used gigabytes of memory and froze Home for seconds).
- **Show pages:** moving between episodes redraws only the episode's details at the top, not
  the whole page.
- **Home:** the backdrops of the cards next to the one you stop on are prepared in advance, so
  moving on crossfades straight away.
- **Cards (Home, libraries, episodes):** the soft shadow under the selected card fades in
  instead of being recalculated every frame as the card grows, and each card sits on its own
  layer, so selecting one no longer redraws the row.

### Windows
- **All seasons window: the selection can't slip away anymore.** The arrows and the controller
  now move around the grid of seasons themselves (one season left or right, one row up or
  down, the shorter last row included) and always stay inside the window. Before, at some
  point the selection could slip out to the show page underneath and seem to disappear.
- **Faster start:** the video engine (the biggest part of Rollback) is now loaded the first
  time a video opens instead of every time Rollback starts, and the window and this device's
  saved details are got ready at the same time instead of one after the other. The perf log
  now says how long Home took to show ("Home shown … ms after start").
- **Moving around Home is much lighter, above all at 4K and in a window:** the soft fade at the
  ends of each row used to redraw the whole row into a see-through layer on every frame a
  card moved. Now only the one or two cards at an edge are faded, each on its own. The same
  for the row of choices in the player (audio, subtitles).
- **Player controls fade in and out more lightly:** they're kept as one finished picture while
  they fade, instead of being redrawn on every frame over the video.
- **No more hitch when coming back from a video:** Home first shows what it had, and refreshes
  Continue Watching a moment later (and not at all if nothing changed), instead of rebuilding
  on the very frames it comes back.
- **Smoother first seconds on Home:** while Rollback starts, it quietly prepares each kind of
  drawing Home uses (rounded artwork, gradients, fades, the soft glow, text), which the
  graphics card otherwise prepared one by one during Home's first moves.
- **PS5 / PS4 controller ready straight away on Windows:** the controller is now read on its own
  thread. Looking for controllers could take Windows several seconds, and on the app's main
  thread that froze Rollback (and the controller) at start-up and every few seconds after.
  New controllers are found the moment Windows reports them plugged in, and also on the very
  first start after installing (Windows only lists a controller to an app once it's asked, so
  Rollback now asks again, instead of needing a restart).
- **Memory and stability with videos (Windows):** each video's picture is now freed properly
  when the player closes, and its Direct3D device with it. Before, every video played could
  leave graphics memory behind, and closing the player could free things in the wrong order.
- **Opening screens is lighter at 4K:** a new screen now comes up out of a dark veil instead of
  fading the whole screen, which redrew it into a see-through layer on every frame. Going back
  is instant.
- **Closing Rollback never waits on the controllers (Windows):** the controller reader isn't
  waited for when the app closes (Windows can take seconds to answer while it looks for
  controllers), and its shared data stays valid until the very end, so closing can't hang or
  crash on it. Closing a show page while it's still loading no longer touches the closed page.
- **No sign-in token in the engine log:** the video engine writes each video's address into
  mpv-<date>.log, and Jellyfin addresses carry the sign-in token. The log is now cleaned (every
  token replaced by "…") as soon as it closes, so it's safe to send along with a report.
- **A PS controller in use no longer seems to disconnect for a moment:** Windows' controller
  list is only re-read while no controller is connected, or when Windows reports a change.
- **Old crash dumps are tidied:** only the 5 newest are kept.
- **The button guide switches to PlayStation symbols when a PS controller is used,** not just
  because one is connected.
- **Crash and error logs (Windows):** if Rollback crashes, crash-<date>.log (what crashed and
  where) and a small crash dump are written to the logs folder, and errors Rollback runs into
  go to errors-<date>.log. Nothing is sent anywhere; they're there to send along with a report.
- **Start screen:** when Rollback takes a moment to start and reach your server, the Rollback
  mark breathes, with soft rings going out like a heartbeat, above "Connecting to" your
  server's name. A quick start goes straight to Home with no added wait.
- **Picking a server:** the card you picked says "Connecting…" while Rollback reaches it.
- **Menus open faster in full screen:** the profile menu and the party panels slide in without
  fading. The fade redrew the whole panel into a see-through layer on every frame, which at 4K
  made opening them feel slow; the dimming behind them still fades in.
- **PS5 and PS4 controllers work on Windows** (USB and Bluetooth, no extra driver): the
  controller library only saw Xbox-style controllers there, so Rollback now reads PlayStation
  controllers itself through Windows' own joystick support. Same buttons as everywhere else,
  with the PlayStation symbols in the button guide.
- **Video decoded by the graphics card stays there:** the picture is now drawn on a Direct3D
  device made with video support, so mpv can hand decoded frames straight to it (`d3d11va`)
  instead of copying each one through memory (`d3d11va-copy`). Less work for small PCs, above
  all in 4K. The engine log (mpv-<date>.log) now starts before the picture is set up, so it
  shows why if a PC still falls back to the copy.
- **Full screen in one step:** Rollback switches with its own window code, in a single move to
  the screen's size and back, instead of passing through several in-between sizes. The window
  keeps its Windows 11 title bar and style the whole time (only hidden while in full screen), so
  the old "Windows Basic" title bar no longer flashes when switching.
- **Smoother resizing:** while the window changes size, the backdrop shading is stretched from
  the picture already made instead of being drawn live on every frame.
- **Resizing and full screen:** pictures are decoded at the new size once the window has
  settled, not at every step of the change.
- **Sound:** a little more kept ready, so Bluetooth headphones and short stalls don't crackle.
- **Engine log:** the first 30 s of each video are logged to `mpv-<date>.log`, next to the perf
  log, to help find problems.

### Fixes
- The log shows the refresh rate of the screen Rollback is on.

## 0.1 (pre-release, Linux)

The first version of Rollback: a couch-first app for Jellyfin, made for a controller and just as
good with a mouse and keyboard. Testing starts on **Linux**; Windows and SteamOS follow.

### Your library
- **Sign in your way:** Rollback finds your Jellyfin server on the network (or type its address),
  then sign in with your password or a Quick Connect code from your phone. Profiles stay signed
  in, and Switch profile is one press away.
- **Home** with the show's artwork full screen, its logo and Resume, then
  Continue watching and Recently added.
- **Libraries** with big posters, watched ticks and progress, and Sort & filter.
- **Show pages** that open on the next episode, with season pills (L2 / R2) and, for long-running
  shows, an All seasons grid. Mark episodes and seasons watched.
- **Movie pages** with the details, Play and Resume.

### Playback
- **The original file, straight from your server,** whenever your computer can play it: 4K,
  TrueHD and DTS sound, and SRT, ASS and PGS subtitles. When a file is too heavy, Rollback
  switches to the version your server converts, at the same moment.
- **Real HDR on Linux.** On a desktop with HDR switched on (KDE Plasma 6, for example), HDR10
  and Dolby Vision films play in real HDR, up to your screen's peak brightness, with the
  controls on top. Switching HDR on or off during a film is followed within a second, and Info
  shows it under Your screen ("HDR · 800 nits"). Elsewhere HDR films get a normal picture.
- **Resume** where you stopped, on any device, and episodes are marked watched at the end.
- **Your audio and subtitle choices are remembered** for each show.

### The player
- **A new design:** a dark bar at the bottom with the timeline (hover it to see the time),
  Audio, Subtitles, Playback and Info showing what's in use, and −10 / play / +30.
- **Audio and Subtitles as big cards,** with subtitle size, position and background you can
  change while watching. With a mouse, the wheel scrolls the cards and arrows appear when
  there are more.
- **Playback** to pick Automatic, the original file or your server's version, and the speed.
- **Info** with the episode's picture and summary, and how it's playing.
- **Up next:** a card with the next episode's picture; Play now fills up as the countdown runs.
- **A loading screen** with the show's artwork and logo while the video starts.

### Watch together
- Start a party from the profile menu, then Play starts any show or movie for everyone;
  friends join from their own Rollback or Jellyfin app.
  Play, pause and jumps stay in sync, with notices like "Maya paused" and each person's initial
  in their colour.

### Getting around
- **PlayStation, Xbox and Steam controllers** work out of the box, with a button guide that
  matches yours. Mouse and keyboard work everywhere; F11 or a double-click goes full screen.
