// Rollback's video surface on Windows.
//
// open():  creates a borderless, black window ("the surface") exactly under Rollback's window,
//          the same size and place, and returns its handle. libmpv draws the video into it with
//          its own renderer (Direct3D 11, HDR). Rollback's window is made see-through (DWM glass
//          over its whole area), so where Flutter draws nothing, the video shows through, and
//          Rollback's controls sit on top.
//          To keep the surface always just under Rollback (never in front, never with another
//          app in between), the surface becomes Rollback's "owner" window: Windows always keeps
//          an owned window above its owner. Rollback is given WS_EX_APPWINDOW so it stays in the
//          taskbar; the surface is a tool window, so it never shows in the taskbar or Alt+Tab.
// close(): gives Rollback back its old owner and look, then destroys the surface (in that order:
//          destroying an owner window would destroy Rollback with it).

#include "include/frame_video/frame_video_plugin_c_api.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <commctrl.h>
#include <dwmapi.h>
#include <windows.h>
#include <shobjidl.h>
#include <dbghelp.h>
#include <shlobj.h>
#include <psapi.h>
#include <setupapi.h>
extern "C" {
#include <hidsdi.h>
}

#include <map>
#include <set>
#include <string>
#include <algorithm>
#include <vector>
#include <atomic>
#include <thread>
#include <mutex>
#include <optional>
#include <cstdlib>
#include <memory>

