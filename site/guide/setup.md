# Set up from scratch

New to Jellyfin? This page takes you from nothing to watching on your TV: a Jellyfin server for your films and shows, then Rollback to watch them. It takes about 30 minutes, most of it waiting for Jellyfin to read your library.

Already have a Jellyfin server? Skip to [Part 2: install Rollback](#install-rollback).

![Your films and shows go on a Jellyfin server, a PC or NAS that stays on. Rollback, on the PC by your TV, plays them over your home network.](/guide/overview.svg)

**How it fits together:** your video files live on a computer that stays on, called the **server**. **Jellyfin** runs there: it sorts your files, finds posters and descriptions, and remembers where you stopped. **Rollback** is the app you watch with, on the PC connected to your TV. They can be the same computer.

## Part 1: the Jellyfin server

### What you need

- A computer that can stay on while you watch: a desktop PC, an old laptop, or a NAS (Synology, QNAP, Unraid…).
- Your films and shows on it, or on a drive plugged into it.

### 1. Sort your files {#sort-files}

Jellyfin recognises your videos by their folder and file names. Sort them like this before you start, and every film and episode gets its poster and description:

![Films: a Movies folder with one folder per film named "Title (Year)". Shows: a Shows folder, a folder per show, a "Season 01" folder per season, and S01E01 in each episode's name.](/guide/folders.svg)

- **Films:** one folder per film, named with the title and the year in brackets.
- **Shows:** a folder per show, a `Season 01` folder per season, and `S01E01` (season 1, episode 1) in each episode's file name.
- Keep films and shows in separate main folders (`Movies` and `Shows`). Anime can have its own folder too.

### 2. Install Jellyfin

Jellyfin is free. Get it from [jellyfin.org/downloads](https://jellyfin.org/downloads): it has Windows, Linux, macOS, Docker and NAS versions, each with its install steps.

**On Windows**, following Jellyfin's [Windows quick start](https://jellyfin.org/docs/general/quick-start/windows):

1. Run the installer and choose **Basic Install** (not *Install as a Service*).
2. When it's done, Jellyfin's icon appears in the system tray, next to the clock.
3. If Windows asks whether to allow Jellyfin through the firewall, choose **Allow**. Otherwise the TV PC can't reach it.

### 3. The first-start wizard

Once Jellyfin is installed, open a web browser **on the server** and go to `http://localhost:8096`. A setup wizard opens:

1. **Language:** pick yours.
2. **Your user:** choose a user name and password. This is the profile you'll sign in to Rollback with.
3. **Media libraries:** choose **Add Media Library** once per folder from step 1:
   - **Content type:** *Movies* for your films folder, *Shows* for your shows.
   - **Folders:** press **+** and pick the folder.
   - Leave everything else as it is, and press **OK**.
4. **Metadata language and country:** yours. This is the language of the descriptions.
5. **Remote access:** leave **Allow remote connections** on (that's how Rollback connects over your home network), and leave **Enable automatic port mapping** off.
6. Press **Finish**, then sign in.

Jellyfin now reads your library and downloads posters. With a big collection this takes a while: you can watch the progress on the Jellyfin home page, and carry on with the steps meanwhile.

### 4. Turn on Quick Connect (recommended) {#quick-connect}

Quick Connect lets you sign in to Rollback with a 6-digit code from your phone instead of typing a password with a controller. In Jellyfin's web page: **☰ menu → Dashboard → General**, tick **Enable Quick Connect**, and **Save**.

### 5. Find your server's address {#find-address}

Rollback usually finds your server by itself. If it doesn't, you'll need its address, a number like `192.168.1.20`, followed by `:8096`.

- **Windows server:** press **Start**, type `cmd`, open it, type `ipconfig` and press Enter. The address is next to **IPv4 Address**.
- **Linux server:** run `hostname -I` in a terminal. The first number is the address.
- **NAS:** it's shown in your NAS's app, or in your router's list of devices.

So if the server's address is `192.168.1.20`, Rollback needs `192.168.1.20:8096`.

::: tip Check it works
On your phone, connected to the same Wi-Fi, open `http://192.168.1.20:8096` (with your address). If Jellyfin's page opens, Rollback will find it too.
:::

## Part 2: install Rollback {#install-rollback}

Install Rollback on the computer connected to your TV. Download it from the [Download page](/download).

### Windows 10 and 11

1. Run `RollbackSetup.exe`.
2. Windows may show a blue **"Windows protected your PC"** window. That's because Rollback is a small free app without a paid signing certificate, not because anything is wrong. Choose **More info**, then **Run anyway**.
3. Follow the installer. Rollback is added to the Start menu.

Updates install the same way, over the old version: your profiles and settings stay.

### Linux

1. Download `Rollback-x86_64.AppImage`.
2. Right-click it → **Properties** → **Permissions**, and tick **Allow executing file as program** (the wording depends on your desktop).
3. Double-click it to open Rollback.

::: details Or in a terminal
```bash
chmod +x Rollback-x86_64.AppImage
./Rollback-x86_64.AppImage
```
:::

## Part 3: first start

### 1. Connect to your server

The first time Rollback opens, it asks **where your library is**. Pick your Jellyfin server if it's in the list. If not, type its address from [Part 1, step 5](#find-address), for example `192.168.1.20:8096`.

### 2. Sign in

On **Who's watching**, choose **Add profile**, then either:

- **With your phone (easiest):** Rollback shows a 6-digit code. On your phone, open Jellyfin (the app, or the server's address in the browser), sign in, go to your profile, choose **Quick Connect** and enter the code.
- **With your password:** type the user name and password from the wizard, with the on-screen keyboard or a real one.

Rollback remembers the profile on this computer: next time it's one press. Everyone at home can have their own profile, each with their own progress.

### 3. Watch

![Rollback's Home: a big backdrop of the selected film, with rows of posters below](/shots/home.jpg)

You're on **Home**: Continue watching, Recently added, and a tab for each library. Choose something and press **Play**. Rollback plays the original file straight from your server, in the best quality your screen can show.

![The player, with Audio, Subtitles, Playback and Info along the bottom](/shots/player.jpg)

While watching, bring up the bar to change **Audio**, **Subtitles** or **Playback**, or open **Info**.

## If something doesn't work

- **Rollback doesn't find the server:** check the server is on, then type its address by hand. Try the [phone check](#find-address) above: if your phone can't open Jellyfin either, it's the server or the network, not Rollback.
- **Quick Connect says it's off:** turn it on in Jellyfin ([step 4](#quick-connect)).
- **A film has no poster, or the wrong one:** check its folder name has the title and year ([step 1](#sort-files)), then in Jellyfin's web page open the film's **⋮** menu → **Refresh metadata**.
- **Watching away from home:** Jellyfin's [networking guide](https://jellyfin.org/docs/general/networking/) explains the options. A private network app such as Tailscale on both computers is the simplest safe way.

More in [Troubleshooting](/guide/troubleshooting).

Next: [Controller and keyboard](/guide/controls)
