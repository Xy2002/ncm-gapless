#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string>
#include <stdio.h>
#include "../../native/windows/cef91.h"
extern "C" __declspec(dllimport) int cef_initialize(const void*, const void*, CefApp*, void*);
static int before_calls;
static int app_references;
static int app_ownership_errors;
static BeforeCommandLine expected_callback;
static void AddApp(CefBase*) { app_references++; }
static int ReleaseApp(CefBase* base) {
    app_references--;
    if (app_references == 0 && ((CefApp*)base)->before_command_line != expected_callback) app_ownership_errors++;
    return app_references == 0;
}
static void Before(CefApp*, const CefString*, CefCommandLine* command) {
    before_calls++;
    if (wcsstr(GetCommandLineW(), L"--cancel-during-original")) {
        wchar_t path[32768]; GetEnvironmentVariableW(L"LOCALAPPDATA", path, 32768);
        DeleteFileW((std::wstring(path) + L"\\NCMGapless\\startup\\enabled.txt").c_str());
    }
    if (command->is_read_only(command)) { command->base.release(&command->base); return; }
    CefString name = { const_cast<wchar_t*>(L"official-original"), 17, NULL };
    CefString value = { const_cast<wchar_t*>(L"preserved"), 9, NULL };
    command->append_switch_with_value(command, &name, &value);
    command->base.release(&command->base); // Generated CEF CToCpp bridges consume this transferred reference.
}
extern "C" __declspec(dllexport) int FixtureRun() {
    // Keep the same import route as the shipped client, without drawing anything.
    auto volatile drawing = &AlphaBlend;
    if (!drawing) return 5;
    CefApp app = {}; app.base.size = sizeof(app);
    app_references = 1; app_ownership_errors = 0;
    app.base.add_ref = AddApp; app.base.release = ReleaseApp;
    app.before_command_line = wcsstr(GetCommandLineW(), L"--null-callback") ? NULL : Before;
    const auto expected = app.before_command_line;
    expected_callback = expected;
    int result = cef_initialize(NULL, NULL, wcsstr(GetCommandLineW(), L"--null-app") ? NULL : &app, NULL);
    printf("{\"initializeResult\":%d,\"originalCalls\":%d,\"callbackRestored\":%s,\"appOwnershipErrors\":%d,\"appReferences\":%d}\n", result, before_calls,
        app.before_command_line == expected ? "true" : "false", app_ownership_errors, app_references);
    return 0;
}