namespace {

const wchar_t kSurfaceClass[] = L"FrameVideoSurface";

HWND g_frame = nullptr;    // Rollback's top-level window
HWND g_surface = nullptr;  // the video surface under it
LONG_PTR g_old_owner = 0;
LONG_PTR g_old_ex_style = 0;
const UINT_PTR kSubclassId = 0xF7A3E;

// Put the surface exactly over Rollback's client area (screen coordinates), hidden while Rollback is
// minimised or hidden.
void PlaceSurface() {
  if (!g_frame || !g_surface) return;
  RECT rc;
  GetClientRect(g_frame, &rc);
  POINT top_left{rc.left, rc.top};
  ClientToScreen(g_frame, &top_left);
  const bool hidden = IsIconic(g_frame) || !IsWindowVisible(g_frame);
  SetWindowPos(g_surface, nullptr, top_left.x, top_left.y, rc.right - rc.left, rc.bottom - rc.top,
               SWP_NOZORDER | SWP_NOACTIVATE | (hidden ? SWP_HIDEWINDOW : SWP_SHOWWINDOW));
}

LRESULT CALLBACK FrameSubclass(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam, UINT_PTR, DWORD_PTR) {
  switch (msg) {
    case WM_MOVE:
    case WM_SIZE:
    case WM_WINDOWPOSCHANGED:
    case WM_SHOWWINDOW:
    case WM_DPICHANGED: {
      const LRESULT result = DefSubclassProc(hwnd, msg, wparam, lparam);
      PlaceSurface();
      return result;
    }
    case WM_DESTROY:
      // Rollback is closing: let go of the surface first (see close()).
      if (g_surface) {
        SetWindowLongPtr(g_frame, GWLP_HWNDPARENT, g_old_owner);
        DestroyWindow(g_surface);
        g_surface = nullptr;
      }
      break;
  }
  return DefSubclassProc(hwnd, msg, wparam, lparam);
}

LRESULT CALLBACK SurfaceProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
  switch (msg) {
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;  // never take focus from Rollback
    case WM_ERASEBKGND: {
      RECT r;
      GetClientRect(hwnd, &r);
      FillRect(reinterpret_cast<HDC>(wparam), &r, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
      return 1;
    }
  }
  return DefWindowProc(hwnd, msg, wparam, lparam);
}

// Undocumented but long-standing (used by Windows' own shell): lets the window's own pixels'
// transparency show what's behind it.
struct AccentPolicy {
  int state;
  int flags;
  unsigned int gradient_color;
  int animation_id;
};
struct WindowCompositionAttributeData {
  int attribute;
  void* data;
  size_t size;
};
using SetWindowCompositionAttributeFn = BOOL(WINAPI*)(HWND, WindowCompositionAttributeData*);

void SetSeeThrough(HWND hwnd, bool on) {
  MARGINS margins = on ? MARGINS{-1, -1, -1, -1} : MARGINS{0, 0, 0, 0};
  DwmExtendFrameIntoClientArea(hwnd, &margins);
  static auto set_attribute = reinterpret_cast<SetWindowCompositionAttributeFn>(
      GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetWindowCompositionAttribute"));
  if (set_attribute) {
    // 2 = ACCENT_ENABLE_TRANSPARENTGRADIENT with a fully clear colour; 0 = back to normal.
    AccentPolicy accent{on ? 2 : 0, 2, 0x00000000, 0};
    WindowCompositionAttributeData data{19 /* WCA_ACCENT_POLICY */, &accent, sizeof(accent)};
    set_attribute(hwnd, &data);
  }
}

bool Open(HWND frame) {
  if (g_surface) return true;
  g_frame = frame;
  WNDCLASSW wc{};
  wc.lpfnWndProc = SurfaceProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kSurfaceClass;
  wc.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClassW(&wc);  // fails harmlessly if already registered

  g_surface = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, kSurfaceClass, L"Rollback video",
                              WS_POPUP | WS_CLIPCHILDREN, 0, 0, 16, 16, nullptr, nullptr,
                              GetModuleHandle(nullptr), nullptr);
  if (!g_surface) return false;

  // Keep the surface just under Rollback: Rollback becomes owned by the surface.
  g_old_owner = GetWindowLongPtr(g_frame, GWLP_HWNDPARENT);
  g_old_ex_style = GetWindowLongPtr(g_frame, GWL_EXSTYLE);
  SetWindowLongPtr(g_frame, GWL_EXSTYLE, g_old_ex_style | WS_EX_APPWINDOW);
  SetWindowLongPtr(g_frame, GWLP_HWNDPARENT, reinterpret_cast<LONG_PTR>(g_surface));
  SetWindowSubclass(g_frame, FrameSubclass, kSubclassId, 0);

  SetSeeThrough(g_frame, true);
  PlaceSurface();
  ShowWindow(g_surface, SW_SHOWNOACTIVATE);
  SetForegroundWindow(g_frame);
  return true;
}

void Close() {
  if (!g_frame) return;
  SetSeeThrough(g_frame, false);
  RemoveWindowSubclass(g_frame, FrameSubclass, kSubclassId);
  SetWindowLongPtr(g_frame, GWLP_HWNDPARENT, g_old_owner);
  SetWindowLongPtr(g_frame, GWL_EXSTYLE, g_old_ex_style);
  if (g_surface) {
    DestroyWindow(g_surface);
    g_surface = nullptr;
  }
  // Repaint the frame so the glass is gone straight away.
  SetWindowPos(g_frame, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

// ---------- Full screen in one step ----------
//
// The window keeps its normal Windows 11 style the whole time: its style is never changed, since
// changing it made Windows briefly draw the old "Windows Basic" title bar. In full screen the
// window covers its monitor and tells Windows it has no title bar or border (WM_NCCALCSIZE: the
// whole window is Rollback's), without square-corner or border lines from Windows 11, and the
// taskbar is told it's a full-screen window. Back, the saved place and size come back in one move,
// with the native title bar exactly as it was.
static WINDOWPLACEMENT g_placement = {sizeof(WINDOWPLACEMENT)};
static bool g_full_screen = false;
const UINT_PTR kFullScreenSubclassId = 0xF7A3F;

static LRESULT CALLBACK FullScreenSubclass(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam, UINT_PTR, DWORD_PTR) {
  if (msg == WM_NCCALCSIZE && wparam && g_full_screen) return 0;  // no title bar or border
  return DefSubclassProc(hwnd, msg, wparam, lparam);
}

static void MarkTaskbarFullScreen(HWND frame, bool on) {
  ITaskbarList2* taskbar = nullptr;
  if (SUCCEEDED(CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&taskbar)))) {
    if (SUCCEEDED(taskbar->HrInit())) taskbar->MarkFullscreenWindow(frame, on ? TRUE : FALSE);
    taskbar->Release();
  }
}

static void SetWindows11Edges(HWND frame, bool full_screen) {
  // 33 = DWMWA_WINDOW_CORNER_PREFERENCE (1 = square, 0 = default); 34 = DWMWA_BORDER_COLOR
  // (0xFFFFFFFE = none, 0xFFFFFFFF = default). Older Windows ignores these.
  DWORD corners = full_screen ? 1 : 0;
  DwmSetWindowAttribute(frame, 33, &corners, sizeof(corners));
  DWORD border = full_screen ? 0xFFFFFFFE : 0xFFFFFFFF;
  DwmSetWindowAttribute(frame, 34, &border, sizeof(border));
}

static bool SetFullScreen(HWND frame, bool on) {
  if (on == g_full_screen) return true;
  if (on) {
    MONITORINFO mi = {sizeof(mi)};
    if (!GetWindowPlacement(frame, &g_placement) ||
        !GetMonitorInfo(MonitorFromWindow(frame, MONITOR_DEFAULTTONEAREST), &mi)) {
      return false;
    }
    SetWindowSubclass(frame, FullScreenSubclass, kFullScreenSubclassId, 0);
    g_full_screen = true;
    SetWindows11Edges(frame, true);
    SetWindowPos(frame, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left,
                 mi.rcMonitor.bottom - mi.rcMonitor.top, SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    MarkTaskbarFullScreen(frame, true);
  } else {
    g_full_screen = false;
    MarkTaskbarFullScreen(frame, false);
    SetWindows11Edges(frame, false);
    SetWindowPlacement(frame, &g_placement);
    SetWindowPos(frame, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    RemoveWindowSubclass(frame, FullScreenSubclass, kFullScreenSubclassId);
  }
  return true;
}

// ---------- Crash log (Windows) ----------
//
// If Rollback crashes (in its own code, the video engine or a driver), Windows calls this just
// before the app closes. It writes what happened to %APPDATA%\Rollback\logs\crash-<date>.log:
// the kind of crash, and in which program file and where in it (for example libmpv-2.dll
// +0x1a2b3c), plus a small crash dump (crash-<date-time>.dmp, a few MB) that shows exactly
// where it stopped. Nothing is sent anywhere. Then Windows' usual handling continues.
static LPTOP_LEVEL_EXCEPTION_FILTER g_previous_filter = nullptr;

static LONG WINAPI CrashFilter(EXCEPTION_POINTERS* info) {
  static volatile LONG once = 0;
  if (InterlockedExchange(&once, 1) == 0) {
    wchar_t folder[MAX_PATH] = L"";
    if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, folder))) {
      wcscat_s(folder, L"\\Rollback\\logs");
      SHCreateDirectoryExW(nullptr, folder, nullptr);
      SYSTEMTIME t;
      GetLocalTime(&t);
      const DWORD code = info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionCode : 0;
      void* address = info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionAddress : nullptr;
      wchar_t module_path[MAX_PATH] = L"?";
      HMODULE module = nullptr;
      if (address && GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                            GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                        static_cast<LPCWSTR>(address), &module)) {
        GetModuleFileNameW(module, module_path, MAX_PATH);
      }
      const wchar_t* module_name = wcsrchr(module_path, L'\\');
      module_name = module_name ? module_name + 1 : module_path;
      const unsigned long long offset =
          module ? static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(address) -
                                                   reinterpret_cast<uintptr_t>(module))
                 : 0;
      PROCESS_MEMORY_COUNTERS memory{};
      GetProcessMemoryInfo(GetCurrentProcess(), &memory, sizeof(memory));
      wchar_t line[1024];
      swprintf_s(line, L"%04u-%02u-%02u %02u:%02u:%02u  Rollback crashed: code 0x%08lX in %s +0x%llX "
                 L"(thread %lu, memory %llu MB)\r\n",
                 t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, code, module_name, offset,
                 GetCurrentThreadId(), static_cast<unsigned long long>(memory.WorkingSetSize >> 20));
      wchar_t path[MAX_PATH];
      swprintf_s(path, L"%s\\crash-%04u-%02u-%02u.log", folder, t.wYear, t.wMonth, t.wDay);
      HANDLE file = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr, OPEN_ALWAYS,
                                FILE_ATTRIBUTE_NORMAL, nullptr);
      if (file != INVALID_HANDLE_VALUE) {
        char utf8[2048];
        const int n = WideCharToMultiByte(CP_UTF8, 0, line, -1, utf8, sizeof(utf8), nullptr, nullptr);
        DWORD written = 0;
        if (n > 1) WriteFile(file, utf8, n - 1, &written, nullptr);
        CloseHandle(file);
      }
      swprintf_s(path, L"%s\\crash-%04u-%02u-%02u-%02u%02u%02u.dmp", folder, t.wYear, t.wMonth, t.wDay,
                 t.wHour, t.wMinute, t.wSecond);
      HANDLE dump = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
      if (dump != INVALID_HANDLE_VALUE) {
        MINIDUMP_EXCEPTION_INFORMATION exception{GetCurrentThreadId(), info, FALSE};
        MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), dump,
                          static_cast<MINIDUMP_TYPE>(MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules),
                          info ? &exception : nullptr, nullptr, nullptr);
        CloseHandle(dump);
      }
    }
  }
  return g_previous_filter ? g_previous_filter(info) : EXCEPTION_CONTINUE_SEARCH;
}

