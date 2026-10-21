#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <vector>
#include <shellapi.h>
#include <commctrl.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  static LRESULT CALLBACK DropWindowProc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);
  void AcceptDrop(HDROP drop);
  void FlushDrops();
  bool drop_ready_ = false;
  std::vector<flutter::EncodableValue> pending_drops_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> drop_channel_;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
