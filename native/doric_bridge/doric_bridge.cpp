// doric_bridge - helper process that hosts DoricSystem.dll behind a line protocol.
//
// Purpose
//   Runs the vendor DLL outside MATLAB (decision D1, docs/architecture.md). It captures the
//   library's debug text (the API's only error channel), pumps wait() on the only thread that
//   calls the DLL, and switches every opened light source off when its stdin closes.
//
// Usage
//   doric_bridge.exe --dll-dir <folder with DoricSystem.dll> [--pump-ms 10] [--settle-ms 100]
//                    [--debugger 1] [--capture-ods 1]
//   doric_bridge.exe --simulate [--sim-devices 5:LEDFLS_465_465,7:Other] [--pump-ms ...]
//
// Protocol
//   docs/bridge-protocol.md. Requests on stdin, "@D ..." replies and events on stdout.
//
// Exit codes
//   0 normal, 2 bad arguments, 3 DLL not found, 4 missing export.
//
// Build
//   native/doric_bridge/build_bridge.m (MinGW-w64 g++, C++17, vendor headers only).
//
// See also: docs/vendor-dll.md, +doric/+transport/BridgeTransport.m

#include <cstdint>  // the vendor headers use uint16_t etc. without including it
#include <cstddef>
#include "doric_system_wrapper.h"

#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <fcntl.h>
#include <io.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace LS = Doric::LightSource;

static const char *kBridgeVersion = "1.0.0";
static const int kMaxQueue = 256;
static const int kMaxComplex = 32;
static const int kMaxCustom = 1000;
static const int kMaxChannels = 8;

// ---------------------------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------------------------

struct Options {
    std::wstring dllDir;
    int pumpMs = 10;
    int settleMs = 100;
    bool debugger = true;
    bool captureOds = true;
    bool simulate = false;
    std::vector<std::pair<int, std::string>> simDevices{{5, "LEDFLS_465_465"}};
};

static Options g_opt;

// ---------------------------------------------------------------------------------------------
// Protocol output. Only whole lines are written, under one mutex, to the original stdout handle
// (the process's std handles are redirected to a capture pipe before the DLL loads).
// ---------------------------------------------------------------------------------------------

static HANDLE g_out = INVALID_HANDLE_VALUE;
static std::mutex g_outMutex;
static std::condition_variable g_outCv;
static std::deque<std::string> g_outQueue;
static std::atomic<bool> g_outBroken{false};
static std::atomic<bool> g_outStop{false};
static long long g_outDropped = 0;  // guarded by g_outMutex
static const size_t kMaxOutQueue = 8192;

// Protocol output is queued and written by one thread. A host that stops reading must never be
// able to block this process: WriteFile on a full pipe blocks forever, and a bridge blocked in a
// write would not notice stdin EOF - it would keep the device open with the light on.
static void writeLine(const std::string &line) {
    {
        std::lock_guard<std::mutex> lock(g_outMutex);
        if (g_outBroken) return;
        if (g_outQueue.size() >= kMaxOutQueue) {
            // Replies keep the host in step; unsolicited events are the ones to drop.
            if (line.compare(0, 6, "@D EVT") == 0) {
                g_outDropped++;
                return;
            }
            while (g_outQueue.size() >= kMaxOutQueue) {
                bool dropped = false;
                for (auto it = g_outQueue.begin(); it != g_outQueue.end(); ++it) {
                    if (it->compare(0, 6, "@D EVT") == 0) {
                        g_outQueue.erase(it);
                        g_outDropped++;
                        dropped = true;
                        break;
                    }
                }
                if (!dropped) {
                    g_outQueue.pop_front();
                    g_outDropped++;
                }
            }
        }
        g_outQueue.push_back(line);
    }
    g_outCv.notify_one();
}

static void outputWriter() {
    for (;;) {
        std::string line;
        {
            std::unique_lock<std::mutex> lock(g_outMutex);
            g_outCv.wait(lock, [] { return !g_outQueue.empty() || g_outStop.load(); });
            if (g_outQueue.empty()) {
                if (g_outStop) return;
                continue;
            }
            line = std::move(g_outQueue.front());
            g_outQueue.pop_front();
            if (g_outDropped > 0) {
                const long long dropped = g_outDropped;
                g_outDropped = 0;
                g_outQueue.push_front("@D EVT INFO text=dropped%3D" + std::to_string(dropped) +
                                      "%20lines%20(host%20not%20reading)");
            }
        }
        line += "\n";
        const char *p = line.data();
        size_t left = line.size();
        while (left > 0) {
            DWORD written = 0;
            if (!WriteFile(g_out, p, static_cast<DWORD>(left), &written, nullptr)) {
                g_outBroken = true;  // host gone; stdin EOF will trigger the shutdown
                std::lock_guard<std::mutex> lock(g_outMutex);
                g_outQueue.clear();
                return;
            }
            p += written;
            left -= written;
        }
    }
}

// Gives the writer thread a moment to drain before the process exits. Never waits on a host that
// has stopped reading.
static void flushOutput(int timeoutMs) {
    using clock = std::chrono::steady_clock;
    const auto until = clock::now() + std::chrono::milliseconds(timeoutMs);
    while (clock::now() < until && !g_outBroken) {
        {
            std::lock_guard<std::mutex> lock(g_outMutex);
            if (g_outQueue.empty()) return;
        }
        Sleep(1);
    }
}

// Values never contain spaces on the wire: '%', space and control characters are %XX-encoded.
static std::string encodeValue(const std::string &s) {
    std::string out;
    char hex[8];
    for (unsigned char c : s) {
        if (c == '%' || c == ' ' || c < 0x20 || c == 0x7f) {
            snprintf(hex, sizeof hex, "%%%02X", c);
            out += hex;
        } else {
            out += static_cast<char>(c);
        }
    }
    return out;
}

static std::string toLower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