// Keeps only the 5 newest crash dumps (a few MB each), so repeated crashes can't slowly fill
// the disk. Runs once when Rollback starts.
static void TidyCrashDumps() {
  wchar_t folder[MAX_PATH] = L"";
  if (FAILED(SHGetFolderPathW(nullptr, CSIDL_APPDATA, nullptr, 0, folder))) return;
  wcscat_s(folder, L"\\Rollback\\logs");
  wchar_t pattern[MAX_PATH];
  swprintf_s(pattern, L"%s\\crash-*.dmp", folder);
  WIN32_FIND_DATAW found;
  HANDLE find = FindFirstFileW(pattern, &found);
  if (find == INVALID_HANDLE_VALUE) return;
  std::vector<std::wstring> names;  // crash-YYYY-MM-DD-HHMMSS.dmp: sorting by name sorts by time
  do {
    names.push_back(found.cFileName);
  } while (FindNextFileW(find, &found));
  FindClose(find);
  if (names.size() <= 5) return;
  std::sort(names.begin(), names.end());
  for (size_t i = 0; i + 5 < names.size(); i++) {
    std::wstring path = std::wstring(folder) + L"\\" + names[i];
    DeleteFileW(path.c_str());
  }
}

// ---------- PlayStation controllers (Windows) ----------
//
// The controller library Rollback uses on Windows (gamepads, through Microsoft's GameInput) only
// sees Xbox-style controllers, so PS5 and PS4 controllers are read here, straight from the
// controller itself (USB or Bluetooth, no extra driver): Rollback finds every Sony controller
// (vendor 0x054C) among the PC's input devices, opens it and reads what it sends. A controller
// that's turned off, runs out of battery or loses its Bluetooth link simply stops; when it's
// back, it's found again within a couple of seconds (or as soon as Windows says a device was
// plugged in), with no need to restart Rollback.
//
// (Before, this went through Windows' old joystick system, which keeps its own list of
// controllers from when the app started: a controller turned off and on again often wasn't
// seen until Rollback was restarted.)
//
// Each controller is read on its own thread, and the finding happens on another, so nothing
// here can freeze the app. Changes are handed to the main thread with a window message, in
// the same shape as before: buttons in Windows' joystick order (0 Square, 1 Cross, 2 Circle,
// 3 Triangle, 4 L1, 5 R1, 6 L2, 7 R2, 8 Create/Share, 9 Options, 10 L3, 11 R3, 12 PS,
// 13 touchpad), the d-pad as a direction in hundredths of degrees (65535 = released), and the
// left stick from -100 to 100 (down is positive).
struct PadState {
  DWORD buttons = 0;
  DWORD pov = 65535;
  int lx = 0, ly = 0;
};
struct PadEvent {
  UINT id;
  bool gone;
  PadState state;
};
// (Made once and never destroyed: the controller threads aren't waited for when Rollback
// closes, so these must still exist if one does a last round while the app is shutting down.)
static std::mutex& g_pad_mutex = *new std::mutex;
static std::vector<PadEvent>& g_pad_events = *new std::vector<PadEvent>;  // waiting for the main thread
static std::set<std::wstring>& g_pad_paths = *new std::set<std::wstring>;  // controllers being read
// Input devices already checked that aren't PlayStation controllers (keyboard, mouse…), so the
// search every 2 s doesn't open them again; forgotten when Windows reports a device change.
static std::set<std::wstring>& g_pad_skip = *new std::set<std::wstring>;
static std::atomic<bool> g_pad_run{false};
static std::atomic<bool> g_pad_rescan{true};
static std::atomic<UINT> g_pad_next_id{0};
static std::thread g_pad_thread;
static std::atomic<HWND> g_pad_window{nullptr};
const UINT kPadMessage = WM_APP + 0x3A1;

