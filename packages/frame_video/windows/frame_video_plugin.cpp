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
// window_manager changes the window's style, size and position one after another, so going full
// screen passed through several in-between sizes (each one a full relayout and frame in Rollback:
// slow, and it could leave the old "Windows Basic" title bar). This is the classic borderless
// full screen: the frame's style is dropped and the window covers its monitor in one move; back,
// the style and the saved placement come back in one move. Windows also treats a borderless
// window covering the screen as full screen (no desktop composition in between).
static WINDOWPLACEMENT g_placement = {sizeof(WINDOWPLACEMENT)};
static LONG_PTR g_windowed_style = 0;
static bool g_full_screen = false;

static bool SetFullScreen(HWND frame, bool on) {
  if (on == g_full_screen) return true;
  if (on) {
    MONITORINFO mi = {sizeof(mi)};
    if (!GetWindowPlacement(frame, &g_placement) ||
        !GetMonitorInfo(MonitorFromWindow(frame, MONITOR_DEFAULTTONEAREST), &mi)) {
      return false;
    }
    g_windowed_style = GetWindowLongPtr(frame, GWL_STYLE);
    SetWindowLongPtr(frame, GWL_STYLE, g_windowed_style & ~WS_OVERLAPPEDWINDOW);
    SetWindowPos(frame, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top, mi.rcMonitor.right - mi.rcMonitor.left,
                 mi.rcMonitor.bottom - mi.rcMonitor.top, SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  } else {
    SetWindowLongPtr(frame, GWL_STYLE, g_windowed_style ? g_windowed_style : (GetWindowLongPtr(frame, GWL_STYLE) | WS_OVERLAPPEDWINDOW));
    SetWindowPlacement(frame, &g_placement);
    SetWindowPos(frame, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  }
  g_full_screen = on;
  return true;
}

class FrameVideoPlugin : public flutter::Plugin {
 public:
  explicit FrameVideoPlugin(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        registrar->messenger(), "frame/video", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) { Handle(call, std::move(result)); });
  }
  ~FrameVideoPlugin() override { Close(); }

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

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

}  // namespace

void FrameVideoPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar_ref) {
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar_ref);
  registrar->AddPlugin(std::make_unique<FrameVideoPlugin>(registrar));
}