// Mirrors doric.transport.MessageClassifier; keep the two tables in step.
static std::string severityOf(const std::string &text) {
    static const char *errorPatterns[] = {
        "unable to", "could not", "couldn't", "not initialized", "device not found",
        "not a lightsource driver", "wrong controller", "error", "failed", "invalid"};
    static const char *warningPatterns[] = {
        "no available device", "already initialized", "warning", "timeout", "timed out"};
    const std::string lower = toLower(text);
    for (const char *p : errorPatterns) {
        if (lower.find(p) != std::string::npos) return "error";
    }
    for (const char *p : warningPatterns) {
        if (lower.find(p) != std::string::npos) return "warning";
    }
    return "info";
}

// ---------------------------------------------------------------------------------------------
// Library text capture. Lines are forwarded at once as LIBMSG events and also collected into the
// window of the request in flight, which decides OK versus ERR libraryError.
// ---------------------------------------------------------------------------------------------

struct Window {
    int lines = 0;
    int errors = 0;
    std::string firstError;
    std::vector<std::string> texts;
};

static std::mutex g_libMutex;
static long long g_currentId = 0;  // guarded by g_libMutex
static Window g_window;            // guarded by g_libMutex

static void onLibraryLine(const char *src, std::string text) {
    while (!text.empty() && (text.back() == '\r' || text.back() == '\n' || text.back() == ' ')) {
        text.pop_back();
    }
    if (text.empty()) return;
    std::lock_guard<std::mutex> lock(g_libMutex);
    const std::string sev = severityOf(text);
    if (g_currentId != 0) {
        g_window.lines++;
        g_window.texts.push_back(text);
        if (sev == "error") {
            if (g_window.errors == 0) g_window.firstError = text;
            g_window.errors++;
        }
    }
    writeLine("@D EVT LIBMSG id=" + std::to_string(g_currentId) + " src=" + src + " sev=" + sev +
              " text=" + encodeValue(text));
}

static std::pair<long long, Window> beginWindow(long long id) {
    std::lock_guard<std::mutex> lock(g_libMutex);
    std::pair<long long, Window> saved{g_currentId, g_window};
    g_currentId = id;
    g_window = Window();
    return saved;
}

static Window endWindow(const std::pair<long long, Window> &saved) {
    std::lock_guard<std::mutex> lock(g_libMutex);
    Window w = g_window;
    g_currentId = saved.first;
    g_window = saved.second;
    return w;
}

static void splitLines(std::string &pending, const char *src) {
    size_t pos;
    while ((pos = pending.find('\n')) != std::string::npos) {
        std::string line = pending.substr(0, pos);
        pending.erase(0, pos + 1);
        onLibraryLine(src, line);
    }
}

// Reads the pipe that replaced the process's stdout/stderr (C runtime, Qt stderr logging).
static void capturePipeReader(HANDLE h) {
    std::string pending;
    char buf[4096];
    for (;;) {
        DWORD n = 0;
        if (!ReadFile(h, buf, sizeof buf, &n, nullptr) || n == 0) break;
        pending.append(buf, n);
        splitLines(pending, "stdio");
    }
    if (!pending.empty()) onLibraryLine("stdio", pending);
}

// OutputDebugString listener (DBWIN protocol), filtered to this process. Qt sends its debug
// output here when it believes no console is attached.
static std::atomic<bool> g_stopOds{false};
static std::atomic<int> g_odsActive{0};

static void odsReader() {
    HANDLE bufferReady = CreateEventW(nullptr, FALSE, FALSE, L"DBWIN_BUFFER_READY");
    if (!bufferReady) return;
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        // Another debug-output listener (DebugView, a debugger) owns the channel.
        CloseHandle(bufferReady);
        writeLine("@D EVT INFO text=" +
                  encodeValue("OutputDebugString capture unavailable: another listener is active"));
        return;
    }
    HANDLE dataReady = CreateEventW(nullptr, FALSE, FALSE, L"DBWIN_DATA_READY");
    HANDLE mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, 4096,
                                        L"DBWIN_BUFFER");
    LPVOID view = mapping ? MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 4096) : nullptr;
    if (!dataReady || !view) {
        if (view) UnmapViewOfFile(view);
        if (mapping) CloseHandle(mapping);
        if (dataReady) CloseHandle(dataReady);
        CloseHandle(bufferReady);
        return;
    }
    g_odsActive = 1;
    const DWORD myPid = GetCurrentProcessId();
    while (!g_stopOds) {
        SetEvent(bufferReady);
        if (WaitForSingleObject(dataReady, 200) != WAIT_OBJECT_0) continue;
        DWORD pid = 0;
        memcpy(&pid, view, sizeof pid);
        if (pid != myPid) continue;
        char text[4093];
        memcpy(text, static_cast<const char *>(view) + sizeof(DWORD), sizeof text - 1);
        text[sizeof text - 1] = '\0';
        std::string pending(text);
        if (pending.empty() || pending.back() != '\n') pending += '\n';
        splitLines(pending, "ods");
    }
    UnmapViewOfFile(view);
    CloseHandle(mapping);
    CloseHandle(dataReady);
    CloseHandle(bufferReady);
}

// ---------------------------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------------------------

struct Request {
    long long id = 0;
    std::string command;
    std::map<std::string, std::string> args;
    std::vector<std::string> positional;
};

static std::mutex g_queueMutex;
static std::condition_variable g_queueCv;
static std::deque<Request> g_queue;
static std::atomic<bool> g_stdinEof{false};

static void replyOk(long long id, const std::string &data = "") {
    writeLine("@D " + std::to_string(id) + " OK" + (data.empty() ? "" : " " + data));
}

static void replyErr(long long id, const std::string &code, const std::string &text) {
    writeLine("@D " + std::to_string(id) + " ERR " + code + " " + text);
}

static std::vector<std::string> splitTokens(const std::string &line) {
    std::vector<std::string> tokens;
    size_t i = 0;
    while (i < line.size()) {
        while (i < line.size() && (line[i] == ' ' || line[i] == '\t')) i++;
        size_t j = i;
        while (j < line.size() && line[j] != ' ' && line[j] != '\t') j++;
        if (j > i) tokens.push_back(line.substr(i, j - i));
        i = j;
    }
    return tokens;
}