static void PostPadEvent(const PadEvent& e) {
  {
    std::lock_guard<std::mutex> lock(g_pad_mutex);
    g_pad_events.push_back(e);
  }
  if (HWND window = g_pad_window.load()) PostMessage(window, kPadMessage, 0, 0);
}

static int StickValue(uint8_t v) {
  const int t = (static_cast<int>(v) - 128) * 100 / 127;
  return t < -100 ? -100 : (t > 100 ? 100 : t);
}

// Reads one report from a PS5 (DualSense) or PS4 (DualShock 4) controller. The layouts:
// DualSense over USB: 0x01 [LX LY RX RY L2 R2 counter B0 B1 B2 …]
// DualSense over Bluetooth: 0x01 [LX LY RX RY B0 B1 B2 L2 R2] (simple), or
//   0x31 [seq LX LY RX RY L2 R2 counter B0 B1 B2 …] (full)
// DualShock 4: 0x01 [LX LY RX RY B0 B1 B2 L2 R2 …] (USB, and Bluetooth simple), or
//   0x11 [flags flags LX LY RX RY B0 B1 B2 …] (Bluetooth full)
// B0 = d-pad (low 4 bits, 8 = released) + Square/Cross/Circle/Triangle, B1 = L1 R1 L2 R2
// Create/Share Options L3 R3, B2 = PS, touchpad.
static bool ReadSonyReport(const uint8_t* r, DWORD n, bool dualsense, bool usb, PadState* out) {
  if (n < 10) return false;
  const uint8_t* stick;
  uint8_t b0, b1, b2;
  if (r[0] == 0x01 && dualsense && usb) {
    if (n < 11) return false;
    stick = r + 1, b0 = r[8], b1 = r[9], b2 = r[10];
  } else if (r[0] == 0x01) {
    stick = r + 1, b0 = r[5], b1 = r[6], b2 = r[7];
  } else if (r[0] == 0x31 && dualsense) {
    if (n < 12) return false;
    stick = r + 2, b0 = r[9], b1 = r[10], b2 = r[11];
  } else if (r[0] == 0x11 && !dualsense) {
    stick = r + 3, b0 = r[7], b1 = r[8], b2 = r[9];
  } else {
    return false;  // another kind of report (battery, motion…)
  }
  out->buttons = (b0 >> 4) | (static_cast<DWORD>(b1) << 4) | (static_cast<DWORD>(b2 & 0x03) << 12);
  const int dpad = b0 & 0x0F;
  out->pov = dpad < 8 ? static_cast<DWORD>(dpad) * 4500 : 65535;
  out->lx = StickValue(stick[0]);
  out->ly = StickValue(stick[1]);
  return true;
}

