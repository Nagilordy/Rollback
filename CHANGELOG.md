# Changelog

What changed in each version of Rollback. Newest first.

Rollback started over at 0.1 with its new name (it was called Frame). The earlier test versions,
0.2 and 0.3, were previews and are no longer listed here.

## 0.1.1 (in testing)

### Faster on small PCs (nothing changes on screen)
- **Windows: video decoded by the graphics card stays there.** Each frame used to be copied
  out to memory and back ("d3d11va-copy"); now it goes straight to the picture, which matters
  most for 4K on integrated graphics.
- **Show pages:** moving between episodes redraws only the episode's details at the top, not
  the whole page.
- **Home:** the backdrops of the cards next to the one you stop on are prepared in advance, so
  moving on crossfades straight away.

### Fixes
- **Windows:** leaving full screen no longer leaves the old "Windows Basic" title bar.
- **Windows:** a little more sound kept ready, so Bluetooth headphones and short stalls don't
  make it crackle.
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