static void handleInputLine(std::string line) {
    while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) line.pop_back();
    const std::vector<std::string> tokens = splitTokens(line);
    if (tokens.empty()) return;
    Request req;
    char *end = nullptr;
    req.id = strtoll(tokens[0].c_str(), &end, 10);
    if (*end != '\0' || req.id <= 0) {
        replyErr(0, "invalidArgument", "request must start with a positive integer id");
        return;
    }
    if (tokens.size() < 2) {
        replyErr(req.id, "unknownCommand", "missing command");
        return;
    }
    req.command = tokens[1];
    std::transform(req.command.begin(), req.command.end(), req.command.begin(),
                   [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
    for (size_t k = 2; k < tokens.size(); k++) {
        const size_t eq = tokens[k].find('=');
        if (eq != std::string::npos && eq > 0) {
            req.args[tokens[k].substr(0, eq)] = tokens[k].substr(eq + 1);
        } else {
            req.positional.push_back(tokens[k]);
        }
    }
    {
        std::lock_guard<std::mutex> lock(g_queueMutex);
        if (static_cast<int>(g_queue.size()) >= kMaxQueue) {
            replyErr(req.id, "busy", "request queue is full");
            return;
        }
        g_queue.push_back(std::move(req));
    }
    g_queueCv.notify_all();
}

static void stdinReader(HANDLE in) {
    std::string pending;
    char buf[8192];
    for (;;) {
        DWORD n = 0;
        if (!ReadFile(in, buf, sizeof buf, &n, nullptr) || n == 0) break;
        pending.append(buf, n);
        size_t pos;
        while ((pos = pending.find('\n')) != std::string::npos) {
            std::string line = pending.substr(0, pos);
            pending.erase(0, pos + 1);
            handleInputLine(line);
        }
    }
    if (!pending.empty()) handleInputLine(pending);
    g_stdinEof = true;
    g_queueCv.notify_all();
}

// ---------------------------------------------------------------------------------------------
// Argument parsing helpers. Each throws ArgError naming the offending key.
// ---------------------------------------------------------------------------------------------

struct ArgError {
    std::string key;
    std::string why;
};

static bool hasArg(const Request &r, const std::string &key) { return r.args.count(key) > 0; }

static long long parseInteger(const std::string &key, const std::string &text, long long lo,
                              long long hi) {
    if (text.empty()) throw ArgError{key, "empty value"};
    char *end = nullptr;
    const long long v = strtoll(text.c_str(), &end, 10);
    if (*end != '\0') throw ArgError{key, "not an integer: " + text};
    if (v < lo || v > hi) {
        throw ArgError{key, "out of range [" + std::to_string(lo) + ", " + std::to_string(hi) +
                                "]: " + text};
    }
    return v;
}

static long long intArg(const Request &r, const std::string &key, long long lo, long long hi,
                        long long def, bool required = false) {
    auto it = r.args.find(key);
    if (it == r.args.end()) {
        if (required) throw ArgError{key, "missing"};
        return def;
    }
    return parseInteger(key, it->second, lo, hi);
}

static double doubleArg(const Request &r, const std::string &key, double def) {
    auto it = r.args.find(key);
    if (it == r.args.end()) return def;
    char *end = nullptr;
    const double v = strtod(it->second.c_str(), &end);
    if (it->second.empty() || *end != '\0') throw ArgError{key, "not a number: " + it->second};
    if (!std::isfinite(v) || v < 0) throw ArgError{key, "must be finite and >= 0"};
    return v;
}

static long long enumArg(const Request &r, const std::string &key, std::initializer_list<int> allowed,
                         long long def) {
    auto it = r.args.find(key);
    if (it == r.args.end()) return def;
    const long long v = parseInteger(key, it->second, -2147483648LL, 2147483647LL);
    for (int a : allowed) {
        if (a == v) return v;
    }
    throw ArgError{key, "not an allowed value: " + it->second};
}

// ---------------------------------------------------------------------------------------------
// The DLL, or its simulation
// ---------------------------------------------------------------------------------------------

struct Api {
    void (*init)(bool) = nullptr;
    void (*quit)() = nullptr;
    void (*wait)(int) = nullptr;
    void (*available_devices_with_ports)() = nullptr;
    void (*open_device)(int) = nullptr;
    void (*close_device)(int) = nullptr;
    void (*ls_start_all)(int) = nullptr;
    void (*ls_stop_all)(int) = nullptr;
    // enum class Channel : int is passed exactly like an int in the Windows x64 ABI
    void (*ls_start_channel)(int, int) = nullptr;
    void (*ls_stop_channel)(int, int) = nullptr;
    void (*ls_send_settings)(int, LS::Settings *) = nullptr;
    void (*ls_send_current)(int, int, uint16_t) = nullptr;
};

static Api g_api;
static std::string g_dllPath = "none";
static bool g_initialised = false;
static std::set<int> g_openPorts;
static std::map<std::string, std::string> g_simFail;  // simulate: command -> library text

// Settings passed to the library stay alive (per channel) in case it reads them after the call.
static LS::Settings g_settings[kMaxChannels];
static LS::ComplexModulation g_complex[kMaxChannels][kMaxComplex];

static bool simHasDevice(int port) {
    for (const auto &d : g_opt.simDevices) {
        if (d.first == port) return true;
    }
    return false;
}

static void simCall(const std::string &fn, const std::string &data) {
    writeLine("@D EVT SIMCALL fn=" + fn + (data.empty() ? "" : " " + data));
}

// Simulated library text for a port-based call, using the DLL's own strings.
static void simPortCall(const std::string &fn, int port, const std::string &data,
                        const char *notFound, const char *notInit) {
    simCall(fn, "port=" + std::to_string(port) + (data.empty() ? "" : " " + data));
    if (!g_initialised) {
        onLibraryLine("stdio", notInit);
    } else if (!g_openPorts.count(port)) {
        onLibraryLine("stdio", notFound);
    }
}

static bool isPriority(const Request &r) { return r.command == "STOPALL"; }
static void execute(Request &req);

// Pumps the library for ms milliseconds in pump-ms slices. Between slices it serves STOPALL
// requests so an emergency stop never waits behind a long INIT/OPEN wait. Returns early on
// stdin EOF when abortOnEof is set.
static void pumpFor(int ms, bool abortOnEof = true) {
    using clock = std::chrono::steady_clock;
    const auto until = clock::now() + std::chrono::milliseconds(ms);
    for (;;) {
        auto now = clock::now();
        if (now >= until) break;
        if (abortOnEof && g_stdinEof) break;
        int slice = static_cast<int>(
            std::chrono::duration_cast<std::chrono::milliseconds>(until - now).count());
        slice = std::max(1, std::min(slice, g_opt.pumpMs));
        if (g_initialised && !g_opt.simulate) {
            g_api.wait(slice);
        } else {
            Sleep(static_cast<DWORD>(slice));
        }
        std::vector<Request> urgent;
        {
            std::lock_guard<std::mutex> lock(g_queueMutex);
            for (auto it = g_queue.begin(); it != g_queue.end();) {
                if (isPriority(*it)) {
                    urgent.push_back(std::move(*it));
                    it = g_queue.erase(it);
                } else {
                    ++it;
                }
            }
        }
        for (auto &r : urgent) execute(r);
    }
}

static void stopAndCloseAll() {
    for (int port : std::vector<int>(g_openPorts.begin(), g_openPorts.end())) {
        if (g_opt.simulate) {
            simCall("ls_stop_all", "port=" + std::to_string(port));
            simCall("close_device", "port=" + std::to_string(port));
        } else {
            g_api.ls_stop_all(port);
            g_api.wait(50);
            g_api.close_device(port);
        }
    }
    g_openPorts.clear();
    if (g_initialised) {
        if (g_opt.simulate) {
            simCall("quit", "");
        } else {
            g_api.wait(500);
            g_api.quit();
        }
        g_initialised = false;
    }
}

static std::string sizesReply() {
    char buf[1024];
    snprintf(buf, sizeof buf,
             "settings=%u ttl=%u complex=%u align.settings=%u "
             "off.channelIdx=%u off.mode=%u off.isTTLOutput=%u off.triggerType=%u "
             "off.triggerMode=%u off.isRepeatableSequence=%u off.currentMode=%u "
             "off.customDataPoint=%u off.ttlModulation=%u off.nbComplexModulations=%u "
             "off.complexModulations=%u "
             "ttl.current=%u ttl.startingDelayMs=%u ttl.delayBetweenSeqMs=%u ttl.periodMs=%u "
             "ttl.timeOnMs=%u ttl.risingTimeMs=%u ttl.fallingTimeMs=%u ttl.nbOfSeq=%u "
             "ttl.nbOfPulsesPerSeq=%u "
             "cx.mode=%u cx.current=%u cx.delayBetweenSeqMs=%u cx.periodMs=%u cx.timeOnMs=%u "
             "cx.nbOfSeq=%u cx.nbOfPulsesPerSeq=%u cx.startingDelayMs=%u compiler=mingw-gcc-%d.%d",
             (unsigned)sizeof(LS::Settings), (unsigned)sizeof(LS::TTLModulation),
             (unsigned)sizeof(LS::ComplexModulation), (unsigned)alignof(LS::Settings),
             (unsigned)offsetof(LS::Settings, channelIdx), (unsigned)offsetof(LS::Settings, mode),
             (unsigned)offsetof(LS::Settings, isTTLOutput),
             (unsigned)offsetof(LS::Settings, triggerType),
             (unsigned)offsetof(LS::Settings, triggerMode),
             (unsigned)offsetof(LS::Settings, isRepeatableSequence),
             (unsigned)offsetof(LS::Settings, currentMode),
             (unsigned)offsetof(LS::Settings, customDataPoint),
             (unsigned)offsetof(LS::Settings, ttlModulation),
             (unsigned)offsetof(LS::Settings, nbComplexModulations),
             (unsigned)offsetof(LS::Settings, complexModulations),
             (unsigned)offsetof(LS::TTLModulation, current),
             (unsigned)offsetof(LS::TTLModulation, startingDelayMs),
             (unsigned)offsetof(LS::TTLModulation, delayBetweenSeqMs),
             (unsigned)offsetof(LS::TTLModulation, periodMs),
             (unsigned)offsetof(LS::TTLModulation, timeOnMs),
             (unsigned)offsetof(LS::TTLModulation, risingTimeMs),
             (unsigned)offsetof(LS::TTLModulation, fallingTimeMs),
             (unsigned)offsetof(LS::TTLModulation, nbOfSeq),
             (unsigned)offsetof(LS::TTLModulation, nbOfPulsesPerSeq),
             (unsigned)offsetof(LS::ComplexModulation, mode),
             (unsigned)offsetof(LS::ComplexModulation, current),
             (unsigned)offsetof(LS::ComplexModulation, delayBetweenSeqMs),
             (unsigned)offsetof(LS::ComplexModulation, periodMs),
             (unsigned)offsetof(LS::ComplexModulation, timeOnMs),
             (unsigned)offsetof(LS::ComplexModulation, nbOfSeq),
             (unsigned)offsetof(LS::ComplexModulation, nbOfPulsesPerSeq),
             (unsigned)offsetof(LS::ComplexModulation, startingDelayMs), __GNUC__,
             __GNUC_MINOR__);
    return buf;
}

// Parses SETTINGS arguments into the per-channel storage. Omitted keys keep header defaults.
static LS::Settings *buildSettings(const Request &r, int ch, std::string &summary) {
    LS::Settings *s = &g_settings[ch];
    LS::ComplexModulation *cx = g_complex[ch];
    LS::Settings defaults;
    delete defaults.complexModulations;  // the header allocates one element per instance
    defaults.complexModulations = cx;
    *s = defaults;
    for (int k = 0; k < kMaxComplex; k++) cx[k] = LS::ComplexModulation();

    s->channelIdx = static_cast<Doric::System::Channel>(ch);
    s->mode = static_cast<LS::Mode>(enumArg(r, "mode", {0, 1, 2, 3, 4, 5, 6, 10}, 0));
    s->isTTLOutput = intArg(r, "ttlout", 0, 1, 0) != 0;
    s->triggerType =
        static_cast<Doric::System::TriggerType>(enumArg(r, "trigtype", {0, 1, 255}, 255));
    s->triggerMode =
        static_cast<Doric::System::TriggerMode>(enumArg(r, "trigmode", {0, 1, 2, 3}, 0));
    s->isRepeatableSequence = intArg(r, "repeat", 0, 1, 0) != 0;
    s->currentMode = static_cast<LS::CurrentMode>(enumArg(r, "curmode", {0, 1, 2}, 0));

    LS::TTLModulation &t = s->ttlModulation;
    t.current = static_cast<uint16_t>(intArg(r, "ttl.current", 0, 65535, t.current));
    t.startingDelayMs =
        static_cast<uint32_t>(intArg(r, "ttl.startdelay", 0, 4294967295LL, t.startingDelayMs));
    t.delayBetweenSeqMs =
        static_cast<uint32_t>(intArg(r, "ttl.seqdelay", 0, 4294967295LL, t.delayBetweenSeqMs));
    t.periodMs = doubleArg(r, "ttl.period", t.periodMs);
    t.timeOnMs = doubleArg(r, "ttl.on", t.timeOnMs);
    t.risingTimeMs = static_cast<uint16_t>(intArg(r, "ttl.rise", 0, 65535, t.risingTimeMs));
    t.fallingTimeMs = static_cast<uint16_t>(intArg(r, "ttl.fall", 0, 65535, t.fallingTimeMs));
    t.nbOfSeq = static_cast<uint16_t>(intArg(r, "ttl.nseq", 0, 65535, t.nbOfSeq));
    t.nbOfPulsesPerSeq =
        static_cast<uint16_t>(intArg(r, "ttl.npulses", 0, 65535, t.nbOfPulsesPerSeq));

    const int ncx = static_cast<int>(intArg(r, "ncx", 0, kMaxComplex, 0));
    s->nbComplexModulations = static_cast<uint8_t>(ncx);
    unsigned long cxSum = 0;
    for (int k = 0; k < ncx; k++) {
        const std::string p = "cx" + std::to_string(k) + ".";
        LS::ComplexModulation &c = cx[k];
        c.mode = static_cast<LS::Mode>(
            enumArg(r, p + "mode", {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}, 1));
        c.current = static_cast<uint16_t>(intArg(r, p + "current", 0, 65535, c.current));
        c.delayBetweenSeqMs = static_cast<uint32_t>(
            intArg(r, p + "seqdelay", 0, 4294967295LL, c.delayBetweenSeqMs));
        c.periodMs = doubleArg(r, p + "period", c.periodMs);
        c.timeOnMs = doubleArg(r, p + "on", c.timeOnMs);
        c.nbOfSeq = static_cast<uint16_t>(intArg(r, p + "nseq", 0, 65535, c.nbOfSeq));
        c.nbOfPulsesPerSeq =
            static_cast<uint16_t>(intArg(r, p + "npulses", 0, 65535, c.nbOfPulsesPerSeq));
        c.startingDelayMs = static_cast<uint32_t>(
            intArg(r, p + "startdelay", 0, 4294967295LL, c.startingDelayMs));
        cxSum += static_cast<unsigned long>(c.mode) + c.current + c.nbOfSeq + c.nbOfPulsesPerSeq;
    }
    for (const auto &kv : r.args) {
        if (kv.first.rfind("cx", 0) == 0 && kv.first.find('.') != std::string::npos) {
            const long long k = parseInteger(kv.first, kv.first.substr(2, kv.first.find('.') - 2),
                                             0, kMaxComplex - 1);
            if (k >= ncx) throw ArgError{kv.first, "segment index >= ncx"};
        }
    }

    int nCustom = 0;
    unsigned long customSum = 0;
    auto it = r.args.find("custom");
    if (it != r.args.end() && !it->second.empty()) {
        size_t start = 0;
        const std::string &list = it->second;
        while (start <= list.size()) {
            size_t comma = list.find(',', start);
            if (comma == std::string::npos) comma = list.size();
            if (nCustom >= kMaxCustom) throw ArgError{"custom", "more than 1000 points"};
            const long long v = parseInteger("custom", list.substr(start, comma - start), 0, 65535);
            s->customDataPoint[nCustom++] = static_cast<uint16_t>(v);
            customSum += static_cast<unsigned long>(v);
            start = comma + 1;
        }
    }

    static const std::set<std::string> known = {
        "port", "ch", "mode", "ttlout", "trigtype", "trigmode", "repeat", "curmode",
        "ttl.current", "ttl.startdelay", "ttl.seqdelay", "ttl.period", "ttl.on", "ttl.rise",
        "ttl.fall", "ttl.nseq", "ttl.npulses", "ncx", "custom", "settle"};
    for (const auto &kv : r.args) {
        if (known.count(kv.first)) continue;
        if (kv.first.rfind("cx", 0) == 0) {
            const std::string field = kv.first.substr(kv.first.find('.') + 1);
            static const std::set<std::string> cxKeys = {"mode", "current", "seqdelay", "period",
                                                         "on", "nseq", "npulses", "startdelay"};
            if (cxKeys.count(field)) continue;
        }
        throw ArgError{kv.first, "unknown key"};
    }

    char buf[512];
    snprintf(buf, sizeof buf,
             "ch=%d mode=%d ttlout=%d trigtype=%d trigmode=%d repeat=%d curmode=%d "
             "ttl.current=%u ttl.startdelay=%lu ttl.seqdelay=%lu ttl.period=%.6g ttl.on=%.6g "
             "ttl.rise=%u ttl.fall=%u ttl.nseq=%u ttl.npulses=%u ncx=%d cxsum=%lu ncustom=%d "
             "customsum=%lu",
             ch, (int)s->mode, (int)s->isTTLOutput, (int)s->triggerType, (int)s->triggerMode,
             (int)s->isRepeatableSequence, (int)s->currentMode, t.current,
             (unsigned long)t.startingDelayMs, (unsigned long)t.delayBetweenSeqMs, t.periodMs,
             t.timeOnMs, t.risingTimeMs, t.fallingTimeMs, t.nbOfSeq, t.nbOfPulsesPerSeq, ncx, cxSum,
             nCustom, customSum);
    summary = buf;
    return s;
}

// Commands that need init() first; the library itself would only print a warning.
static bool needsInit(const std::string &cmd) {
    static const std::set<std::string> cmds = {"LIST", "OPEN", "CLOSE", "START", "STOP",
                                               "STARTALL", "CURRENT", "SETTINGS"};
    return cmds.count(cmd) > 0;
}

static void execute(Request &req) {
    const std::string &cmd = req.command;
    const bool sim = g_opt.simulate;
    std::string data;
    const auto saved = beginWindow(req.id);
    try {
        int settle = static_cast<int>(intArg(req, "settle", 0, 60000, g_opt.settleMs));

        if (needsInit(cmd) && !g_initialised) {
            endWindow(saved);
            replyErr(req.id, "notInitialised", "send INIT first");
            return;
        }

        if (cmd == "HELLO") {
            settle = 0;
            data = std::string("bridge=") + kBridgeVersion + " dll=" + encodeValue(g_dllPath) +
                   " pid=" + std::to_string(GetCurrentProcessId()) +
                   " simulate=" + (sim ? "1" : "0") + " pumpms=" + std::to_string(g_opt.pumpMs) +
                   " settlems=" + std::to_string(g_opt.settleMs) +
                   " ods=" + std::to_string(g_odsActive.load());
        } else if (cmd == "INIT") {
            const bool debugger = intArg(req, "debugger", 0, 1, g_opt.debugger ? 1 : 0) != 0;
            const int waitMs = static_cast<int>(intArg(req, "waitms", 0, 600000, 5000));
            if (g_initialised) {
                onLibraryLine(sim ? "stdio" : "bridge", "System already initialized");
            } else if (sim) {
                simCall("init", std::string("debugger=") + (debugger ? "1" : "0"));
                g_initialised = true;
            } else {
                g_api.init(debugger);
                g_initialised = true;
            }
            pumpFor(waitMs);
        } else if (cmd == "LIST") {
            const int waitMs = static_cast<int>(intArg(req, "waitms", 0, 600000, 200));
            if (sim) {
                simCall("available_devices_with_ports", "");
                if (g_opt.simDevices.empty()) onLibraryLine("stdio", "No available device(s)");
                for (const auto &d : g_opt.simDevices) {
                    onLibraryLine("stdio", d.second + " (Port #" + std::to_string(d.first) + ")");
                }
            } else {
                g_api.available_devices_with_ports();
            }
            pumpFor(waitMs);
        } else if (cmd == "OPEN") {
            const int port = static_cast<int>(intArg(req, "port", 0, 65535, 0, true));
            const int waitMs = static_cast<int>(intArg(req, "waitms", 0, 600000, 5000));
            if (sim) {
                simCall("open_device", "port=" + std::to_string(port));
                if (!simHasDevice(port)) {
                    onLibraryLine("stdio", "Unable to connect device... Device not found");
                }
            } else {
                g_api.open_device(port);
            }
            pumpFor(waitMs);
        } else if (cmd == "CLOSE") {
            const int port = static_cast<int>(intArg(req, "port", 0, 65535, 0, true));
            const int waitMs = static_cast<int>(intArg(req, "waitms", 0, 600000, 1000));
            if (sim) {
                simPortCall("close_device", port, "", "Unable to disconnect device... Device not found",
                            "Could not close device. System not initialized yet");
            } else {
                g_api.close_device(port);
            }
            g_openPorts.erase(port);
            pumpFor(waitMs);
        } else if (cmd == "START" || cmd == "STOP") {
            const int port = static_cast<int>(intArg(req, "port", 0, 65535, 0, true));
            const int ch = static_cast<int>(intArg(req, "ch", 0, kMaxChannels - 1, 0, true));
            const bool start = cmd == "START";
            if (sim) {
                simPortCall(start ? "ls_start_channel" : "ls_stop_channel", port,
                            "ch=" + std::to_string(ch),
                            start ? "Unable to start channel... Device not found"
                                  : "Unable to stop channel... Device not found",
                            start ? "Could not start channel. System not initialized yet"
                                  : "Could not stop channel. System not initialized yet");
            } else if (start) {
                g_api.ls_start_channel(port, ch);
            } else {
                g_api.ls_stop_channel(port, ch);
            }
        } else if (cmd == "STARTALL") {
            const int port = static_cast<int>(intArg(req, "port", 0, 65535, 0, true));
            if (sim) {
                simPortCall("ls_start_all", port, "", "Unable to start all... Device not found",
                            "Could not start all. System not initialized yet");
            } else {
                g_api.ls_start_all(port);
            }
        } else if (cmd == "STOPALL") {
            // Without port: every port this bridge opened (safe in any state, even before INIT).
            std::vector<int> ports;
            if (hasArg(req, "port")) {
                ports.push_back(static_cast<int>(intArg(req, "port", 0, 65535, 0)));
            } else {
                ports.assign(g_openPorts.begin(), g_openPorts.end());
            }
            if (!g_initialised) ports.clear();
            for (int port : ports) {
                if (sim) {
                    simPortCall("ls_stop_all", port, "", "Unable to stop all... Device not found",
                                "Could not stop all. System not initialized yet");
                } else {
                    g_api.ls_stop_all(port);
                }
            }
            data = "ports=" + std::to_string(ports.size());
        } else if (cmd == "CURRENT") {
            const int port = static_cast<int>(intArg(req, "port", 0, 65535, 0, true));
            const int ch = static_cast<int>(intArg(req, "ch", 0, kMaxChannels - 1, 0, true));
            const int ma = static_cast<int>(intArg(req, "ma", 0, 65535, 0, true));
            if (sim) {
                simPortCall("ls_send_current", port,
                            "ch=" + std::to_string(ch) + " ma=" + std::to_string(ma),
                            "Unable to send current... Device not found",
                            "Could not send current. System not initialized yet");
            } else {
                g_api.ls_send_current(port, ch, static_cast<uint16_t>(ma));
            }
        } else if (cmd == "SETTINGS") {
            const int port = static_cast<int>(intArg(req, "port", 0, 65535, 0, true));
            const int ch = static_cast<int>(intArg(req, "ch", 0, kMaxChannels - 1, 0, true));
            std::string summary;
            LS::Settings *s = buildSettings(req, ch, summary);
            if (sim) {
                simPortCall("ls_send_settings", port, summary,
                            "Unable to send settings... Device not found",
                            "Could not send settings. System not initialized yet");
            } else {
                g_api.ls_send_settings(port, s);
            }
        } else if (cmd == "SIZES") {
            settle = 0;
            data = sizesReply();
        } else if (cmd == "SIMFAIL" && sim) {
            // Test hook: the next <COMMAND> request emits <text> as library output.
            if (req.positional.size() < 2) throw ArgError{"SIMFAIL", "usage: SIMFAIL <COMMAND> <text>"};
            std::string text;
            for (size_t k = 1; k < req.positional.size(); k++) {
                text += (k > 1 ? " " : "") + req.positional[k];
            }
            std::string target = req.positional[0];
            std::transform(target.begin(), target.end(), target.begin(),
                           [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
            g_simFail[target] = text;
            settle = 0;
        } else if (cmd == "SIMCRASH" && sim) {
            // Test hook: exit abruptly without the stdin-EOF safety path.
            flushOutput(200);
            ExitProcess(9);
        } else if (cmd == "QUIT") {
            stopAndCloseAll();
            endWindow(saved);
            replyOk(req.id);
            writeLine("@D EVT EXITING reason=quit");
            flushOutput(1000);
            ExitProcess(0);
        } else {
            endWindow(saved);
            replyErr(req.id, "unknownCommand", cmd);
            return;
        }

        if (sim) {
            auto f = g_simFail.find(cmd);
            if (f != g_simFail.end()) {
                onLibraryLine("stdio", f->second);
                g_simFail.erase(f);
            }
        }

        if (settle > 0) {
            pumpFor(settle);
            Sleep(2);  // let the capture threads forward text already written to the pipe
        }
        const Window w = endWindow(saved);

        if (cmd == "OPEN" && w.errors == 0) {
            g_openPorts.insert(static_cast<int>(intArg(req, "port", 0, 65535, 0)));
        }
        if (cmd == "LIST") {
            int n = 0;
            for (const auto &t : w.texts) {
                if (t.find("(Port #") != std::string::npos) n++;
            }
            data = "n=" + std::to_string(n);
        }
        if (w.errors > 0) {
            replyErr(req.id, "libraryError", w.firstError);
        } else {
            std::string extra = data;
            if (w.lines > 0) extra += (extra.empty() ? "" : " ") + std::string("msgs=") + std::to_string(w.lines);
            replyOk(req.id, extra);
        }
    } catch (const ArgError &e) {
        endWindow(saved);
        replyErr(req.id, "invalidArgument", e.key + ": " + e.why);
    }
}

// ---------------------------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------------------------

static std::string narrow(const std::wstring &w) {
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0,
                                nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), &s[0], n, nullptr,
                        nullptr);
    return s;
}

static void fatal(int exitCode, const std::string &code, const std::string &text) {
    writeLine("@D EVT FATAL code=" + code + " text=" + encodeValue(text));
    flushOutput(1000);
    ExitProcess(static_cast<UINT>(exitCode));
}

static bool parseArgs(int argc, wchar_t **argv, std::string &why) {
    for (int k = 1; k < argc; k++) {
        const std::wstring a = argv[k];
        auto next = [&](std::wstring &out) {
            if (k + 1 >= argc) return false;
            out = argv[++k];
            return true;
        };
        std::wstring v;
        auto nextInt = [&](int lo, int hi, int &out) {
            if (!next(v)) return false;
            wchar_t *end = nullptr;
            const long n = wcstol(v.c_str(), &end, 10);
            if (*end != L'\0' || n < lo || n > hi) return false;
            out = static_cast<int>(n);
            return true;
        };
        int tmp = 0;
        if (a == L"--dll-dir") {
            if (!next(g_opt.dllDir)) { why = "--dll-dir needs a folder"; return false; }
        } else if (a == L"--pump-ms") {
            if (!nextInt(1, 1000, g_opt.pumpMs)) { why = "--pump-ms needs 1..1000"; return false; }
        } else if (a == L"--settle-ms") {
            if (!nextInt(0, 60000, g_opt.settleMs)) { why = "--settle-ms needs 0..60000"; return false; }
        } else if (a == L"--debugger") {
            if (!nextInt(0, 1, tmp)) { why = "--debugger needs 0 or 1"; return false; }
            g_opt.debugger = tmp != 0;
        } else if (a == L"--capture-ods") {
            if (!nextInt(0, 1, tmp)) { why = "--capture-ods needs 0 or 1"; return false; }
            g_opt.captureOds = tmp != 0;
        } else if (a == L"--simulate") {
            g_opt.simulate = true;
        } else if (a == L"--sim-devices") {
            if (!next(v)) { why = "--sim-devices needs port:name[,port:name]"; return false; }
            g_opt.simDevices.clear();
            const std::string list = narrow(v);
            size_t start = 0;
            while (start < list.size()) {
                size_t comma = list.find(',', start);
                if (comma == std::string::npos) comma = list.size();
                const std::string item = list.substr(start, comma - start);
                const size_t colon = item.find(':');
                if (colon == std::string::npos) { why = "--sim-devices item needs port:name"; return false; }
                g_opt.simDevices.push_back({atoi(item.substr(0, colon).c_str()), item.substr(colon + 1)});
                start = comma + 1;
            }
        } else {
            why = "unknown argument: " + narrow(a);
            return false;
        }
    }
    if (!g_opt.simulate && g_opt.dllDir.empty()) {
        why = "--dll-dir is required unless --simulate";
        return false;
    }
    return true;
}

static void loadDll() {
    std::wstring dir = g_opt.dllDir;
    while (!dir.empty() && (dir.back() == L'\\' || dir.back() == L'/')) dir.pop_back();
    const std::wstring path = dir + L"\\DoricSystem.dll";
    if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) {
        fatal(3, "vendorDllNotFound", "DoricSystem.dll not found in " + narrow(dir));
    }
    // Qt looks for plugins next to the executable by default; point it at the vendor folder.
    if (GetEnvironmentVariableW(L"QT_PLUGIN_PATH", nullptr, 0) == 0) {
        SetEnvironmentVariableW(L"QT_PLUGIN_PATH", dir.c_str());
    }
    SetDllDirectoryW(dir.c_str());
    HMODULE h = LoadLibraryExW(path.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!h) {
        fatal(3, "vendorDllNotFound",
              "LoadLibrary failed for " + narrow(path) + " (Windows error " +
                  std::to_string(GetLastError()) + "; a dependency may be missing)");
    }
    g_dllPath = narrow(path);
    auto resolve = [&](const char *name) {
        FARPROC p = GetProcAddress(h, name);
        if (!p) fatal(4, "missingExport", std::string("export not found: ") + name);
        return p;
    };
    g_api.init = reinterpret_cast<void (*)(bool)>(resolve("init"));
    g_api.quit = reinterpret_cast<void (*)()>(resolve("quit"));
    g_api.wait = reinterpret_cast<void (*)(int)>(resolve("wait"));
    g_api.available_devices_with_ports =
        reinterpret_cast<void (*)()>(resolve("available_devices_with_ports"));
    g_api.open_device = reinterpret_cast<void (*)(int)>(resolve("open_device"));
    g_api.close_device = reinterpret_cast<void (*)(int)>(resolve("close_device"));
    g_api.ls_start_all = reinterpret_cast<void (*)(int)>(resolve("ls_start_all"));
    g_api.ls_stop_all = reinterpret_cast<void (*)(int)>(resolve("ls_stop_all"));
    g_api.ls_start_channel = reinterpret_cast<void (*)(int, int)>(resolve("ls_start_channel"));
    g_api.ls_stop_channel = reinterpret_cast<void (*)(int, int)>(resolve("ls_stop_channel"));
    g_api.ls_send_settings =
        reinterpret_cast<void (*)(int, LS::Settings *)>(resolve("ls_send_settings"));
    g_api.ls_send_current =
        reinterpret_cast<void (*)(int, int, uint16_t)>(resolve("ls_send_current"));
}