// Reads one controller until it goes away (turned off, unplugged, out of range).
static void ReadController(std::wstring path, HANDLE handle, UINT id, bool dualsense, bool usb, USHORT length) {
  std::vector<uint8_t> report(length > 0 ? length : 128);
  PadState last;
  bool announced = false;
  // Buttons already held when the controller connects (the PS button that turned it on,
  // say) don't count as presses until they've been let go once.
  DWORD held_at_start = 0;
  while (g_pad_run) {
    DWORD n = 0;
    if (!ReadFile(handle, report.data(), static_cast<DWORD>(report.size()), &n, nullptr)) break;
    PadState next;
    if (!ReadSonyReport(report.data(), n, dualsense, usb, &next)) continue;
    if (!announced) held_at_start = next.buttons;
    held_at_start &= next.buttons;  // let go: counts again from now on
    next.buttons &= ~held_at_start;
    const bool stick_changed = std::abs(next.lx - last.lx) >= 5 || std::abs(next.ly - last.ly) >= 5;
    if (!announced || next.buttons != last.buttons || next.pov != last.pov || stick_changed) {
      if (announced && !stick_changed) {
        next.lx = last.lx;
        next.ly = last.ly;
      }
      last = next;
      announced = true;
      PostPadEvent({id, false, next});  // (the first one also tells Rollback it's there)
    }
  }
  CloseHandle(handle);
  if (announced) PostPadEvent({id, true, {}});
  std::lock_guard<std::mutex> lock(g_pad_mutex);
  g_pad_paths.erase(path);
}

