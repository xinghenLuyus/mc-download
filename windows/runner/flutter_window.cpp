#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include "utils.h"

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  drop_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "mc_download/archive_drop",
      &flutter::StandardMethodCodec::GetInstance());
  drop_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "ready") { result->NotImplemented(); return; }
    drop_ready_ = true;
    result->Success();
    FlushDrops();
  });
  const HWND view = flutter_controller_->view()->GetNativeWindow();
  SetWindowSubclass(view, DropWindowProc, 1, reinterpret_cast<DWORD_PTR>(this));
  DragAcceptFiles(view, TRUE);
  DragAcceptFiles(GetHandle(), TRUE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (drop_channel_) {
    drop_channel_->SetMethodCallHandler(nullptr);
    drop_channel_.reset();
  }
  if (flutter_controller_) {
    const HWND view = flutter_controller_->view()->GetNativeWindow();
    DragAcceptFiles(view, FALSE);
    RemoveWindowSubclass(view, DropWindowProc, 1);
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_DROPFILES:
      AcceptDrop(reinterpret_cast<HDROP>(wparam));
      return 0;
    case WM_GETMINMAXINFO: {
      const UINT dpi = GetDpiForWindow(hwnd);
      auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
      limits->ptMinTrackSize.x = MulDiv(1120, dpi, 96);
      limits->ptMinTrackSize.y = MulDiv(720, dpi, 96);
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

LRESULT CALLBACK FlutterWindow::DropWindowProc(HWND window, UINT message,
    WPARAM wparam, LPARAM lparam, UINT_PTR, DWORD_PTR data) {
  if (message == WM_DROPFILES) {
    reinterpret_cast<FlutterWindow*>(data)->AcceptDrop(reinterpret_cast<HDROP>(wparam));
    return 0;
  }
  return DefSubclassProc(window, message, wparam, lparam);
}

void FlutterWindow::AcceptDrop(HDROP drop) {
  flutter::EncodableList paths;
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  // Do not silently install a subset of a large multi-file drop.
  if (count <= 16) {
    for (UINT i = 0; i < count; ++i) {
      const UINT length = DragQueryFileW(drop, i, nullptr, 0);
      std::vector<wchar_t> path(static_cast<size_t>(length) + 1);
      if (DragQueryFileW(drop, i, path.data(), length + 1) != 0)
        paths.emplace_back(Utf8FromUtf16(path.data()));
    }
  }
  DragFinish(drop);
  if (pending_drops_.size() < 8) pending_drops_.emplace_back(paths);
  FlushDrops();
}

void FlutterWindow::FlushDrops() {
  if (!drop_ready_ || !drop_channel_) return;
  auto events = std::move(pending_drops_);
  pending_drops_.clear();
  for (auto& event : events) {
    drop_channel_->InvokeMethod("dropFiles", std::make_unique<flutter::EncodableValue>(std::move(event)));
  }
}