// Redirects this process's stdout/stderr (Win32 handles and C runtime descriptors) into a pipe
// read by capturePipeReader, so anything the library prints becomes a LIBMSG event and can never
// corrupt the protocol stream. Must run before the DLL (and its C runtime) loads.
static void redirectStdio() {
    SECURITY_ATTRIBUTES sa{sizeof(SECURITY_ATTRIBUTES), nullptr, FALSE};
    HANDLE readEnd = nullptr;
    HANDLE writeEnd = nullptr;
    if (!CreatePipe(&readEnd, &writeEnd, &sa, 0)) return;
    SetStdHandle(STD_OUTPUT_HANDLE, writeEnd);
    SetStdHandle(STD_ERROR_HANDLE, writeEnd);
    int fd = _open_osfhandle(static_cast<intptr_t>(reinterpret_cast<intptr_t>(writeEnd)), _O_TEXT);
    if (fd >= 0) {
        _dup2(fd, 1);
        _dup2(fd, 2);
    }
    // Make Qt log to stderr (our pipe) even though no console is attached.
    SetEnvironmentVariableW(L"QT_FORCE_STDERR_LOGGING", L"1");
    SetEnvironmentVariableW(L"QT_ASSUME_STDERR_HAS_CONSOLE", L"1");
    std::thread(capturePipeReader, readEnd).detach();
}