// Looks through the PC's input devices for Sony game controllers not being read yet, and
// starts reading each one it finds.
static void FindControllers() {
  GUID hid;
  HidD_GetHidGuid(&hid);
  HDEVINFO set = SetupDiGetClassDevsW(&hid, nullptr, nullptr, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
  if (set == INVALID_HANDLE_VALUE) return;
  SP_DEVICE_INTERFACE_DATA item{sizeof(item)};
  for (DWORD i = 0; g_pad_run && SetupDiEnumDeviceInterfaces(set, nullptr, &hid, i, &item); i++) {
    DWORD size = 0;
    SetupDiGetDeviceInterfaceDetailW(set, &item, nullptr, 0, &size, nullptr);
    if (size == 0) continue;
    std::vector<uint8_t> buffer(size);
    auto* detail = reinterpret_cast<SP_DEVICE_INTERFACE_DETAIL_DATA_W*>(buffer.data());
    detail->cbSize = sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W);
    if (!SetupDiGetDeviceInterfaceDetailW(set, &item, detail, size, nullptr, nullptr)) continue;
    const std::wstring path = detail->DevicePath;
    {
      std::lock_guard<std::mutex> lock(g_pad_mutex);
      if (g_pad_paths.count(path) || g_pad_skip.count(path)) continue;
    }
    // Who made it (asked without opening it for reading).
    HANDLE probe = CreateFileW(path.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (probe == INVALID_HANDLE_VALUE) continue;
    HIDD_ATTRIBUTES attributes{sizeof(attributes)};
    const bool known = HidD_GetAttributes(probe, &attributes) != FALSE;
    CloseHandle(probe);
    // A device that's still starting up (a controller just plugged in) may not answer yet:
    // asked again at the next search, never written off.
    if (!known) continue;
    const bool sony = attributes.VendorID == 0x054C;
    if (!sony) {
      std::lock_guard<std::mutex> lock(g_pad_mutex);
      g_pad_skip.insert(path);
      continue;
    }
    HANDLE handle = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                nullptr, OPEN_EXISTING, 0, nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
      handle = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
                           0, nullptr);
    }
    if (handle == INVALID_HANDLE_VALUE) continue;
    // Only the game controller part (usage page 1, usage 5: game pad).
    PHIDP_PREPARSED_DATA parsed = nullptr;
    HIDP_CAPS caps{};
    bool gamepad = false;
    if (!HidD_GetPreparsedData(handle, &parsed)) {
      CloseHandle(handle);  // not ready yet: asked again at the next search
      continue;
    }
    gamepad = HidP_GetCaps(parsed, &caps) == HIDP_STATUS_SUCCESS && caps.UsagePage == 0x01 && caps.Usage == 0x05;
    HidD_FreePreparsedData(parsed);
    if (!gamepad) {
      CloseHandle(handle);
      std::lock_guard<std::mutex> lock(g_pad_mutex);
      g_pad_skip.insert(path);  // another part of a Sony device (not the controls)
      continue;
    }
    // PS5 controllers (DualSense 0x0CE6, DualSense Edge 0x0DF2) lay their reports out
    // differently from PS4 ones; over USB their reports are 64 bytes, over Bluetooth longer.
    const bool dualsense = attributes.ProductID == 0x0CE6 || attributes.ProductID == 0x0DF2;
    const bool usb = caps.InputReportByteLength == 64;
    {
      std::lock_guard<std::mutex> lock(g_pad_mutex);
      g_pad_paths.insert(path);
    }
    std::thread(ReadController, path, handle, g_pad_next_id++, dualsense, usb, caps.InputReportByteLength).detach();
  }
  SetupDiDestroyDeviceInfoList(set);
}

static void PadThread() {
  ULONGLONG last_scan = 0;
  while (g_pad_run) {
    const ULONGLONG now = GetTickCount64();
    // Looks for controllers when Windows says a device changed, and every 2 s in case it
    // didn't say (a Bluetooth controller waking up, say).
    const bool device_changed = g_pad_rescan.exchange(false);
    if (device_changed || now - last_scan > 2000) {
      last_scan = now;
      if (device_changed) {
        std::lock_guard<std::mutex> lock(g_pad_mutex);
        g_pad_skip.clear();  // something was plugged in or removed: check everything again
      }
      FindControllers();
    }
    Sleep(100);
  }
}

