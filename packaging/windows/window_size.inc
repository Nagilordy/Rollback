  // Rollback: the window starts at about three quarters of the screen's free area (the screen
  // minus the taskbar), 16:9, centred, so it's never bigger than the screen, even with high
  // display scaling (Windows' 1280×720 default was larger than the screen at 150–200%).
  // (Sizes here are before scaling: Create() multiplies them by the screen's scale.)
  RECT work{};
  SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  const HMONITOR monitor = MonitorFromPoint(POINT{work.left + 1, work.top + 1}, MONITOR_DEFAULTTOPRIMARY);
  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const int work_w = static_cast<int>((work.right - work.left) / scale);
  const int work_h = static_cast<int>((work.bottom - work.top) / scale);
  int width = work_w * 3 / 4;
  int height = work_h * 3 / 4;
  if (width > 1600) width = 1600;
  if (height > width * 9 / 16) height = width * 9 / 16;
  if (width > height * 16 / 9) width = height * 16 / 9;
  if (width < 640 || height < 360) {  // a very small screen: as much as fits
    width = work_w;
    height = work_h;
  }
  Win32Window::Point origin(static_cast<int>(work.left / scale) + (work_w - width) / 2,
                            static_cast<int>(work.top / scale) + (work_h - height) / 2);
  Win32Window::Size size(width, height);