int wmain(int argc, wchar_t **argv) {
    // Keep private duplicates of the original std handles before anything redirects them.
    const HANDLE self = GetCurrentProcess();
    DuplicateHandle(self, GetStdHandle(STD_OUTPUT_HANDLE), self, &g_out, 0, FALSE,
                    DUPLICATE_SAME_ACCESS);
    HANDLE in = INVALID_HANDLE_VALUE;
    DuplicateHandle(self, GetStdHandle(STD_INPUT_HANDLE), self, &in, 0, FALSE,
                    DUPLICATE_SAME_ACCESS);
    // Never let a vendor crash dialog block the process (the host needs it to exit).
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);

    std::thread(outputWriter).detach();

    std::string why;
    if (!parseArgs(argc, argv, why)) {
        writeLine("@D EVT FATAL code=invalidArgument text=" + encodeValue(why));
        flushOutput(1000);
        return 2;
    }

    if (!g_opt.simulate) {
        redirectStdio();
        if (g_opt.captureOds) std::thread(odsReader).detach();
        loadDll();
    }

    std::thread(stdinReader, in).detach();
    writeLine(std::string("@D EVT READY bridge=") + kBridgeVersion +
              " simulate=" + (g_opt.simulate ? "1" : "0"));

    for (;;) {
        Request req;
        bool have = false;
        {
            std::unique_lock<std::mutex> lock(g_queueMutex);
            if (g_queue.empty() && !g_stdinEof && !(g_initialised && !g_opt.simulate)) {
                g_queueCv.wait_for(lock, std::chrono::milliseconds(g_opt.pumpMs));
            }
            // After EOF nobody is listening: queued requests are dropped in favour of shutdown.
            if (!g_queue.empty() && !g_stdinEof) {
                req = std::move(g_queue.front());
                g_queue.pop_front();
                have = true;
            }
        }
        if (have) {
            execute(req);
            continue;
        }
        if (g_stdinEof) break;
        if (g_initialised && !g_opt.simulate) g_api.wait(g_opt.pumpMs);
    }

    // stdin closed: the host exited or crashed. Light off, release the device, leave.
    stopAndCloseAll();
    writeLine("@D EVT EXITING reason=stdinClosed");
    g_stopOds = true;
    flushOutput(1000);
    return 0;
}
