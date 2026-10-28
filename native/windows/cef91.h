// Minimal declarations for the CEF 4472 C API. Layout verified against:
// chromiumembedded/cef@04c8d5653ca5b3e36b693d871cce1ef09617bfc9.
// See LICENSES/CEF.txt for the upstream license.
#pragma once
#include <stddef.h>

struct CefString { wchar_t* text; size_t length; void (*destructor)(wchar_t*); };
struct CefBase {
    size_t size;
    void (*add_ref)(CefBase*);
    int (*release)(CefBase*);
    int (*has_one_ref)(CefBase*);
    int (*has_any_ref)(CefBase*);
};
struct CefCommandLine {
    CefBase base;
    int (*is_valid)(CefCommandLine*);
    int (*is_read_only)(CefCommandLine*);
    void* copy;
    void* init_from_argv;
    void* init_from_string;
    void* reset;
    void* get_argv;
    void* get_command_line_string;
    void* get_program;
    void* set_program;
    void* has_switches;
    int (*has_switch)(CefCommandLine*, const CefString*);
    CefString* (*get_switch_value)(CefCommandLine*, const CefString*);
    void* get_switches;
    void* append_switch;
    void (*append_switch_with_value)(CefCommandLine*, const CefString*, const CefString*);
    void* has_arguments;
    void* get_arguments;
    void* append_argument;
    void* prepend_wrapper;
};
struct CefApp;
typedef void (*BeforeCommandLine)(CefApp*, const CefString*, CefCommandLine*);
struct CefApp { CefBase base; BeforeCommandLine before_command_line; void* callbacks[4]; };
typedef int (*CefInitialize)(const void*, const void*, CefApp*, void*);
static_assert(sizeof(void*) == 8, "Windows startup loader requires x64");
static_assert(sizeof(CefBase) == 40, "CEF base ABI");
static_assert(sizeof(CefApp) == 80, "CEF app ABI");
static_assert(sizeof(CefCommandLine) == 200, "CEF command line ABI");
static_assert(offsetof(CefApp, before_command_line) == 40, "CEF callback ABI");
static_assert(offsetof(CefCommandLine, append_switch_with_value) == 160, "CEF append ABI");