class FrameVideoPlugin : public flutter::Plugin {
 public:
  explicit FrameVideoPlugin(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {
    g_previous_filter = SetUnhandledExceptionFilter(CrashFilter);
    TidyCrashDumps();
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        registrar->messenger(), "frame/video", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) { Handle(call, std::move(result)); });
    proc_id_ = registrar->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) -> std::optional<LRESULT> {
          if (msg == kPadMessage) {
            SendPadEvents();
            return 0;
          }
          if (msg == WM_DEVICECHANGE) g_pad_rescan = true;  // something plugged in or removed
          return std::nullopt;
        });
  }
  ~FrameVideoPlugin() override {
    // The controller thread stops on its own at its next check. It isn't waited for: Windows
    // can take seconds to answer while it looks for controllers, and closing Rollback must not
    // hang on that. (It only touches its own data and posts to a window that's going away.)
    g_pad_window = nullptr;
    g_pad_run = false;
    if (g_pad_thread.joinable()) g_pad_thread.detach();
    registrar_->UnregisterTopLevelWindowProcDelegate(proc_id_);
    Close();
  }

 private:
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() == "open") {
      HWND view = registrar_->GetView() ? registrar_->GetView()->GetNativeWindow() : nullptr;
      HWND frame = view ? GetAncestor(view, GA_ROOT) : nullptr;
      if (!frame || !Open(frame)) {
        result->Success();  // null: Rollback falls back to its usual player
        return;
      }
      result->Success(flutter::EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(g_surface))));
    } else if (call.method_name() == "close") {
      Close();
      result->Success();
    } else if (call.method_name() == "setFullScreen") {
      const auto* on = std::get_if<bool>(call.arguments());
      HWND view = registrar_->GetView() ? registrar_->GetView()->GetNativeWindow() : nullptr;
      HWND frame = view ? GetAncestor(view, GA_ROOT) : nullptr;
      result->Success(flutter::EncodableValue(frame && on && SetFullScreen(frame, *on)));
    } else if (call.method_name() == "startPads") {
      HWND view = registrar_->GetView() ? registrar_->GetView()->GetNativeWindow() : nullptr;
      HWND frame = view ? GetAncestor(view, GA_ROOT) : nullptr;
      if (frame && !g_pad_run) {
        g_pad_window = frame;
        g_pad_run = true;
        g_pad_rescan = true;
        g_pad_thread = std::thread(PadThread);
      }
      result->Success(flutter::EncodableValue(g_pad_run.load()));
    } else if (call.method_name() == "refreshFrame") {
      // After leaving full screen, window_manager puts the title bar's style back but doesn't
      // tell Windows the frame changed (no SWP_FRAMECHANGED when the window isn't maximised),
      // so Windows falls back to drawing the old "Windows Basic" frame. This redraws it.
      HWND view = registrar_->GetView() ? registrar_->GetView()->GetNativeWindow() : nullptr;
      HWND frame = view ? GetAncestor(view, GA_ROOT) : nullptr;
      if (frame) {
        SetWindowPos(frame, nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        RedrawWindow(frame, nullptr, nullptr, RDW_FRAME | RDW_INVALIDATE | RDW_UPDATENOW);
      }
      result->Success();
    } else {
      result->NotImplemented();
    }
  }

  // Hands what the controller thread read to Rollback: {"id", "buttons", "pov", "lx", "ly"},
  // or {"id", "gone": true} when one disconnects.
  void SendPadEvents() {
    std::vector<PadEvent> events;
    {
      std::lock_guard<std::mutex> lock(g_pad_mutex);
      events.swap(g_pad_events);
    }
    for (const auto& e : events) {
      flutter::EncodableMap map{{flutter::EncodableValue("id"), flutter::EncodableValue(static_cast<int>(e.id))}};
      if (e.gone) {
        map[flutter::EncodableValue("gone")] = flutter::EncodableValue(true);
      } else {
        map[flutter::EncodableValue("buttons")] = flutter::EncodableValue(static_cast<int64_t>(e.state.buttons));
        map[flutter::EncodableValue("pov")] = flutter::EncodableValue(static_cast<int64_t>(e.state.pov));
        map[flutter::EncodableValue("lx")] = flutter::EncodableValue(e.state.lx);
        map[flutter::EncodableValue("ly")] = flutter::EncodableValue(e.state.ly);
      }
      channel_->InvokeMethod("pad", std::make_unique<flutter::EncodableValue>(std::move(map)));
    }
  }

  flutter::PluginRegistrarWindows* registrar_;
  int proc_id_ = 0;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace

void FrameVideoPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar_ref) {
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar_ref);
  registrar->AddPlugin(std::make_unique<FrameVideoPlugin>(registrar));
}
